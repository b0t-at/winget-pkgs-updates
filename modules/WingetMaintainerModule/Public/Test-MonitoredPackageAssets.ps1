function Test-MonitoredPackageAssets {
    <#
    .SYNOPSIS
        Verifies that every monitored package's release-asset URL template still
        matches a real asset on the package's current GitHub release.

    .DESCRIPTION
        Publishers rename assets, change naming schemes, delete releases, or
        archive repositories. Any of those turns a monitored package into a
        permanent source of failed generations or, worse, upstream
        URL-Validation-Error pull requests. This function performs a read-only
        sweep over the monitored configuration using batched GraphQL queries
        (mirroring the update precheck's query shapes) and reports one status
        per package:

          - OK: every URL template resolves to an existing release asset.
          - RepoMissing: the GitHub repository no longer exists (or is private).
          - NoRelease: the repository has no published stable release.
          - NoMatchingRelease: no stable release matches the tagPattern.
          - VersionUnresolved: versionSource=ReleaseName and the release has no
            usable name.
          - AssetMissing: at least one URL template matches no asset on the
            resolved release (details list the missing URLs).
          - Inconclusive: the release carries more than 100 assets, so a missed
            match cannot be distinguished from truncation.
          - Skipped: the entry has no repo/url pair to check.

    .OUTPUTS
        One PSCustomObject per package: PackageId, Repo, Status, Detail, Tag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Packages,

        # Injectable for tests: receives the GraphQL query string, returns the parsed response.
        [Parameter()]
        [scriptblock] $GraphQlInvoker,

        [Parameter()]
        [ValidateRange(1, 100)]
        [int] $BatchSize = 40,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int] $TagPatternBatchSize = 5
    )

    if ($null -eq $GraphQlInvoker) {
        $GraphQlInvoker = { param([string] $Query) Invoke-WingetPrecheckGraphQlRequest -Query $Query }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $simple = [System.Collections.Generic.List[object]]::new()
    $withTagPattern = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $Packages) {
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'
        $url = Get-WingetPrecheckPackageField -Package $package -Name 'url'
        $tagPattern = Get-WingetPrecheckPackageField -Package $package -Name 'tagPattern'

        if ([string]::IsNullOrWhiteSpace($packageId) -or
            [string]::IsNullOrWhiteSpace($repo) -or
            [string]::IsNullOrWhiteSpace($url) -or
            $repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            $results.Add([PSCustomObject]@{
                    PackageId = $packageId
                    Repo      = $repo
                    Status    = 'Skipped'
                    Detail    = 'No checkable repo/url template.'
                    Tag       = $null
                })
            continue
        }

        if ([string]::IsNullOrWhiteSpace($tagPattern)) {
            $simple.Add($package)
        }
        else {
            $withTagPattern.Add($package)
        }
    }

    $releaseSelection = 'tagName name releaseAssets(first: 100) { totalCount nodes { downloadUrl } }'

    # Pass 1: packages that follow the repository's latest stable release.
    $simpleArray = @($simple)
    for ($offset = 0; $offset -lt $simpleArray.Count; $offset += $BatchSize) {
        $slice = @($simpleArray[$offset..([Math]::Min($offset + $BatchSize, $simpleArray.Count) - 1)])
        $fields = for ($i = 0; $i -lt $slice.Count; $i++) {
            $owner, $name = (Get-WingetPrecheckPackageField -Package $slice[$i] -Name 'repo').Split('/', 2)
            "a$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { latestRelease { $releaseSelection } }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = & $GraphQlInvoker $query
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $slice.Count; $i++) {
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "a$i"
            $release = Get-WingetGraphQlFieldValue -InputObject $repository -Name 'latestRelease'
            $results.Add((Resolve-WingetMonitoredAssetStatus -Package $slice[$i] -Repository $repository -Release $release))
        }
    }

    # Pass 2: tagPattern packages need the recent release list to pick their stream.
    $tagPatternArray = @($withTagPattern)
    for ($offset = 0; $offset -lt $tagPatternArray.Count; $offset += $TagPatternBatchSize) {
        $slice = @($tagPatternArray[$offset..([Math]::Min($offset + $TagPatternBatchSize, $tagPatternArray.Count) - 1)])
        $fields = for ($i = 0; $i -lt $slice.Count; $i++) {
            $owner, $name = (Get-WingetPrecheckPackageField -Package $slice[$i] -Name 'repo').Split('/', 2)
            "t$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { releases(first: 60, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { isDraft isPrerelease publishedAt $releaseSelection } } }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = & $GraphQlInvoker $query
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $slice.Count; $i++) {
            $slicePackage = $slice[$i]
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "t$i"
            $release = $null

            if ($null -ne $repository) {
                $tagPattern = Get-WingetPrecheckPackageField -Package $slicePackage -Name 'tagPattern'
                $releasesValue = Get-WingetGraphQlFieldValue -InputObject (Get-WingetGraphQlFieldValue -InputObject $repository -Name 'releases') -Name 'nodes'
                $releaseNodes = if ($null -eq $releasesValue) { @() } else { @($releasesValue) }
                $matching = @($releaseNodes |
                        Where-Object {
                            $null -ne $_ -and
                            -not [bool](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'isDraft') -and
                            -not [bool](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'isPrerelease') -and
                            "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'tagName')" -match $tagPattern
                        } |
                        Sort-Object -Property @{ Expression = { "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'publishedAt')" } } -Descending)
                if ($matching.Count -gt 0) {
                    $release = $matching[0]
                }
            }

            $results.Add((Resolve-WingetMonitoredAssetStatus -Package $slicePackage -Repository $repository -Release $release -NoReleaseStatus 'NoMatchingRelease'))
        }
    }

    return @($results | Sort-Object -Property PackageId)
}

function Resolve-WingetMonitoredAssetStatus {
    <#
    .SYNOPSIS
        Classifies one monitored package against its resolved GitHub release.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter()] $Repository,
        [Parameter()] $Release,
        [Parameter()] [string] $NoReleaseStatus = 'NoRelease'
    )

    $packageId = Get-WingetPrecheckPackageField -Package $Package -Name 'id'
    $repo = Get-WingetPrecheckPackageField -Package $Package -Name 'repo'
    $url = Get-WingetPrecheckPackageField -Package $Package -Name 'url'
    $versionSource = Get-WingetPrecheckPackageField -Package $Package -Name 'versionSource'

    $newResult = {
        param([string] $Status, [string] $Detail, [string] $Tag)
        [PSCustomObject]@{
            PackageId = $packageId
            Repo      = $repo
            Status    = $Status
            Detail    = $Detail
            Tag       = $Tag
        }
    }

    if ($null -eq $Repository) {
        return & $newResult 'RepoMissing' 'The GitHub repository does not exist or is not readable.' $null
    }
    if ($null -eq $Release) {
        return & $newResult $NoReleaseStatus 'No published stable release resolves for this package.' $null
    }

    $tag = [string](Get-WingetGraphQlFieldValue -InputObject $Release -Name 'tagName')
    if ([string]::IsNullOrWhiteSpace($tag)) {
        return & $newResult $NoReleaseStatus 'The resolved release has no tag.' $null
    }

    $version = if ($versionSource -eq 'ReleaseName') {
        [string](Get-WingetGraphQlFieldValue -InputObject $Release -Name 'name')
    }
    else {
        Remove-GHTagPrefixes -Tag $tag
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        return & $newResult 'VersionUnresolved' 'The resolved release has no usable version (empty release name).' $tag
    }
    $version = $version.Trim()

    $assetsObject = Get-WingetGraphQlFieldValue -InputObject $Release -Name 'releaseAssets'
    $assetNodesValue = Get-WingetGraphQlFieldValue -InputObject $assetsObject -Name 'nodes'
    $assetNodes = if ($null -eq $assetNodesValue) { @() } else { @($assetNodesValue) }
    $assetUrls = @($assetNodes | ForEach-Object { [string](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'downloadUrl') })
    $totalCountValue = Get-WingetGraphQlFieldValue -InputObject $assetsObject -Name 'totalCount'
    $assetsTruncated = $null -ne $totalCountValue -and [int]$totalCountValue -gt $assetUrls.Count

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @(Get-InstallerUrlEntries -InstallerValues @($url.Split(' ')))) {
        $template = $entry.InstallerUrl
        if ($template -match '\{ARPVERSION\}') {
            $assetRegex = [regex]::Escape($template).
                Replace('\{ARPVERSION}', '(.+?)').
                Replace('\{TAG}', [regex]::Escape($tag)).
                Replace('\{VERSION}', [regex]::Escape($version))
            $matched = @($assetUrls | Where-Object { $_ -match $assetRegex }).Count -gt 0
            if (-not $matched) {
                $missing.Add($template)
            }
            continue
        }

        $expectedUrl = $template.Replace('{TAG}', $tag).Replace('{VERSION}', $version)
        if (-not (@($assetUrls | Where-Object { $_ -ieq $expectedUrl }).Count -gt 0)) {
            $missing.Add($expectedUrl)
        }
    }

    if ($missing.Count -gt 0) {
        if ($assetsTruncated) {
            return & $newResult 'Inconclusive' "The release lists more than $($assetUrls.Count) assets; unmatched URL(s) may exist beyond the first page: $($missing -join ' ')" $tag
        }
        return & $newResult 'AssetMissing' "No release asset matches: $($missing -join ' ')" $tag
    }

    return & $newResult 'OK' "All URL templates resolve against release $tag." $tag
}
