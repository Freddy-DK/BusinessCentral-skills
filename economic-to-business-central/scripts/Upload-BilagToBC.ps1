<#
  Attaches every bilag-*.pdf in a folder to its posted G/L entry in Business Central,
  and cleans up duplicates left by earlier runs.

  For each file it lists what is already attached to that G/L entry and then:
    - deletes any duplicate copies of the same file name (keeps one with content)
    - uploads the file only if it is not there yet

  Retries throttling (429), lock conflicts (409) and 5xx with exponential backoff.
  Failures are reported at the end; the run does not stop.

  .EXAMPLE
    .\Upload-BilagToBC.ps1 -Folder .\receipts -TenantId <guid> -ClientId <guid> `
        -ClientSecret $env:BC_SECRET -Environment <env> -CompanyName '<company>' -First 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Folder,
    [Parameter(Mandatory)][string] $TenantId,
    [Parameter(Mandatory)][string] $ClientId,
    [Parameter(Mandatory)][string] $ClientSecret,
    [Parameter(Mandatory)][string] $Environment,
    [Parameter(Mandatory)][string] $CompanyName,
    [int]    $First = 0,
    [switch] $CleanupOnly
)

$ErrorActionPreference = 'Stop'

function Invoke-BC {
    param([string]$Uri, [string]$Method = 'Get', [hashtable]$Headers,
          [string]$ContentType, $Body, [string]$InFile, [int]$Retries = 6)
    for ($i = 0; ; $i++) {
        try {
            $p = @{ Uri = $Uri; Method = $Method; Headers = $Headers }
            if ($ContentType) { $p.ContentType = $ContentType }
            if ($Body)        { $p.Body        = $Body }
            if ($InFile)      { $p.InFile      = $InFile }
            return Invoke-RestMethod @p
        }
        catch {
            $code = 0
            try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch { }
            # 409 = BC record lock / concurrency, 429 = throttling. Both are transient.
            $transient = ($code -eq 409 -or $code -eq 429 -or $code -ge 500 -or $code -eq 0)
            if ($i -ge $Retries -or -not $transient) { throw }
            $wait = [math]::Min(60, [math]::Pow(2, $i + 1))
            Write-Host "    HTTP $code - retrying in $wait s" -ForegroundColor DarkYellow
            Start-Sleep -Seconds $wait
        }
    }
}

$token = (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
    grant_type    = 'client_credentials'
    client_id     = $ClientId
    client_secret = $ClientSecret
    scope         = 'https://api.businesscentral.dynamics.com/.default'
}).access_token
$H = @{ Authorization = "Bearer $token" }

$base    = "https://api.businesscentral.dynamics.com/v2.0/$TenantId/$Environment/api/v2.0"
$company = (Invoke-BC "$base/companies?`$filter=name eq '$CompanyName'" -Headers $H).value | Select-Object -First 1
if (-not $company) { throw "Company '$CompanyName' not found in environment '$Environment'." }
$co = "$base/companies($($company.id))"

$gl = @{}
$entries = (Invoke-BC "$co/generalLedgerEntries?`$select=id,entryNumber,documentNumber&`$top=20000" -Headers $H).value
foreach ($e in $entries | Sort-Object entryNumber) {
    if (-not $gl.ContainsKey($e.documentNumber)) { $gl[$e.documentNumber] = $e.id }
}
Write-Host "$($entries.Count) G/L entries, $($gl.Count) distinct document numbers."

$files = @(Get-ChildItem -LiteralPath $Folder -Filter *.pdf -Recurse -File | Sort-Object Name)
if ($First -gt 0) { $files = $files | Select-Object -First $First }

$ok = 0; $kept = 0; $removed = 0; $n = 0; $failed = @()
foreach ($f in $files) {
    $n++
    if ($f.Name -notmatch 'bilag-0*(\d+)') { Write-Warning "no bilag number in $($f.Name)"; continue }
    $doc = $Matches[1]
    if (-not $gl.ContainsKey($doc)) { Write-Warning "no G/L entry with Document No. $doc ($($f.Name))"; continue }
    $glId = $gl[$doc]
    $nav  = "$co/generalLedgerEntries($glId)/attachments"

    try {
        # what is on this entry already
        $existing = @((Invoke-BC $nav -Headers $H).value | Where-Object fileName -eq $f.Name)
        $good     = @($existing | Where-Object { $_.byteSize -gt 0 })
        $drop     = @($existing | Where-Object { $_.id -ne ($good | Select-Object -First 1).id })

        foreach ($d in $drop) {
            Invoke-BC "$nav($($d.id))" -Method Delete -Headers ($H + @{ 'If-Match' = '*' }) | Out-Null
            $removed++
        }

        if ($good.Count -gt 0) {
            $kept++
            Write-Host ("{0,3}/{1}  {2} -> already attached{3}" -f $n, $files.Count, $f.Name,
                        $(if ($drop.Count) { " ($($drop.Count) duplicate removed)" } else { '' }))
            continue
        }
        if ($CleanupOnly) { continue }

        $att = Invoke-BC $nav -Method Post -Headers $H -ContentType 'application/json' `
                   -Body (@{ fileName = $f.Name } | ConvertTo-Json)
        Invoke-BC "$co/attachments($($att.id))/attachmentContent" -Method Patch `
            -Headers ($H + @{ 'If-Match' = '*' }) -ContentType 'application/octet-stream' -InFile $f.FullName | Out-Null
        $ok++
        Write-Host ("{0,3}/{1}  {2} -> document {3}" -f $n, $files.Count, $f.Name, $doc)
    }
    catch {
        $failed += [pscustomobject]@{ File = $f.Name; Document = $doc; Error = $_.Exception.Message }
        Write-Warning "$($f.Name): $($_.Exception.Message)"
    }
}

Write-Host ("`n{0} uploaded, {1} already there, {2} duplicates removed, {3} failed." -f $ok, $kept, $removed, $failed.Count) -ForegroundColor Green
if ($failed) { $failed | Format-Table -AutoSize; Write-Host "Re-run to retry the failures." -ForegroundColor Yellow }
