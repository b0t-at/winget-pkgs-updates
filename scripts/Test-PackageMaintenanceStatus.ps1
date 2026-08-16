#Requires -Version 7.0

<#
.SYNOPSIS
    Classifies scan candidates by how actively they are already being maintained
    in `microsoft/winget-pkgs`, so only unmaintained packages get adopted.

.DESCRIPTION
    A package being out of date does not mean nobody is looking after it. The
    publisher may self-submit, another maintainer may run their own pipeline, or
    a pull request for the new version may already be open. Adopting those
    packages produces duplicate PRs and friction with existing maintainers.

    For each candidate this script runs one `repo:microsoft/winget-pkgs is:pr
    in:title "<PackageId>"` search and inspects the most recent pull requests.
    Searches are batched with GraphQL aliases so hundreds of packages cost a few
    dozen requests instead of one REST search each.

    GitHub Search tokenizes on punctuation, so `Foo.Bar` can match `Foo.Bar.Baz`.
    Every returned title is therefore re-checked client-side against the exact
    package identifier before it counts as evidence of maintenance.

    Resulting status per package:
      OpenPr       - a pull request is open right now; leave it alone.
      Maintained   - somebody other than us submitted within -MaintainedWithinDays.
      Ours         - only our own account submitted recently.
      Unmaintained - no qualifying pull request activity at all.

.PARAMETER InputPath
    Verified candidate report from Test-OutdatedPackageCandidate.ps1.

.PARAMETER OutputPath
    CSV report with the maintenance verdict for every candidate.

.PARAMETER SelfAuthor
    Accounts that belong to this pipeline. Activity from these does not count as
    third-party maintenance.

.PARAMETER MaintainedWithinDays
    How recent a third-party pull request has to be for the package to count as
    actively maintained.

.PARAMETER BatchSize
    Number of aliased searches per GraphQL request. GitHub applies a secondary
    rate limit to search, so this is deliberately small.

.PARAMETER Top
    Only classify the first N candidates. Intended for smoke tests.

.EXAMPLE
    ./scripts/Test-PackageMaintenanceStatus.ps1 -Top 30 -Verbose

.EXAMPLE
    ./scripts/Test-PackageMaintenanceStatus.ps1 -MaintainedWithinDays 180
#>
[CmdletBinding()]
param(
    [string] $InputPath,
    [string] $OutputPath,
    [string[]] $SelfAuthor = @('damn-good-b0t'),
    [int] $MaintainedWithinDays = 120,
    [int] $BatchSize = 10,
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

function Invoke-PrSearchBatch {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Packages,
        [Parameter(Mandatory = $true)] [hashtable] $Result,
        [Parameter(Mandatory = $true)] [scriptblock] $Invoker
    )

    if ($Packages.Count -eq 0) { return }

    $fields = for ($i = 0; $i -lt $Packages.Count; $i++) {
        $id = $Packages[$i].PackageId
        $search = "repo:microsoft/winget-pkgs is:pr in:title `"$($id.Replace('"', '\"'))`" sort:created-desc"
        $literal = '"' + $search.Replace('\', '\\').Replace('"', '\"') + '"'
        "  s$($i): search(query: $literal, type: ISSUE, first: 20) { nodes { ... on PullRequest { number title state createdAt mergedAt url author { login } } } }"
    }

    $query = "query {`n" + ($fields -join "`n") + "`n}"

    try {
        $response = & $Invoker $query
    }
    catch {
        if ($Packages.Count -eq 1) {
            Write-Verbose "PR search failed for $($Packages[0].PackageId): $($_.Exception.Message)"
            $Result[$Packages[0].PackageId] = $null
            return
        }

        $half = [int][Math]::Floor($Packages.Count / 2)
        Invoke-PrSearchBatch -Packages $Packages[0..($half - 1)] -Result $Result -Invoker $Invoker
        Invoke-PrSearchBatch -Packages $Packages[$half..($Packages.Count - 1)] -Result $Result -Invoker $Invoker
        return
    }

    $dataProperty = if ($null -ne $response) { $response.PSObject.Properties['data'] } else { $null }
    $data = if ($dataProperty) { $dataProperty.Value } else { $null }

    for ($i = 0; $i -lt $Packages.Count; $i++) {
        $node = if ($null -ne $data) { $data.PSObject.Properties["s$i"] } else { $null }
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

$pullRequestsByPackage = @{}
for ($offset = 0; $offset -lt $candidates.Count; $offset += $BatchSize) {
    $slice = @($candidates[$offset..([Math]::Min($offset + $BatchSize, $candidates.Count) - 1)])
    Write-Progress -Activity 'Searching winget-pkgs pull requests' `
        -Status "$offset/$($candidates.Count)" `
        -PercentComplete (100 * $offset / $candidates.Count)
    Invoke-PrSearchBatch -Packages $slice -Result $pullRequestsByPackage -Invoker $invoker
}
Write-Progress -Activity 'Searching winget-pkgs pull requests' -Completed

$cutoff = (Get-Date).ToUniversalTime().AddDays(-$MaintainedWithinDays)
$report = [System.Collections.Generic.List[object]]::new()

foreach ($candidate in $candidates) {
    $nodes = $pullRequestsByPackage[$candidate.PackageId]

    if ($null -eq $nodes) {
        # Fail closed: an unresolved search is not evidence that nobody is
        # maintaining the package.
        $report.Add([PSCustomObject]@{
                PackageId       = $candidate.PackageId
                CurrentVersion  = $candidate.CurrentVersion
                LatestVersion   = $candidate.LatestVersion
                Status          = 'Unknown'
                OpenPrCount     = 0
                OpenPrForLatest = $false
                LastPrAt        = ''
                DaysSinceLastPr = ''
                RecentAuthors   = ''
                LatestPrUrl     = ''
                GitHubOwner     = $candidate.GitHubOwner
                GitHubRepo      = $candidate.GitHubRepo
                UrlTemplate     = $candidate.UrlTemplate
            })
        continue
    }

    # GitHub Search splits identifiers on dots, so `Foo.Bar` also matches
    # `Foo.Bar.Baz`. Require the exact identifier in the title.
    $matching = @($nodes | Where-Object {
            $null -ne $_ -and "$($_.title)".IndexOf($candidate.PackageId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        })

    $open = @($matching | Where-Object { $_.state -eq 'OPEN' })
    $openForLatest = @($open | Where-Object { "$($_.title)".Contains($candidate.LatestVersion) })

    $recent = @($matching | Where-Object { [datetime]$_.createdAt -ge $cutoff })
    $recentAuthors = @($recent |
            ForEach-Object { if ($_.author) { [string]$_.author.login } else { '' } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
    $thirdPartyAuthors = @($recentAuthors | Where-Object { $_ -notin $SelfAuthor })

    $newest = $matching | Sort-Object { [datetime]$_.createdAt } -Descending | Select-Object -First 1

    $status =
        if ($open.Count -gt 0) { 'OpenPr' }
        elseif ($thirdPartyAuthors.Count -gt 0) { 'Maintained' }
        elseif ($recentAuthors.Count -gt 0) { 'Ours' }
        else { 'Unmaintained' }

    $report.Add([PSCustomObject]@{
            PackageId       = $candidate.PackageId
            CurrentVersion  = $candidate.CurrentVersion
            LatestVersion   = $candidate.LatestVersion
            Status          = $status
            OpenPrCount     = $open.Count
            OpenPrForLatest = ($openForLatest.Count -gt 0)
            LastPrAt        = if ($newest) { ([datetime]$newest.createdAt).ToString('yyyy-MM-dd') } else { '' }
            DaysSinceLastPr = if ($newest) { [int]((Get-Date).ToUniversalTime() - [datetime]$newest.createdAt).TotalDays } else { '' }
            RecentAuthors   = $recentAuthors -join ';'
            LatestPrUrl     = if ($newest) { [string]$newest.url } else { '' }
            GitHubOwner     = $candidate.GitHubOwner
            GitHubRepo      = $candidate.GitHubRepo
            UrlTemplate     = $candidate.UrlTemplate
        })
}

$ordered = @($report | Sort-Object Status, PackageId)
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$ordered | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8

$unmaintainedPath = Join-Path (Split-Path -Parent $OutputPath) 'github-outdated-candidates-unmaintained.yml'
$snippet = foreach ($row in @($ordered | Where-Object { $_.Status -in @('Unmaintained', 'Ours') })) {
    "          - id: `"$($row.PackageId)`""
    "            repo: `"$($row.GitHubOwner)/$($row.GitHubRepo)`""
    "            url: `"$($row.UrlTemplate)`""
}
Set-Content -LiteralPath $unmaintainedPath -Value ($snippet -join "`n") -Encoding utf8

Write-Host ''
Write-Host 'Maintenance status' -ForegroundColor Cyan
$ordered | Group-Object Status | Sort-Object Count -Descending | ForEach-Object {
    $percent = [math]::Round(100 * $_.Count / $ordered.Count, 1)
    Write-Host ("  {0,-14} {1,5}  ({2}%)" -f $_.Name, $_.Count, $percent)
}
Write-Host ''
Write-Host "Report        : $OutputPath"
Write-Host "Adoptable yml : $unmaintainedPath"
