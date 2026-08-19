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
        # A weekly report spanning ~30 batched queries must shrug off the odd
        # transient GraphQL 5xx; the shared precheck invoker only retries
        # rate limits, so transport-level retries are layered on here.
        $GraphQlInvoker = {
            param([string] $Query)

            $maxAttempts = 5
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    return Invoke-WingetPrecheckGraphQlRequest -Query $Query
                }
                catch {
                    if ($attempt -ge $maxAttempts) { throw }
                    $message = "$($_.Exception.Message)"
                    $statusCode = $null
                    if ($null -ne $_.Exception.Data -and $null -ne $_.Exception.Data['StatusCode']) {
                        $statusCode = [int]$_.Exception.Data['StatusCode']
                    }
                    elseif ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                        $statusCode = [int]$_.Exception.Response.StatusCode
                    }
                    $isTransient = ($statusCode -ge 500 -and $statusCode -le 599) -or
                        $message -match 'No server is currently available|couldn.t respond to your request in time|502|503|504'
                    if (-not $isTransient) { throw }
                    $delay = [int][Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1))
                    Write-Warning "Monitored-asset GraphQL query hit a transient failure (attempt $attempt/$maxAttempts): $message Retrying in $delay s."
                    Start-Sleep -Seconds $delay
                }
            }
        }
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

    # Pass 2: tagPattern packages need the recent release list to pick their
    # stream. Multiple packages often share one repository (e.g. every
    # Electron major), so the release list is fetched once per unique repo -
    # asset-heavy repositories make the per-package form time out server-side.
    $tagPatternArray = @($withTagPattern)
    $releaseNodesByRepo = @{}
    $repoMissingByRepo = @{}
    $uniqueTagPatternRepos = @($tagPatternArray |
            ForEach-Object { Get-WingetPrecheckPackageField -Package $_ -Name 'repo' } |
            Sort-Object -Unique)

    for ($offset = 0; $offset -lt $uniqueTagPatternRepos.Count; $offset += $TagPatternBatchSize) {
        $slice = @($uniqueTagPatternRepos[$offset..([Math]::Min($offset + $TagPatternBatchSize, $uniqueTagPatternRepos.Count) - 1)])
        $fields = for ($i = 0; $i -lt $slice.Count; $i++) {
            $owner, $name = $slice[$i].Split('/', 2)
            "t$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { releases(first: 40, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { isDraft isPrerelease publishedAt $releaseSelection } } }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = & $GraphQlInvoker $query
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $slice.Count; $i++) {
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "t$i"
            if ($null -eq $repository) {
                $repoMissingByRepo[$slice[$i]] = $true
                continue
            }
            $releasesValue = Get-WingetGraphQlFieldValue -InputObject (Get-WingetGraphQlFieldValue -InputObject $repository -Name 'releases') -Name 'nodes'
            $releaseNodesByRepo[$slice[$i]] = if ($null -eq $releasesValue) { @() } else { @($releasesValue) }
        }
    }

    foreach ($package in $tagPatternArray) {
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'

        if ($repoMissingByRepo.ContainsKey($repo)) {
            $results.Add((Resolve-WingetMonitoredAssetStatus -Package $package -Repository $null -Release $null -NoReleaseStatus 'NoMatchingRelease'))
            continue
        }

        $tagPattern = Get-WingetPrecheckPackageField -Package $package -Name 'tagPattern'
        # Prerelease-channel entries (pre-release: "true") resolve against
        # prerelease-flagged releases, mirroring Get-LatestGHVersionTag.
        $allowPrerelease = Test-WingetPreReleaseOptIn -Value (Get-WingetGraphQlFieldValue -InputObject $package -Name 'pre-release')
        $releaseNodes = @($releaseNodesByRepo[$repo])
        $matching = @($releaseNodes |
                Where-Object {
                    $null -ne $_ -and
                    -not [bool](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'isDraft') -and
                    ($allowPrerelease -or -not [bool](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'isPrerelease')) -and
                    "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'tagName')" -match $tagPattern
                } |
                Sort-Object -Property @{ Expression = { "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'publishedAt')" } } -Descending)
        $release = if ($matching.Count -gt 0) { $matching[0] } else { $null }

        $results.Add((Resolve-WingetMonitoredAssetStatus -Package $package -Repository ([PSCustomObject]@{ present = $true }) -Release $release -NoReleaseStatus 'NoMatchingRelease'))
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

    $installerValues = @($url -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $assetTemplates = [System.Collections.Generic.List[string]]::new()
    $deferredTemplates = [System.Collections.Generic.List[string]]::new()
    $releasePrefix = "https://github.com/$repo/releases/"
    $escapedRepo = [regex]::Escape($repo)
    $latestDownloadPattern = "^(?i:https://github\.com/$escapedRepo/releases/latest/download/)"
    foreach ($entry in @(Get-InstallerUrlEntries -InstallerValues $installerValues)) {
        $template = $entry.InstallerUrl -replace '[?#].*$', ''
        if ($template -notlike "$releasePrefix*") {
            $deferredTemplates.Add($entry.InstallerUrl)
            continue
        }

        $latestDownloadMatch = [regex]::Match($template, $latestDownloadPattern)
        if ($latestDownloadMatch.Success) {
            $template = "$releasePrefix`download/$tag/" + $template.Substring($latestDownloadMatch.Length)
        }
        if ($template -notlike "$releasePrefix`download/*") {
            $deferredTemplates.Add($entry.InstallerUrl)
            continue
        }
        $assetTemplates.Add($template)
    }

    if ($assetTemplates.Count -eq 0) {
        return & $newResult 'Skipped' 'No GitHub release-asset URL template to verify; final installer URL preflight remains responsible.' $tag
    }

    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($template in $assetTemplates) {
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

    $deferredNote = if ($deferredTemplates.Count -gt 0) {
        " $($deferredTemplates.Count) external URL template(s) remain covered by submission preflight."
    }
    else {
        ''
    }
    return & $newResult 'OK' "All GitHub release-asset URL templates resolve against release ${tag}.$deferredNote" $tag
}
