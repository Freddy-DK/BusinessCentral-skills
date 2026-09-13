#requires -Version 7.0
<#
.SYNOPSIS
    Generates the repository skills index and the Jekyll site pages.

.DESCRIPTION
    Discovers every skill in the repository (a directory containing a skill.json),
    then produces:

      * README.md          - the repo-facing list of skills, linking to each
                             skill's own README.md.
      * index.md           - the Jekyll front page listing all skills, linking to
                             each skill's subpage.
      * <skill>/README.md  - the skill's own README, with Jekyll front matter
                             (generated from skill.json) injected in place so
                             Jekyll serves it at /skills/<name>/ with no copy.

    Everything shown in the lists comes from each skill's skill.json. To add a
    skill, check in a folder with a skill.json and a README.md - nothing else.

.NOTES
    Run locally to preview, or in CI (see .github/workflows/build-and-deploy.yml).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RelativePath {
    param([string]$Base, [string]$Path)
    $rel = $Path.Substring($Base.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

function Format-Prerequisites {
    param($Prerequisites)
    $parts = @()
    if ($Prerequisites.PSObject.Properties.Name -contains 'businessCentral') {
        $bc = $Prerequisites.businessCentral
        $bcText = 'Business Central'
        if ($bc.deployment) { $bcText += " $($bc.deployment)" }
        if ($bc.minimumVersion) { $bcText += " $($bc.minimumVersion)+" }
        $parts += $bcText
    }
    if ($Prerequisites.PSObject.Properties.Name -contains 'apps') {
        foreach ($app in $Prerequisites.apps) {
            $appText = $app.name
            if ($app.required -eq $false) { $appText += ' (optional)' }
            $parts += $appText
        }
    }
    return ($parts -join ', ')
}

# --- Discover skills -------------------------------------------------------

$skillFiles = Get-ChildItem -Path $RepoRoot -Recurse -Filter 'skill.json' -File |
    Where-Object { $_.FullName -notmatch '[\\/](_site|node_modules|\.git|vendor)[\\/]' }

if (-not $skillFiles) {
    Write-Warning 'No skill.json files found. Nothing to generate.'
    return
}

$skills = foreach ($file in $skillFiles) {
    $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $dir = Split-Path -Parent $file.FullName
    $name = if ($json.PSObject.Properties.Name -contains 'name' -and $json.name) { $json.name } else { Split-Path -Leaf $dir }
    $readmeName = if ($json.PSObject.Properties.Name -contains 'readme' -and $json.readme) { $json.readme } else { 'README.md' }
    $relDir = Get-RelativePath -Base $RepoRoot -Path $dir
    $readmePath = Join-Path $dir $readmeName

    [pscustomobject]@{
        Name          = $name
        Title         = if ($json.PSObject.Properties.Name -contains 'title' -and $json.title) { $json.title } else { $name }
        Tldr          = if ($json.PSObject.Properties.Name -contains 'tldr') { $json.tldr } else { '' }
        RelDir        = $relDir
        ReadmeRelPath = "$relDir/$readmeName"
        ReadmePath    = $readmePath
        Prerequisites = if ($json.PSObject.Properties.Name -contains 'prerequisites') { Format-Prerequisites $json.prerequisites } else { '' }
        Tags          = if ($json.PSObject.Properties.Name -contains 'tags') { $json.tags } else { @() }
    }
}

$skills = $skills | Sort-Object Title

Write-Host "Discovered $($skills.Count) skill(s):"
$skills | ForEach-Object { Write-Host "  - $($_.Title) [$($_.RelDir)]" }

# --- README.md (repo-facing index) ----------------------------------------

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('# Business Central Skills')
[void]$sb.AppendLine()
[void]$sb.AppendLine('A collection of skills for Microsoft Dynamics 365 Business Central.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('> This list is generated automatically from each skill''s `skill.json` by')
[void]$sb.AppendLine('> [`scripts/Build-SkillIndex.ps1`](scripts/Build-SkillIndex.ps1). Do not edit it by hand.')
[void]$sb.AppendLine()
[void]$sb.AppendLine('## Skills')
[void]$sb.AppendLine()

foreach ($s in $skills) {
    [void]$sb.AppendLine("### [$($s.Title)]($($s.ReadmeRelPath))")
    [void]$sb.AppendLine()
    if ($s.Tldr) {
        [void]$sb.AppendLine($s.Tldr)
        [void]$sb.AppendLine()
    }
    if ($s.Prerequisites) {
        [void]$sb.AppendLine("**Prerequisites:** $($s.Prerequisites)")
        [void]$sb.AppendLine()
    }
}

$readmeOut = Join-Path $RepoRoot 'README.md'
$sb.ToString().TrimEnd() + "`n" | Set-Content -LiteralPath $readmeOut -Encoding utf8 -NoNewline
Write-Host "Wrote $readmeOut"

# --- index.md (Jekyll front page) -----------------------------------------

$idx = [System.Text.StringBuilder]::new()
[void]$idx.AppendLine('---')
[void]$idx.AppendLine('layout: default')
[void]$idx.AppendLine('title: Business Central Skills')
[void]$idx.AppendLine('---')
[void]$idx.AppendLine()
[void]$idx.AppendLine('# Business Central Skills')
[void]$idx.AppendLine()
[void]$idx.AppendLine('A collection of skills for Microsoft Dynamics 365 Business Central.')
[void]$idx.AppendLine()
[void]$idx.AppendLine('## Skills')
[void]$idx.AppendLine()

foreach ($s in $skills) {
    [void]$idx.AppendLine("### [$($s.Title)](skills/$($s.Name)/)")
    [void]$idx.AppendLine()
    if ($s.Tldr) {
        [void]$idx.AppendLine($s.Tldr)
        [void]$idx.AppendLine()
    }
    if ($s.Prerequisites) {
        [void]$idx.AppendLine("**Prerequisites:** $($s.Prerequisites)")
        [void]$idx.AppendLine()
    }
}

$indexOut = Join-Path $RepoRoot 'index.md'
$idx.ToString().TrimEnd() + "`n" | Set-Content -LiteralPath $indexOut -Encoding utf8 -NoNewline
Write-Host "Wrote $indexOut"

# --- Inject front matter into each skill's own README.md ------------------
# No copies: the skill's README becomes its own Jekyll page at /skills/<name>/.

# Strips a leading YAML front-matter block (optionally BOM-prefixed) if present.
$frontMatterPattern = '(?s)\A\uFEFF?---\r?\n.*?\r?\n---\r?\n'

foreach ($s in $skills) {
    if (-not (Test-Path -LiteralPath $s.ReadmePath)) {
        Write-Warning "README not found for '$($s.Name)' at $($s.ReadmePath); skipping."
        continue
    }
    $body = (Get-Content -LiteralPath $s.ReadmePath -Raw) -replace $frontMatterPattern, ''
    $body = $body.TrimStart("`r", "`n")

    $fm = [System.Text.StringBuilder]::new()
    [void]$fm.AppendLine('---')
    [void]$fm.AppendLine('layout: default')
    [void]$fm.AppendLine("title: $($s.Title)")
    [void]$fm.AppendLine("permalink: /skills/$($s.Name)/")
    [void]$fm.AppendLine('---')
    [void]$fm.AppendLine()

    ($fm.ToString() + $body) | Set-Content -LiteralPath $s.ReadmePath -Encoding utf8 -NoNewline
    Write-Host "Updated front matter in $($s.ReadmeRelPath)"
}

Write-Host 'Done.'
