#Requires -Version 7.0

<#
.SYNOPSIS
    Scans the whole WinGet community repository for packages whose installers
    come from GitHub releases and whose published version is behind the latest
    GitHub release.

.DESCRIPTION
    Replaces the old clone-and-walk approach (`check-winget-version.ps1`) with a
    three-stage pipeline that avoids both a full git clone and per-package REST
    calls:

      Stage 1 - Published versions come from the official WinGet source index
                (`source2.msix`, ~3 MB). It already contains the authoritative
                `latest_version` for all ~14k packages, so no manifest tree walk
                and no version sorting heuristics are required.

      Stage 2 - Installer URLs are read from `microsoft/winget-pkgs`. The
                manifest path of a package is fully derivable from its
                identifier and published version, so the scan reads only the
                ~14k manifests it actually needs. By default the repository
                tarball is streamed once and matching entries are pulled out in
                memory; `-WingetPkgsPath` reads an existing working tree instead.

      Stage 3 - Latest GitHub releases are resolved with batched GraphQL
                queries (100 repositories per request), reusing the module's
                rate-limit-aware GraphQL client. That turns thousands of REST
                calls into a few dozen requests.

    Results are compared with a shape-aware version comparison that only reports
    a package when GitHub is strictly newer, and tags each row with a confidence
    level so tag schemes that do not line up with WinGet versions can be
    triaged instead of silently producing false positives.

.PARAMETER OutputPath
    CSV report of outdated packages. Defaults to `winget-github-versions.csv`.

.PARAMETER MapPath
    CSV cache of every GitHub-hosted package and its resolved repository.
    Defaults to `data/github-package-map.csv`.

.PARAMETER CandidatePath
    YAML snippet with ready-to-paste `github-releases-monitored.yml` entries for
    high-confidence, not-yet-monitored packages.

.PARAMETER WingetPkgsPath
    Path to an existing `microsoft/winget-pkgs` working tree. When supplied,
    manifests are read from disk instead of downloading the repository tarball.

.PARAMETER CachePath
    Directory for the downloaded source index and repository tarball.

.PARAMETER IncludeMonitored
    Also report packages that are already listed in
    `github-releases-monitored.yml`.

.PARAMETER MinimumConfidence
    Lowest confidence level to include in the report. High, Medium or Low.

.PARAMETER UseCachedMap
    Skips stage 2 and reuses the existing package map CSV. Useful for re-running
    the GitHub release comparison without touching the manifest source.

.PARAMETER Top
    Limits stage 2/3 to the first N GitHub-hosted packages. Intended for smoke
    tests.

.EXAMPLE
    ./scripts/Find-OutdatedGitHubPackages.ps1 -Verbose

.EXAMPLE
    ./scripts/Find-OutdatedGitHubPackages.ps1 -WingetPkgsPath 'u:\_git\winget-pkgs' -MinimumConfidence High
#>
[CmdletBinding()]
param(
    [string] $OutputPath,
    [string] $MapPath,
    [string] $CandidatePath,
    [string] $WingetPkgsPath,
    [string] $CachePath,
    [switch] $IncludeMonitored,
    [ValidateSet('High', 'Medium', 'Low')] [string] $MinimumConfidence = 'Medium',
    [switch] $UseCachedMap,
    [int] $Top = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\WingetMaintainerModule') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repoRoot 'winget-github-versions.csv' }
if ([string]::IsNullOrWhiteSpace($MapPath)) { $MapPath = Join-Path $repoRoot 'data\github-package-map.csv' }
if ([string]::IsNullOrWhiteSpace($CandidatePath)) { $CandidatePath = Join-Path $repoRoot 'data\github-outdated-candidates.yml' }
if ([string]::IsNullOrWhiteSpace($CachePath)) { $CachePath = Join-Path ([System.IO.Path]::GetTempPath()) 'winget-scan-cache' }

$tarballUri = 'https://codeload.github.com/microsoft/winget-pkgs/tar.gz/refs/heads/master'
$githubReleaseUrlPattern = '^https?://github\.com/(?<owner>[^/\s]+)/(?<repo>[^/\s]+)/releases/(?:download|latest/download)/'

#region helpers

function Get-MonitoredPackageId {
    param([string] $Path)

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $Path)) { return $ids }

    foreach ($match in [regex]::Matches((Get-Content -LiteralPath $Path -Raw), '(?m)^\s*-\s*id:\s*"?([^"\r\n]+?)"?\s*$')) {
        [void]$ids.Add($match.Groups[1].Value.Trim())
    }

    return $ids
}

function Get-IgnoredPackagePattern {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    return @(Import-Csv -LiteralPath $Path |
        ForEach-Object { $_.package_identifier } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ManifestDirectory {
    <#
        winget-pkgs stores every manifest under a path that is fully derivable
        from the package identifier and version, e.g. `Gyan.FFmpeg.Essentials`
        at 7.0.2 lives in manifests/g/Gyan/FFmpeg/Essentials/7.0.2/.
    #>
    param([string] $PackageIdentifier, [string] $Version)

    $first = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    return "manifests/$first/$($PackageIdentifier.Replace('.', '/'))/$Version"
}

function Get-InstallerUrlFromManifest {
    param([string] $Content)

    return @([regex]::Matches($Content, '(?m)^\s*InstallerUrl\s*:\s*(\S.*?)\s*$') |
        ForEach-Object { $_.Groups[1].Value.Trim().Trim('"', "'") } |
        Where-Object { $_ -match '^https?://' })
}

function ConvertTo-UrlTemplate {
    param([string] $Url, [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $Url }
    return [regex]::Replace($Url, [regex]::Escape($Version), '{VERSION}')
}

function ConvertTo-ComparableVersion {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $text = $Value.Trim().Trim('"', "'")
    $text = Remove-GHTagPrefixes -Tag $text
    # Tags such as `release-1.2.3`, `app_v2.0` or `2024-06-01` still need the
    # leading label removed before the numeric payload can be compared.
    $text = $text -replace '^(?i)(release|rel|ver|version|build)[-_.]?', ''
    $text = $text -replace '^(?i)v(?=\d)', ''

    return $text.Trim()
}

function Compare-PackageVersion {
    <#
    .SYNOPSIS
        Decides whether a GitHub release is strictly newer than the published
        WinGet version, and how much that verdict can be trusted.
    #>
    param([string] $WingetVersion, [string] $ReleaseVersion)

    $left = ConvertTo-ComparableVersion -Value $WingetVersion
    $right = ConvertTo-ComparableVersion -Value $ReleaseVersion

    $result = [PSCustomObject]@{
        IsNewer          = $false
        Confidence       = 'Low'
        NormalizedWinget = $left
        NormalizedGitHub = $right
    }

    if ([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { return $result }
    if ($left -eq $right) { $result.Confidence = 'High'; return $result }

    $leftParts = @([regex]::Matches($left, '\d+') | ForEach-Object { [long]$_.Value })
    $rightParts = @([regex]::Matches($right, '\d+') | ForEach-Object { [long]$_.Value })
    if ($leftParts.Count -eq 0 -or $rightParts.Count -eq 0) { return $result }

    $shared = [Math]::Min($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $shared; $i++) {
        if ($rightParts[$i] -gt $leftParts[$i]) { $result.IsNewer = $true; break }
        if ($rightParts[$i] -lt $leftParts[$i]) { return $result }
    }

    if (-not $result.IsNewer) {
        # All shared segments matched; a longer, non-zero tail wins.
        if ($rightParts.Count -le $leftParts.Count) { return $result }
        $tail = $rightParts[$shared..($rightParts.Count - 1)] | Where-Object { $_ -ne 0 }
        if (-not $tail) { return $result }
        $result.IsNewer = $true
    }

    $isSimple = { param($v) $v -match '^\d+(\.\d+)*$' }
    $leftSimple = & $isSimple $left
    $rightSimple = & $isSimple $right

    if ($leftSimple -and $rightSimple -and $leftParts.Count -eq $rightParts.Count) {
        $result.Confidence = 'High'
    }
    elseif ($leftSimple -and $rightSimple) {
        $result.Confidence = 'Medium'
    }
    elseif ($left -match '^\d' -and $right -match '^\d') {
        $result.Confidence = 'Medium'
    }

    # Segment shapes that differ this much usually mean the tag scheme and the
    # WinGet version scheme are simply unrelated.
    if ([Math]::Abs($leftParts.Count - $rightParts.Count) -ge 2) { $result.Confidence = 'Low' }
    if ($right -match '(?i)(alpha|beta|rc\d|nightly|preview|snapshot|canary|dev)') { $result.Confidence = 'Low' }

    return $result
}

function Get-ManifestContentFromTarball {
    <#
    .SYNOPSIS
        Streams the winget-pkgs tarball once and returns only the manifests that
        belong to the requested version directories.

    .DESCRIPTION
        Extracting all ~250k manifest files to disk is far slower than a single
        streamed pass, so entries are filtered against a hash set of wanted
        directories and read straight out of the decompression stream.
    #>
    param(
        [Parameter(Mandatory = $true)] [System.Collections.Generic.HashSet[string]] $WantedDirectories,
        [Parameter(Mandatory = $true)] [string] $TarballPath
    )

    $contentByDirectory = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $fileStream = [System.IO.File]::OpenRead($TarballPath)
    try {
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $tarReader = [System.Formats.Tar.TarReader]::new($gzipStream)
            try {
                $seen = 0
                while ($null -ne ($entry = $tarReader.GetNextEntry($false))) {
                    $seen++
                    if (($seen % 25000) -eq 0) {
                        Write-Progress -Activity 'Streaming winget-pkgs tarball' -Status "$seen entries, $($contentByDirectory.Count) manifests matched"
                    }

                    $name = $entry.Name
                    if (-not $name.EndsWith('.yaml', [System.StringComparison]::OrdinalIgnoreCase)) { continue }

                    $slash = $name.LastIndexOf('/')
                    if ($slash -lt 0) { continue }

                    # Drop the `winget-pkgs-master/` archive prefix.
                    $directory = $name.Substring(0, $slash)
                    $prefixEnd = $directory.IndexOf('/')
                    if ($prefixEnd -lt 0) { continue }
                    $directory = $directory.Substring($prefixEnd + 1)

                    if (-not $WantedDirectories.Contains($directory)) { continue }
                    if ($contentByDirectory.ContainsKey($directory) -and $name -notmatch '\.installer\.yaml$') { continue }
                    if ($null -eq $entry.DataStream) { continue }

                    $reader = [System.IO.StreamReader]::new($entry.DataStream, [System.Text.Encoding]::UTF8, $true, 4096, $true)
                    try {
                        $text = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }

                    if ($text -match 'InstallerUrl') {
                        $contentByDirectory[$directory] = $text
                    }
                }
            }
            finally { $tarReader.Dispose() }
        }
        finally { $gzipStream.Dispose() }
    }
    finally { $fileStream.Dispose() }

    Write-Progress -Activity 'Streaming winget-pkgs tarball' -Completed
    return $contentByDirectory
}

function Invoke-GraphQlBatch {
    <#
    .SYNOPSIS
        Resolves `latestRelease.tagName` for a set of owner/repo pairs.

    .DESCRIPTION
        GitHub returns partial data plus per-alias errors for repositories that
        were renamed or deleted, which is the normal case in a repository-wide
        scan, so a failed alias simply yields no tag. A failing batch is split in
        half so one bad request cannot lose ~100 results.
    #>
    param(
        [Parameter(Mandatory = $true)] [string[]] $Repositories,
        [Parameter(Mandatory = $true)] [hashtable] $Result,
        [Parameter(Mandatory = $true)] [scriptblock] $Invoker
    )

    if ($Repositories.Count -eq 0) { return }

    $fields = for ($i = 0; $i -lt $Repositories.Count; $i++) {
        $owner, $name = $Repositories[$i].Split('/', 2)
        $ownerLiteral = '"' + $owner.Replace('\', '\\').Replace('"', '\"') + '"'
        $nameLiteral = '"' + $name.Replace('\', '\\').Replace('"', '\"') + '"'
        "  r$($i): repository(owner: $ownerLiteral, name: $nameLiteral) { nameWithOwner latestRelease { tagName name publishedAt } }"
    }

    $query = "query {`n" + ($fields -join "`n") + "`n}"

    try {
        $response = & $Invoker $query
    }
    catch {
        if ($Repositories.Count -eq 1) {
            Write-Verbose "GraphQL lookup failed for $($Repositories[0]): $($_.Exception.Message)"
            $Result[$Repositories[0]] = $null
            return
        }

        $half = [int][Math]::Floor($Repositories.Count / 2)
        Invoke-GraphQlBatch -Repositories $Repositories[0..($half - 1)] -Result $Result -Invoker $Invoker
        Invoke-GraphQlBatch -Repositories $Repositories[$half..($Repositories.Count - 1)] -Result $Result -Invoker $Invoker
        return
    }

    $dataProperty = if ($null -ne $response) { $response.PSObject.Properties['data'] } else { $null }
    $data = if ($dataProperty) { $dataProperty.Value } else { $null }

    for ($i = 0; $i -lt $Repositories.Count; $i++) {
        $node = if ($null -ne $data) { $data.PSObject.Properties["r$i"] } else { $null }
        $repository = if ($node) { $node.Value } else { $null }
        $release = if ($null -ne $repository) { $repository.PSObject.Properties['latestRelease'].Value } else { $null }
        $Result[$Repositories[$i]] = if ($null -ne $release) { [string]$release.tagName } else { $null }
    }
}

#endregion helpers

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# --- Stage 1: published versions from the WinGet source index ----------------

Write-Host 'Stage 1/3: reading the WinGet source index...' -ForegroundColor Cyan
$indexPackages = @(Get-WingetSourceIndexPackage -CachePath (Join-Path $CachePath 'index'))
Write-Host "  $($indexPackages.Count) packages published in the community source."

$monitoredIds = Get-MonitoredPackageId -Path (Join-Path $repoRoot 'github-releases-monitored.yml')
$ignoredPatterns = Get-IgnoredPackagePattern -Path (Join-Path $repoRoot 'scripts\package-cleanup\ignored_packages.csv')
Write-Host "  $($monitoredIds.Count) packages already monitored, $($ignoredPatterns.Count) ignore patterns loaded."

# --- Stage 2: installer URLs from winget-pkgs manifests ----------------------

$mapRows = [System.Collections.Generic.List[object]]::new()

if ($UseCachedMap) {
    if (-not (Test-Path -LiteralPath $MapPath)) {
        throw "-UseCachedMap was specified but '$MapPath' does not exist. Run the script once without it."
    }

    Write-Host 'Stage 2/3: reusing the cached package map...' -ForegroundColor Cyan
    $mapRows.AddRange([object[]]@(Import-Csv -LiteralPath $MapPath))
}
else {
    Write-Host 'Stage 2/3: resolving GitHub repositories from winget-pkgs manifests...' -ForegroundColor Cyan

    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $packageByDirectory = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($package in $indexPackages) {
        $directory = Get-ManifestDirectory -PackageIdentifier $package.PackageIdentifier -Version $package.WingetVersion
        if ($wanted.Add($directory)) { $packageByDirectory[$directory] = $package }
    }

    if ($WingetPkgsPath) {
        if (-not (Test-Path -LiteralPath $WingetPkgsPath)) { throw "WingetPkgsPath '$WingetPkgsPath' does not exist." }

        $contentByDirectory = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $processed = 0
        foreach ($directory in $wanted) {
            $processed++
            if (($processed % 500) -eq 0) {
                Write-Progress -Activity 'Reading local winget-pkgs manifests' -Status "$processed/$($wanted.Count)" -PercentComplete (100 * $processed / $wanted.Count)
            }

            $full = Join-Path $WingetPkgsPath ($directory -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $full)) { continue }

            $manifest = Get-ChildItem -LiteralPath $full -Filter '*.installer.yaml' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $manifest) {
                $manifest = Get-ChildItem -LiteralPath $full -Filter '*.yaml' -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
            }
            if (-not $manifest) { continue }

            $contentByDirectory[$directory] = Get-Content -LiteralPath $manifest.FullName -Raw
        }
        Write-Progress -Activity 'Reading local winget-pkgs manifests' -Completed
    }
    else {
        $tarballPath = Join-Path (New-Item -ItemType Directory -Path $CachePath -Force).FullName 'winget-pkgs-master.tar.gz'
        $needsDownload = -not (Test-Path -LiteralPath $tarballPath) -or
            ((Get-Item -LiteralPath $tarballPath).LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddHours(-12))

        if ($needsDownload) {
            Write-Host "  downloading $tarballUri ..."
            $previousProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $tarballUri -OutFile $tarballPath -TimeoutSec 1800 }
            finally { $ProgressPreference = $previousProgress }
        }
        else {
            Write-Host "  re-using cached tarball at $tarballPath"
        }

        Write-Host "  tarball size: $([math]::Round((Get-Item -LiteralPath $tarballPath).Length / 1MB, 1)) MB"
        $contentByDirectory = Get-ManifestContentFromTarball -WantedDirectories $wanted -TarballPath $tarballPath
    }

    Write-Host "  $($contentByDirectory.Count) of $($wanted.Count) manifests located."

    foreach ($pair in $contentByDirectory.GetEnumerator()) {
        $package = $packageByDirectory[$pair.Key]
        $urls = Get-InstallerUrlFromManifest -Content $pair.Value
        $githubUrls = @($urls | Where-Object { $_ -match $githubReleaseUrlPattern })
        if ($githubUrls.Count -eq 0) { continue }

        $null = $githubUrls[0] -match $githubReleaseUrlPattern
        $owner = $Matches['owner']
        $repo = $Matches['repo']

        # Multi-architecture packages list one InstallerUrl per architecture.
        # github-releases-monitored.yml expects them space-joined, so keep every
        # URL that belongs to the same repository instead of only the first.
        $sameRepoUrls = @($githubUrls |
                Where-Object { $_ -match "^https?://github\.com/$([regex]::Escape($owner))/$([regex]::Escape($repo))/" } |
                Select-Object -Unique)

        $templates = @($sameRepoUrls |
                ForEach-Object { ConvertTo-UrlTemplate -Url $_ -Version $package.WingetVersion } |
                Select-Object -Unique)

        $mapRows.Add([PSCustomObject]@{
                PackageId         = $package.PackageIdentifier
                PackageName       = $package.PackageName
                WingetVersion     = $package.WingetVersion
                GitHubOwner       = $owner
                GitHubRepo        = $repo
                InstallerUrl      = $sameRepoUrls -join ' '
                InstallerUrlCount = $templates.Count
                UrlTemplate       = $templates -join ' '
                ManifestPath      = "$($pair.Key)/$($package.PackageIdentifier).installer.yaml"
            })
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $MapPath) -Force | Out-Null
    $mapRows | Sort-Object PackageId | Export-Csv -LiteralPath $MapPath -NoTypeInformation -Encoding utf8
}

Write-Host "  $($mapRows.Count) packages install from GitHub releases."

$candidatesForLookup = @($mapRows | Sort-Object PackageId)
if ($Top -gt 0) { $candidatesForLookup = @($candidatesForLookup | Select-Object -First $Top) }

# --- Stage 3: latest GitHub release per repository --------------------------

Write-Host 'Stage 3/3: resolving latest GitHub releases (batched GraphQL)...' -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and [string]::IsNullOrWhiteSpace($env:WINGET_UPSTREAM_READ_TOKEN)) {
    $ghToken = & { gh auth token } 2>$null
    if (-not [string]::IsNullOrWhiteSpace($ghToken)) {
        $env:GITHUB_TOKEN = "$ghToken".Trim()
        Write-Verbose 'Using the token from `gh auth token` for GraphQL requests.'
    }
}

$module = Get-Module WingetMaintainerModule
$invoker = {
    param($Query)
    & $module { param($q) Invoke-WingetPrecheckGraphQlRequest -Query $q } $Query
}.GetNewClosure()

$uniqueRepositories = @($candidatesForLookup |
    ForEach-Object { '{0}/{1}' -f $_.GitHubOwner, $_.GitHubRepo } |
    Sort-Object -Unique)

Write-Host "  $($uniqueRepositories.Count) unique repositories to query."

$tagByRepository = @{}
$batchSize = 100
for ($offset = 0; $offset -lt $uniqueRepositories.Count; $offset += $batchSize) {
    $slice = @($uniqueRepositories[$offset..([Math]::Min($offset + $batchSize, $uniqueRepositories.Count) - 1)])
    Write-Progress -Activity 'Querying GitHub releases' `
        -Status "$offset/$($uniqueRepositories.Count)" `
        -PercentComplete (100 * $offset / $uniqueRepositories.Count)
    Invoke-GraphQlBatch -Repositories $slice -Result $tagByRepository -Invoker $invoker
}
Write-Progress -Activity 'Querying GitHub releases' -Completed

$withRelease = @($tagByRepository.Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
Write-Host "  $withRelease repositories reported a latest release."

# --- Report -----------------------------------------------------------------

$confidenceRank = @{ High = 3; Medium = 2; Low = 1 }
$report = [System.Collections.Generic.List[object]]::new()

foreach ($row in $candidatesForLookup) {
    $repository = '{0}/{1}' -f $row.GitHubOwner, $row.GitHubRepo
    $tag = [string]$tagByRepository[$repository]
    if ([string]::IsNullOrWhiteSpace($tag)) { continue }

    $comparison = Compare-PackageVersion -WingetVersion $row.WingetVersion -ReleaseVersion $tag
    if (-not $comparison.IsNewer) { continue }
    if ($confidenceRank[$comparison.Confidence] -lt $confidenceRank[$MinimumConfidence]) { continue }

    $isMonitored = $monitoredIds.Contains($row.PackageId)
    if ($isMonitored -and -not $IncludeMonitored) { continue }

    $isIgnored = $false
    foreach ($pattern in $ignoredPatterns) {
        if ($row.PackageId -like $pattern) { $isIgnored = $true; break }
    }
    if ($isIgnored) { continue }

    $report.Add([PSCustomObject]@{
            PackageId         = $row.PackageId
            CurrentVersion    = $row.WingetVersion
            LatestVersion     = $comparison.NormalizedGitHub
            LatestTag         = $tag
            GitHubOwner       = $row.GitHubOwner
            GitHubRepo        = $row.GitHubRepo
            GitHubUrl         = "https://github.com/$repository"
            InstallerUrl      = $row.InstallerUrl
            InstallerUrlCount = $row.InstallerUrlCount
            UrlTemplate       = $row.UrlTemplate
            ManifestPath      = $row.ManifestPath
            Confidence        = $comparison.Confidence
            Monitored         = $isMonitored
        })
}

$ordered = @($report | Sort-Object @{ Expression = { $confidenceRank[$_.Confidence] }; Descending = $true }, PackageId)
$ordered | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8

$snippet = foreach ($row in @($ordered | Where-Object { $_.Confidence -eq 'High' -and -not $_.Monitored })) {
    "          - id: `"$($row.PackageId)`""
    "            repo: `"$($row.GitHubOwner)/$($row.GitHubRepo)`""
    "            url: `"$($row.UrlTemplate)`""
}
New-Item -ItemType Directory -Path (Split-Path -Parent $CandidatePath) -Force | Out-Null
Set-Content -LiteralPath $CandidatePath -Value ($snippet -join "`n") -Encoding utf8

$stopwatch.Stop()

Write-Host ''
Write-Host "Outdated packages found: $($ordered.Count)" -ForegroundColor Green
$ordered | Group-Object Confidence | Sort-Object Name | ForEach-Object { Write-Host "  $($_.Name): $($_.Count)" }
Write-Host "Report      : $OutputPath"
Write-Host "Package map : $MapPath"
Write-Host "Candidates  : $CandidatePath"
Write-Host "Elapsed     : $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))"
