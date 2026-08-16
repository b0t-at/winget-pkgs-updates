#Requires -Version 7.0

<#
.SYNOPSIS
    Decides which scan candidates are genuinely unclaimed, by checking whether
    the new version is already published in `microsoft/winget-pkgs` or already
    has a pull request.

.DESCRIPTION
    The maintenance question that matters is narrow: is somebody already
    handling *this specific version*? Broad "was there any activity lately"
    heuristics reject packages that nobody is actually going to update.

    Two checks decide the verdict, both scoped to the version the scan found:

      1. Published    - the version directory already exists under the package's
                        manifest path on `master`. The source index lags the
                        repository by up to a day, so this catches versions that
                        landed between the index build and the scan.
      2. PrForLatest  - an open or merged pull request whose title carries both
                        the package identifier and that version.

    Anything else is unclaimed and safe to adopt.

    Both checks are batched with GraphQL aliases. Published-version lookups read
    the repository tree, so they are cheap; pull request lookups use GitHub
    Search, which tokenizes on punctuation, so every returned title is
    re-validated client-side against the exact identifier and version. Closed
    but unmerged pull requests are ignored, matching the duplicate-detection
    rules the submission pipeline already uses.

.PARAMETER InputPath
    Verified candidate report from Test-OutdatedPackageCandidate.ps1.

.PARAMETER OutputPath
    CSV report with the verdict for every candidate.

.PARAMETER BatchSize
    Packages per GraphQL search request. GitHub applies a secondary rate limit
    to search, so this is deliberately small.

.PARAMETER TreeBatchSize
    Packages per published-version request. Tree reads are cheap, so this can be
    considerably larger than BatchSize.

.PARAMETER Top
    Only classify the first N candidates. Intended for smoke tests.

.EXAMPLE
    ./scripts/Test-PackageMaintenanceStatus.ps1

.EXAMPLE
    ./scripts/Test-PackageMaintenanceStatus.ps1 -Top 30 -Verbose
#>
[CmdletBinding()]
param(
    [string] $InputPath,
    [string] $OutputPath,
    [int] $BatchSize = 10,
    [int] $TreeBatchSize = 30,
    [int] $Top = 0
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'modules\WingetMaintainerModule') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($InputPath)) { $InputPath = Join-Path $repoRoot 'data\github-outdated-verified.csv' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repoRoot 'data\github-package-maintenance.csv' }

$candidates = @(Import-Csv -LiteralPath $InputPath | Where-Object { $_.ProbeStatus -eq 'Ok' } | Sort-Object PackageId)
if ($Top -gt 0) { $candidates = @($candidates | Select-Object -First $Top) }

Write-Host "Classifying $($candidates.Count) verified candidate(s)..." -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and [string]::IsNullOrWhiteSpace($env:WINGET_UPSTREAM_READ_TOKEN)) {
    $ghToken = & { gh auth token } 2>$null
    if (-not [string]::IsNullOrWhiteSpace($ghToken)) { $env:GITHUB_TOKEN = "$ghToken".Trim() }
}

$module = Get-Module WingetMaintainerModule
$invoker = {
    param($Query)
    & $module { param($q) Invoke-WingetPrecheckGraphQlRequest -Query $q } $Query
}.GetNewClosure()

function ConvertTo-GraphQlLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

# --- pass 1: is the version already published in winget-pkgs? ----------------

function Invoke-PublishedVersionBatch {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Packages,
        [Parameter(Mandatory = $true)] [hashtable] $Result,
        [Parameter(Mandatory = $true)] [scriptblock] $Invoker,
        [Parameter(Mandatory = $true)] $Module
    )

    if ($Packages.Count -eq 0) { return }

    $fields = for ($i = 0; $i -lt $Packages.Count; $i++) {
        $relative = & $Module { param($id) Get-WingetPackageRelativePath -PackageIdentifier $id } $Packages[$i].PackageId
        $expression = ConvertTo-GraphQlLiteral -Value "master:$relative"
        "    p$($i): object(expression: $expression) { ... on Tree { entries { name type } } }"
    }

    $query = "query {`n  repository(owner: `"microsoft`", name: `"winget-pkgs`") {`n" + ($fields -join "`n") + "`n  }`n}"

    try {
        $response = & $Invoker $query
    }
    catch {
        if ($Packages.Count -eq 1) {
            Write-Verbose "Published-version lookup failed for $($Packages[0].PackageId): $($_.Exception.Message)"
            $Result[$Packages[0].PackageId] = $null
            return
        }

        $half = [int][Math]::Floor($Packages.Count / 2)
        Invoke-PublishedVersionBatch -Packages $Packages[0..($half - 1)] -Result $Result -Invoker $Invoker -Module $Module
        Invoke-PublishedVersionBatch -Packages $Packages[$half..($Packages.Count - 1)] -Result $Result -Invoker $Invoker -Module $Module
        return
    }

    $dataProperty = if ($null -ne $response) { $response.PSObject.Properties['data'] } else { $null }
    $data = if ($dataProperty) { $dataProperty.Value } else { $null }
    $repositoryProperty = if ($null -ne $data) { $data.PSObject.Properties['repository'] } else { $null }
    $repository = if ($repositoryProperty) { $repositoryProperty.Value } else { $null }

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $treeProperty = if ($null -ne $repository) { $repository.PSObject.Properties["p$i"] } else { $null }
        $tree = if ($treeProperty) { $treeProperty.Value } else { $null }

        if ($null -eq $tree) {
            $Result[$Packages[$i].PackageId] = $null
            continue
        }

        $entriesProperty = $tree.PSObject.Properties['entries']
        $entries = if ($entriesProperty -and $null -ne $entriesProperty.Value) { @($entriesProperty.Value) } else { @() }
        $Result[$Packages[$i].PackageId] = [string[]]@(
            $entries | Where-Object { $_.type -eq 'tree' } | ForEach-Object { [string]$_.name }
        )
    }
}

$publishedByPackage = @{}
for ($offset = 0; $offset -lt $candidates.Count; $offset += $TreeBatchSize) {
    $slice = @($candidates[$offset..([Math]::Min($offset + $TreeBatchSize, $candidates.Count) - 1)])
    Write-Progress -Activity 'Reading published versions from winget-pkgs' `
        -Status "$offset/$($candidates.Count)" `
        -PercentComplete (100 * $offset / $candidates.Count)
    Invoke-PublishedVersionBatch -Packages $slice -Result $publishedByPackage -Invoker $invoker -Module $module
}
Write-Progress -Activity 'Reading published versions from winget-pkgs' -Completed

# --- pass 2: is there a pull request for exactly this version? ---------------

function Invoke-VersionPrSearchBatch {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Packages,
        [Parameter(Mandatory = $true)] [hashtable] $Result,
        [Parameter(Mandatory = $true)] [scriptblock] $Invoker
    )

    if ($Packages.Count -eq 0) { return }

    $fields = for ($i = 0; $i -lt $Packages.Count; $i++) {
        $id = $Packages[$i].PackageId
        $version = $Packages[$i].LatestVersion
        $search = "repo:microsoft/winget-pkgs is:pr in:title `"$($id.Replace('"', '\"'))`" `"$($version.Replace('"', '\"'))`""
        $literal = ConvertTo-GraphQlLiteral -Value $search
        "  v$($i): search(query: $literal, type: ISSUE, first: 15) { nodes { ... on PullRequest { number title state url createdAt mergedAt author { login } } } }"
    }

    $query = "query {`n" + ($fields -join "`n") + "`n}"

    try {
        $response = & $Invoker $query
    }
    catch {
        if ($Packages.Count -eq 1) {
            Write-Verbose "Version PR search failed for $($Packages[0].PackageId): $($_.Exception.Message)"
            $Result[$Packages[0].PackageId] = $null
            return
        }

        $half = [int][Math]::Floor($Packages.Count / 2)
        Invoke-VersionPrSearchBatch -Packages $Packages[0..($half - 1)] -Result $Result -Invoker $Invoker
        Invoke-VersionPrSearchBatch -Packages $Packages[$half..($Packages.Count - 1)] -Result $Result -Invoker $Invoker
        return
    }

    $dataProperty = if ($null -ne $response) { $response.PSObject.Properties['data'] } else { $null }
    $data = if ($dataProperty) { $dataProperty.Value } else { $null }

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $node = if ($null -ne $data) { $data.PSObject.Properties["v$i"] } else { $null }
        $search = if ($node) { $node.Value } else { $null }

        # Assign through the index directly: using `if` as an assignment
        # expression unrolls an empty result set to $null, which would be
        # indistinguishable from a failed search.
        if ($null -eq $search) {
            $Result[$Packages[$i].PackageId] = $null
        }
        else {
            $Result[$Packages[$i].PackageId] = [object[]]@($search.nodes)
        }
    }
}

# Packages already published need no search at all.
$needsSearch = [System.Collections.Generic.List[object]]::new()
$publishedMatchByPackage = @{}
foreach ($candidate in $candidates) {
    $versions = $publishedByPackage[$candidate.PackageId]
    $match = $null
    if ($null -ne $versions -and $versions.Count -gt 0) {
        $match = & $module {
            param($v, $list) Find-WingetPublishedVersionMatch -Version $v -PublishedVersions $list
        } $candidate.LatestVersion ([string[]]$versions)
    }

    $publishedMatchByPackage[$candidate.PackageId] = $match
    if ($null -eq $match) { $needsSearch.Add($candidate) }
}

Write-Host "  $($candidates.Count - $needsSearch.Count) already published upstream; searching pull requests for the remaining $($needsSearch.Count)."

$prByPackage = @{}
$searchArray = @($needsSearch)
for ($offset = 0; $offset -lt $searchArray.Count; $offset += $BatchSize) {
    $slice = @($searchArray[$offset..([Math]::Min($offset + $BatchSize, $searchArray.Count) - 1)])
    Write-Progress -Activity 'Searching winget-pkgs pull requests for the new version' `
        -Status "$offset/$($searchArray.Count)" `
        -PercentComplete (100 * $offset / $searchArray.Count)
    Invoke-VersionPrSearchBatch -Packages $slice -Result $prByPackage -Invoker $invoker
}
Write-Progress -Activity 'Searching winget-pkgs pull requests for the new version' -Completed

# --- verdict -----------------------------------------------------------------

$report = [System.Collections.Generic.List[object]]::new()

foreach ($candidate in $candidates) {
    $published = $publishedMatchByPackage[$candidate.PackageId]

    if ($null -ne $published) {
        $report.Add([PSCustomObject]@{
                PackageId       = $candidate.PackageId
                CurrentVersion  = $candidate.CurrentVersion
                LatestVersion   = $candidate.LatestVersion
                Status          = 'PublishedAlready'
                Evidence        = "manifest version $($published.Version) ($($published.MatchType))"
                PrNumber        = ''
                PrState         = ''
                PrAuthor        = ''
                PrUrl           = ''
                GitHubOwner     = $candidate.GitHubOwner
                GitHubRepo      = $candidate.GitHubRepo
                UrlTemplate     = $candidate.UrlTemplate
            })
        continue
    }

    $nodes = $prByPackage[$candidate.PackageId]

    if ($null -eq $nodes) {
        # Fail closed: an unresolved search is not evidence that the version is
        # unclaimed.
        $report.Add([PSCustomObject]@{
                PackageId       = $candidate.PackageId
                CurrentVersion  = $candidate.CurrentVersion
                LatestVersion   = $candidate.LatestVersion
                Status          = 'Unknown'
                Evidence        = 'pull request search failed'
                PrNumber        = ''
                PrState         = ''
                PrAuthor        = ''
                PrUrl           = ''
                GitHubOwner     = $candidate.GitHubOwner
                GitHubRepo      = $candidate.GitHubRepo
                UrlTemplate     = $candidate.UrlTemplate
            })
        continue
    }

    # GitHub Search splits on punctuation, so require both the exact identifier
    # and the exact version in the title, and ignore closed-unmerged PRs.
    $matching = @($nodes | Where-Object {
            $null -ne $_ -and
            "$($_.title)".IndexOf($candidate.PackageId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            "$($_.title)".IndexOf($candidate.LatestVersion, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            ($_.state -eq 'OPEN' -or $null -ne $_.mergedAt)
        } | Sort-Object { [datetime]$_.createdAt } -Descending)

    if ($matching.Count -gt 0) {
        $pr = $matching[0]
        $report.Add([PSCustomObject]@{
                PackageId       = $candidate.PackageId
                CurrentVersion  = $candidate.CurrentVersion
                LatestVersion   = $candidate.LatestVersion
                Status          = 'PrForLatest'
                Evidence        = "PR #$($pr.number) $($pr.state)"
                PrNumber        = [string]$pr.number
                PrState         = [string]$pr.state
                PrAuthor        = if ($pr.author) { [string]$pr.author.login } else { '' }
                PrUrl           = [string]$pr.url
                GitHubOwner     = $candidate.GitHubOwner
                GitHubRepo      = $candidate.GitHubRepo
                UrlTemplate     = $candidate.UrlTemplate
            })
        continue
    }

    $report.Add([PSCustomObject]@{
            PackageId       = $candidate.PackageId
            CurrentVersion  = $candidate.CurrentVersion
            LatestVersion   = $candidate.LatestVersion
            Status          = 'Unclaimed'
            Evidence        = 'no published version and no pull request'
            PrNumber        = ''
            PrState         = ''
            PrAuthor        = ''
            PrUrl           = ''
            GitHubOwner     = $candidate.GitHubOwner
            GitHubRepo      = $candidate.GitHubRepo
            UrlTemplate     = $candidate.UrlTemplate
        })
}

$ordered = @($report | Sort-Object Status, PackageId)
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$ordered | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8

$unclaimedPath = Join-Path (Split-Path -Parent $OutputPath) 'github-outdated-candidates-unmaintained.yml'
$snippet = foreach ($row in @($ordered | Where-Object { $_.Status -eq 'Unclaimed' })) {
    "          - id: `"$($row.PackageId)`""
    "            repo: `"$($row.GitHubOwner)/$($row.GitHubRepo)`""
    "            url: `"$($row.UrlTemplate)`""
}
Set-Content -LiteralPath $unclaimedPath -Value ($snippet -join "`n") -Encoding utf8

Write-Host ''
Write-Host 'Maintenance status' -ForegroundColor Cyan
$ordered | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
    $percent = [math]::Round(100 * $_.Count / $ordered.Count, 1)
    Write-Host ("  {0,-18} {1,5}  ({2}%)" -f $_.Name, $_.Count, $percent)
}
Write-Host ''
Write-Host "Report        : $OutputPath"
Write-Host "Adoptable yml : $unclaimedPath"
