#Requires -Version 7.0

<#
.SYNOPSIS
    Finds packages in `github-releases-monitored.yml` that are active but were
    previously disabled on purpose, and comments them back out.

.DESCRIPTION
    A repository-wide scan only knows that a newer GitHub release exists. It
    cannot know that a package was deliberately parked earlier because Komac
    mangles its installer URLs, the upstream repository was taken down, or the
    asset layout needs a reviewed override. Re-adding those packages silently
    undoes a maintainer decision.

    The monitored file records those decisions in two shapes:

      1. A commented-out YAML entry:
             #          - id: "ransome1.sleek"
         optionally preceded or followed by the reason.

      2. A prose exclusion note:
             # Gyan.FFmpeg.Essentials is excluded: 9.0 removed the prior asset layout.

    Both are collected, matched against the active entries, and any collision is
    commented out again with the original reason attached.

.PARAMETER MonitoredPath
    Path to github-releases-monitored.yml.

.PARAMETER CandidatePath
    Restricts changes to identifiers present in this YAML snippet, so a bulk
    scan import can be cleaned up without touching long-standing entries.
    Collisions outside the snippet are reported but left alone.

.PARAMETER Apply
    Writes the changes. Without it the script only reports.

.EXAMPLE
    ./scripts/Disable-ReAddedExcludedPackages.ps1

.EXAMPLE
    ./scripts/Disable-ReAddedExcludedPackages.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string] $MonitoredPath,
    [string] $CandidatePath,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($MonitoredPath)) { $MonitoredPath = Join-Path $repoRoot 'github-releases-monitored.yml' }
if ([string]::IsNullOrWhiteSpace($CandidatePath)) { $CandidatePath = Join-Path $repoRoot 'data\github-outdated-candidates-unmaintained.yml' }

$lines = [System.Collections.Generic.List[string]]::new()
$lines.AddRange([string[]](Get-Content -LiteralPath $MonitoredPath))

$entryPattern = '^(?<indent>\s*)-\s*id:\s*"?(?<id>[^"\r\n]+?)"?\s*$'
$commentedEntryPattern = '^\s*#\s*-\s*id:\s*"?(?<id>[^"#\r\n]+?)"?\s*(?:#\s*(?<reason>.*?)\s*)?$'
$commentedEntryDashReason = '^\s*#\s*-\s*id:\s*"(?<id>[^"]+)"\s*(?<reason>-\s*.+?)\s*$'
$exclusionNotePattern = '^\s*#\s*(?<id>[A-Za-z0-9][A-Za-z0-9._+-]*\.[A-Za-z0-9._+-]+)\s+is excluded:\s*(?<reason>.+?)\s*$'

# --- collect deliberately disabled identifiers -------------------------------

$disabled = [ordered]@{}

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]

    if ($line -match $exclusionNotePattern) {
        $disabled[$Matches['id']] = [PSCustomObject]@{
            Reason = $Matches['reason']
            Line   = $i + 1
            Kind   = 'ExclusionNote'
        }
        continue
    }

    if ($line -notmatch '^\s*#') { continue }

    $reason = ''
    $id = ''
    if ($line -match $commentedEntryDashReason) {
        $id = $Matches['id']
        $reason = $Matches['reason'].TrimStart('-', ' ')
    }
    elseif ($line -match $commentedEntryPattern) {
        $id = $Matches['id']
        $reason = if ($Matches.ContainsKey('reason')) { [string]$Matches['reason'] } else { '' }
    }
    else {
        continue
    }

    $id = $id.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { continue }

    # A standalone comment directly above a commented block usually carries the
    # reason, e.g. "# temporarily disabled as komac mixes up the installer URLs".
    # Commented-out YAML keys from the preceding entry are not reasons.
    if ([string]::IsNullOrWhiteSpace($reason) -and $i -gt 0) {
        $previous = $lines[$i - 1]
        $isCommentedYamlKey = $previous -match '^\s*#\s*-?\s*(id|repo|url|with|tagPattern|versionSource|allowStructuralRewrite|overridePack|pre-release)\s*:'
        if (-not $isCommentedYamlKey -and $previous -match '^\s*#\s*(?<text>[^-#\s][^:]*)\s*$') {
            $reason = $Matches['text'].Trim()
        }
    }

    if (-not $disabled.Contains($id)) {
        $disabled[$id] = [PSCustomObject]@{
            Reason = $reason
            Line   = $i + 1
            Kind   = 'CommentedEntry'
        }
    }
}

Write-Host "Disabled identifiers found: $($disabled.Count)" -ForegroundColor Cyan

# --- collect active entries and their block extent ---------------------------

$activeBlocks = [System.Collections.Generic.List[object]]::new()

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*#') { continue }
    if ($lines[$i] -notmatch $entryPattern) { continue }

    $id = $Matches['id'].Trim()
    $start = $i
    $end = $i

    # The block runs until the next entry, comment or blank line.
    for ($j = $i + 1; $j -lt $lines.Count; $j++) {
        $next = $lines[$j]
        if ([string]::IsNullOrWhiteSpace($next)) { break }
        if ($next -match '^\s*#') { break }
        if ($next -match $entryPattern) { break }
        if ($next -notmatch '^\s*[A-Za-z][A-Za-z0-9]*\s*:') { break }
        $end = $j
    }

    $activeBlocks.Add([PSCustomObject]@{ Id = $id; Start = $start; End = $end })
    $i = $end
}

Write-Host "Active entries found: $($activeBlocks.Count)"

$candidateIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
if (Test-Path -LiteralPath $CandidatePath) {
    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $CandidatePath -Raw), '(?m)^\s*-\s*id:\s*"([^"]+)"')) {
        [void]$candidateIds.Add($match.Groups[1].Value)
    }
    Write-Host "Candidate identifiers loaded: $($candidateIds.Count)"
}

# --- match --------------------------------------------------------------------

$inScope = [System.Collections.Generic.List[object]]::new()
$outOfScope = [System.Collections.Generic.List[object]]::new()

foreach ($block in $activeBlocks) {
    if (-not $disabled.Contains($block.Id)) { continue }

    $record = [PSCustomObject]@{
        Id          = $block.Id
        ActiveLine  = $block.Start + 1
        Reason      = $disabled[$block.Id].Reason
        Kind        = $disabled[$block.Id].Kind
        DisabledAt  = $disabled[$block.Id].Line
        Start       = $block.Start
        End         = $block.End
    }

    if ($candidateIds.Count -eq 0 -or $candidateIds.Contains($block.Id)) {
        $inScope.Add($record)
    }
    else {
        $outOfScope.Add($record)
    }
}

Write-Host ''
Write-Host "Re-added packages that were previously disabled: $($inScope.Count)" -ForegroundColor Yellow
$inScope | Sort-Object Id | Format-Table Id, ActiveLine, Kind, @{ n = 'Reason'; e = { if ($_.Reason) { $_.Reason } else { '(no reason recorded)' } } } -AutoSize |
    Out-String -Width 200 | Write-Host

if ($outOfScope.Count -gt 0) {
    Write-Host "Pre-existing collisions NOT touched (outside the candidate list): $($outOfScope.Count)" -ForegroundColor DarkYellow
    $outOfScope | Sort-Object Id | Format-Table Id, ActiveLine, Kind, @{ n = 'Reason'; e = { if ($_.Reason) { $_.Reason } else { '(no reason recorded)' } } } -AutoSize |
        Out-String -Width 200 | Write-Host
}

if (-not $Apply) {
    Write-Host 'Report only. Re-run with -Apply to comment these entries out.' -ForegroundColor Cyan
    return
}

if ($inScope.Count -eq 0) {
    Write-Host 'Nothing to change.'
    return
}

# --- rewrite ------------------------------------------------------------------

# Work back to front so earlier line indexes stay valid.
foreach ($record in ($inScope | Sort-Object Start -Descending)) {
    for ($i = $record.Start; $i -le $record.End; $i++) {
        $lines[$i] = '#' + $lines[$i]
    }

    $reason = if ([string]::IsNullOrWhiteSpace($record.Reason)) {
        'previously disabled; re-added by a scan, see the earlier commented entry'
    }
    else {
        $record.Reason
    }

    $lines.Insert($record.Start, "          # $($record.Id) is excluded: $reason")
}

Set-Content -LiteralPath $MonitoredPath -Value $lines -Encoding utf8
Write-Host "Commented out $($inScope.Count) re-added entr$(if ($inScope.Count -eq 1) { 'y' } else { 'ies' }) in $MonitoredPath" -ForegroundColor Green
