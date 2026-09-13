<#
.SYNOPSIS
    Splits e-conomic "Eksporter bilag" batch PDFs into one PDF per bilag (voucher).

.DESCRIPTION
    e-conomic stamps every page of an exported bilag batch with a header like

        Regnskabsår: 2025/2026     Bilagsnummer: 62     Side: 41/144

    This script reads that stamp from every page, groups the pages that belong to
    the same voucher, and writes one PDF per voucher. Pages are copied object-for-
    object, so scanned images are never re-encoded and quality is unchanged.

    Optionally point -Postering at e-conomic's Postering.csv export and the file
    names are enriched with the posting date and the entry text, which makes the
    files far easier to match up when you upload them to Business Central:

        bilag-062_2025-10-10_Dropbox.pdf

    A CSV index of everything that was written is produced as well.

    PDF handling uses PdfPig (Apache-2.0). The script downloads it from nuget.org
    on first run into a local .\lib folder; after that it works offline. If your
    machine has no internet access, download the package yourself from
    https://www.nuget.org/api/v2/package/PdfPig/0.1.10 , rename it to .zip,
    extract it, and pass -PdfPigPath <folder>\lib\net8.0.

.PARAMETER Path
    The e-conomic batch PDFs. Wildcards are allowed.

.PARAMETER OutDir
    Where the per-voucher PDFs are written. Default: .\bilag

.PARAMETER Index
    CSV index to write. Default: .\bilag_index.csv

.PARAMETER Postering
    Optional Postering.csv from the same e-conomic export. Used only to add the
    posting date and text to the file names.

.PARAMETER Flat
    Write everything into one folder instead of a subfolder per fiscal year.

.PARAMETER PdfPigPath
    Folder containing the PdfPig assemblies, if you do not want them downloaded.

.EXAMPLE
    .\Split-EconomicBilag.ps1 .\Bilag1.pdf .\Bilag2.pdf .\Bilag3.pdf .\Bilag4.pdf

.EXAMPLE
    .\Split-EconomicBilag.ps1 .\Bilag*.pdf -Postering .\Postering.csv -OutDir .\receipts

.NOTES
    Requires PowerShell 7 or later (winget install Microsoft.PowerShell).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Path,

    [string] $OutDir = 'receipts',
    [string] $Index = 'bilag_index.csv',
    [string] $Postering,
    [switch] $Flat,
    [string] $PdfPigPath,
    [string] $PdfPigVersion = '0.1.10'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "This script needs PowerShell 7 or later (you are on $($PSVersionTable.PSVersion)). Install it with:  winget install Microsoft.PowerShell"
}

# ---------------------------------------------------------------- PdfPig -----

function Initialize-PdfPig {
    param([string] $ExplicitPath, [string] $Version)

    if ($ExplicitPath) {
        $dir = (Resolve-Path -LiteralPath $ExplicitPath).Path
    }
    else {
        $root = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
        $lib  = Join-Path $root 'lib' "PdfPig.$Version"
        $tfm  = if ([Environment]::Version.Major -ge 8) { 'net8.0' } else { 'net6.0' }
        $dir  = Join-Path $lib 'lib' $tfm

        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Host "Downloading PdfPig $Version from nuget.org ..." -ForegroundColor DarkGray
            $null = New-Item -ItemType Directory -Path $lib -Force
            $zip  = Join-Path $lib 'pdfpig.zip'
            $url  = "https://api.nuget.org/v3-flatcontainer/pdfpig/$Version/pdfpig.$Version.nupkg"
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            Expand-Archive -LiteralPath $zip -DestinationPath $lib -Force
            Remove-Item -LiteralPath $zip -Force
        }
        if (-not (Test-Path -LiteralPath $dir)) {
            throw "PdfPig assemblies for $tfm were not found in $lib"
        }
    }

    # Load in dependency order; PdfPig has no third-party dependencies on .NET 6/8.
    foreach ($name in 'UglyToad.PdfPig.Core',
                      'UglyToad.PdfPig.Tokens',
                      'UglyToad.PdfPig.Tokenization',
                      'UglyToad.PdfPig.Fonts',
                      'UglyToad.PdfPig') {
        $dll = Join-Path $dir "$name.dll"
        if (Test-Path -LiteralPath $dll) { $null = [Reflection.Assembly]::LoadFrom($dll) }
    }
    if (-not ('UglyToad.PdfPig.PdfDocument' -as [type])) {
        throw "Could not load PdfPig from $dir"
    }
    Write-Verbose "PdfPig loaded from $dir"
}

# ----------------------------------------------------------------- helpers ---

# The stamp, with every whitespace character removed first. That makes the match
# independent of how the PDF text extractor spaces the words out.
$script:Stamp = [regex]::new(
    'Regnskabs.{0,2}r:(?<year>.+?)Bilagsnummer:(?<bilag>.+?)Side:(?<page>\d+)/(?<total>\d+)',
    'Compiled')

function Get-SafeName {
    param([string] $Text, [int] $Limit = 40)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $s = [regex]::Replace($Text, '[^\w\s.-]', '').Trim()
    $s = [regex]::Replace($s, '\s+', '-')
    if ($s.Length -gt $Limit) { $s = $s.Substring(0, $Limit) }
    return $s.Trim('-')
}

function Read-TextFileSmart {
    param([string] $File)
    try {
        # strict UTF-8 first, fall back to Windows/Latin-1 (what e-conomic exports)
        return [IO.File]::ReadAllText($File, [Text.UTF8Encoding]::new($false, $true))
    }
    catch {
        return [IO.File]::ReadAllText($File, [Text.Encoding]::GetEncoding(28591))
    }
}

function Get-PosteringLabels {
    param([string] $File)
    $labels = @{}
    if (-not $File) { return $labels }
    if (-not (Test-Path -LiteralPath $File)) {
        Write-Warning "Postering file not found: $File - file names will not include date/text."
        return $labels
    }
    $csv = @(Read-TextFileSmart -File (Resolve-Path -LiteralPath $File).Path | ConvertFrom-Csv)
    $cols = @($csv[0].PSObject.Properties.Name)
    foreach ($need in 'BilagsNr', 'Dato', 'Tekst') {
        if ($cols -notcontains $need) {
            Write-Warning "$File has no '$need' column - file names will not include date/text."
            return @{}
        }
    }
    foreach ($row in $csv) {
        $b = "$($row.BilagsNr)".Trim()
        if (-not $b -or $labels.ContainsKey($b)) { continue }
        $d = "$($row.Dato)".Trim()                       # dd-mm-yyyy
        $iso = ''
        if ($d -match '^(\d{2})-(\d{2})-(\d{4})$') { $iso = "$($Matches[3])-$($Matches[2])-$($Matches[1])" }
        $t = ($row.Tekst -split '\s+' | Where-Object { $_ }) -join ' '
        $labels[$b] = [pscustomobject]@{ Date = $iso; Text = $t }
    }
    return $labels
}

# -------------------------------------------------------------------- main ---

Initialize-PdfPig -ExplicitPath $PdfPigPath -Version $PdfPigVersion

$files = @(Get-ChildItem -Path $Path -File | Where-Object Extension -ieq '.pdf' | Sort-Object FullName)
if (-not $files) { throw "No PDF files matched: $($Path -join ', ')" }

$OutDir = [IO.Path]::GetFullPath([string]$OutDir, $PWD.Path)   # honours absolute and relative paths
$null = New-Item -ItemType Directory -Path $OutDir -Force

$docs      = [ordered]@{}                       # full path -> open PdfDocument
$vouchers  = [ordered]@{}                       # "year|bilag" -> list of page refs
$unstamped = [Collections.Generic.List[string]]::new()

try {
    foreach ($f in $files) {
        Write-Host "Reading $($f.Name) ..." -ForegroundColor DarkGray
        $doc = [UglyToad.PdfPig.PdfDocument]::Open($f.FullName)
        $docs[$f.FullName] = $doc

        for ($p = 1; $p -le $doc.NumberOfPages; $p++) {
            $text = ''
            try { $text = $doc.GetPage($p).Text } catch { $text = '' }
            $compact = [regex]::Replace($text, '\s+', '')
            $m = $script:Stamp.Match($compact)
            if (-not $m.Success) {
                $unstamped.Add("$($f.Name) page $p")
                continue
            }
            $key = '{0}|{1}' -f $m.Groups['year'].Value, $m.Groups['bilag'].Value
            if (-not $vouchers.Contains($key)) {
                $vouchers[$key] = [Collections.Generic.List[object]]::new()
            }
            $vouchers[$key].Add([pscustomobject]@{ File = $f.FullName; Name = $f.Name; Page = $p })
        }
    }

    if ($vouchers.Count -eq 0) {
        throw "No 'Bilagsnummer' stamps were found. Are these e-conomic bilag exports?"
    }

    $labels = Get-PosteringLabels -File $Postering
    $rows   = [Collections.Generic.List[object]]::new()

    foreach ($key in $vouchers.Keys) {
        $year, $bilag = $key -split '\|', 2
        $pages = $vouchers[$key]

        $folder = if ($Flat) { $OutDir } else { Join-Path $OutDir ($year -replace '[\\/:*?"<>|]', '-') }
        $null = New-Item -ItemType Directory -Path $folder -Force

        $stem = 'bilag-{0}' -f $(if ($bilag -match '^\d+$') { $bilag.PadLeft(3, '0') } else { Get-SafeName $bilag })
        $date = ''; $text = ''
        if ($labels.ContainsKey($bilag)) { $date = $labels[$bilag].Date; $text = $labels[$bilag].Text }
        if ($date) { $stem += "_$date" }
        $safeText = Get-SafeName $text
        if ($safeText) { $stem += "_$safeText" }

        $dest = Join-Path $folder "$stem.pdf"
        $n = 1
        while (Test-Path -LiteralPath $dest) { $dest = Join-Path $folder ("{0}({1}).pdf" -f $stem, ++$n) }

        $builder = [UglyToad.PdfPig.Writer.PdfDocumentBuilder]::new()
        try {
            foreach ($pg in $pages) { $null = $builder.AddPage($docs[$pg.File], $pg.Page) }
            [IO.File]::WriteAllBytes($dest, $builder.Build())
        }
        finally { $builder.Dispose() }

        $rows.Add([pscustomobject]@{
            bilag        = $bilag
            fiscal_year  = $year
            pages        = $pages.Count
            posting_date = $date
            text         = $text
            source_pdf   = ($pages.Name | Select-Object -Unique) -join ','
            source_pages = ($pages.Page -join ',')
            file         = [IO.Path]::GetRelativePath($OutDir, $dest)
            bytes        = (Get-Item -LiteralPath $dest).Length
        })
    }
}
finally {
    foreach ($d in $docs.Values) { try { $d.Dispose() } catch { } }
}

$rows = $rows | Sort-Object fiscal_year, @{ Expression = { if ($_.bilag -match '^\d+$') { [int]$_.bilag } else { [int]::MaxValue } } }, bilag
$rows | Export-Csv -LiteralPath $Index -NoTypeInformation -Encoding utf8BOM

$totalBytes = ($rows | Measure-Object bytes -Sum).Sum
$multi      = @($rows | Where-Object pages -gt 1).Count

Write-Host ''
Write-Host ("{0} vouchers written to {1}  ({2:N1} MB)" -f $rows.Count, $OutDir, ($totalBytes / 1MB)) -ForegroundColor Green
Write-Host ("index: {0}" -f (Resolve-Path -LiteralPath $Index).Path)
Write-Host ("single-page: {0}   multi-page: {1}" -f ($rows.Count - $multi), $multi)

if ($unstamped.Count -gt 0) {
    Write-Warning "$($unstamped.Count) page(s) had no readable stamp and were skipped:"
    $unstamped | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
}
