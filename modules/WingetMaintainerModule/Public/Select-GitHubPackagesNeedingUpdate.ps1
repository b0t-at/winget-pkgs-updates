function Get-WingetGraphQlFieldValue {
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function ConvertTo-WingetGraphQlStringLiteral {
    param([Parameter(Mandatory = $true)] [string] $Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Invoke-WingetPrecheckGraphQlRequest {
    param([Parameter(Mandatory = $true)] [string] $Query)

    $token = Get-WingetGitHubToken
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'A GitHub token is required for the update precheck GraphQL queries.'
    }

    $headers = @{
        ('Author' + 'ization') = ('Bearer' + [char]32 + $token)
        'Accept'               = 'application/vnd.github+json'
        'User-Agent'           = 'winget-pkgs-updates'
    }
    $body = @{ query = $Query } | ConvertTo-Json -Depth 4 -Compress

    return Invoke-WithGitHubRateLimitRetry `
        -OperationName 'GitHub GraphQL update precheck' `
        -MaxAttempts 5 `
        -MaxTotalWaitSeconds 240 `
        -RetryTransientServerErrors `
        -ScriptBlock {
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri 'https://api.github.com/graphql' `
                -Headers $headers `
                -Body $body `
                -ContentType 'application/json'

            $graphQlErrors = @()
            $errorsValue = Get-WingetGraphQlFieldValue -InputObject $response -Name 'errors'
            if ($null -ne $errorsValue) {
                $graphQlErrors = @($errorsValue)
            }

            # GraphQL rate limits arrive as HTTP 200 with an errors payload; tag them
            # so the retry helper treats them like REST 429 responses.
            $rateLimitedErrors = @($graphQlErrors | Where-Object { "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'type')" -eq 'RATE_LIMITED' })
            if ($rateLimitedErrors.Count -gt 0) {
                $rateLimitMessage = [string](Get-WingetGraphQlFieldValue -InputObject $rateLimitedErrors[0] -Name 'message')
                $rateLimitException = [System.Exception]::new("GitHub GraphQL request failed: $rateLimitMessage")
                $rateLimitException.Data['StatusCode'] = 429
                throw $rateLimitException
            }

            if ($null -eq (Get-WingetGraphQlFieldValue -InputObject $response -Name 'data') -and $graphQlErrors.Count -gt 0) {
                $firstMessage = [string](Get-WingetGraphQlFieldValue -InputObject $graphQlErrors[0] -Name 'message')
                throw "GitHub GraphQL request failed: $firstMessage"
            }

            return $response
        }
}

function Get-WingetPrecheckPackageField {
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $value = Get-WingetGraphQlFieldValue -InputObject $Package -Name $Name
    if ($null -eq $value) {
        return ''
    }

    return [string]$value
}

function Get-WingetPrecheckErroredAlias {
    <#
    .SYNOPSIS
        Attributes GraphQL partial errors to the aliased fields of a batch query.

    .DESCRIPTION
        A GraphQL response can be HTTP 200 with an errors array and partially
        null data: per-alias errors carry the failed field's response path
        (e.g. ["p3"] or ["repository", "p3"]). A null aliased object WITH a
        corresponding error entry is a failed lookup, not evidence of absence,
        so callers must not treat it as a skip decision. Returns the batch
        aliases the errors attribute to, plus WholeBatchFailed when the
        response cannot be trusted at all: data is null/absent, or an error
        exists whose path matches none of the expected aliases (fail-open,
        identical handling to a thrown batch).
    #>
    param(
        [Parameter()] $Response,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [string[]] $ExpectedAliases
    )

    $aliasSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExpectedAliases, [System.StringComparer]::Ordinal)
    $errorsValue = Get-WingetGraphQlFieldValue -InputObject $Response -Name 'errors'
    $graphQlErrors = if ($null -eq $errorsValue) { @() } else { @($errorsValue) }

    $erroredAliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $hasUnattributableErrors = $false
    foreach ($graphQlError in $graphQlErrors) {
        $pathValue = Get-WingetGraphQlFieldValue -InputObject $graphQlError -Name 'path'
        $pathEntries = if ($null -eq $pathValue) { @() } else { @($pathValue) }
        $matched = $false
        foreach ($pathEntry in $pathEntries) {
            if ($aliasSet.Contains("$pathEntry")) {
                $null = $erroredAliases.Add("$pathEntry")
                $matched = $true
            }
        }
        if (-not $matched) {
            $hasUnattributableErrors = $true
        }
    }

    $data = Get-WingetGraphQlFieldValue -InputObject $Response -Name 'data'

    return [PSCustomObject]@{
        ErroredAliases   = $erroredAliases
        WholeBatchFailed = ($null -eq $data) -or ($graphQlErrors.Count -gt 0 -and $hasUnattributableErrors)
    }
}

function Resolve-WingetPrecheckReleaseVersion {
    <#
    .SYNOPSIS
        Resolves a package's pending version from release metadata.

    .DESCRIPTION
        Mirrors the full update job's version resolution (Get-LatestGHVersionTag
        + Get-LatestARPVersion) using a single package-scoped GraphQL response:
        tagPattern packages pick the newest stable release whose tag matches,
        versionSource=ReleaseName uses the release name, {ARPVERSION} URLs derive
        the version from asset download URLs, everything else strips known tag
        prefixes. Returns $null whenever resolution is not possible so callers
        can fail open and include the package.
    #>
    param(
        [Parameter(Mandatory = $true)] $Package,
        [Parameter()] $Repository
    )

    $url = Get-WingetPrecheckPackageField -Package $Package -Name 'url'
    $tagPattern = Get-WingetPrecheckPackageField -Package $Package -Name 'tagPattern'
    $versionSource = Get-WingetPrecheckPackageField -Package $Package -Name 'versionSource'

    $release = $null
    if (-not [string]::IsNullOrWhiteSpace($tagPattern)) {
        $releasesValue = Get-WingetGraphQlFieldValue -InputObject (Get-WingetGraphQlFieldValue -InputObject $Repository -Name 'releases') -Name 'nodes'
        $releaseNodes = if ($null -eq $releasesValue) { @() } else { @($releasesValue) }
        # Same selection as Get-LatestGHVersionTag: stable releases whose tag
        # matches the pattern, newest publish date first.
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
    else {
        # latestRelease already excludes drafts and prereleases, matching the
        # full job's isLatest selection.
        $release = Get-WingetGraphQlFieldValue -InputObject $Repository -Name 'latestRelease'
    }

    if ($null -eq $release) {
        return $null
    }

    $tag = [string](Get-WingetGraphQlFieldValue -InputObject $release -Name 'tagName')
    if ([string]::IsNullOrWhiteSpace($tag)) {
        return $null
    }

    if ($versionSource -eq 'ReleaseName') {
        $releaseName = [string](Get-WingetGraphQlFieldValue -InputObject $release -Name 'name')
        if ([string]::IsNullOrWhiteSpace($releaseName)) {
            return $null
        }
        return $releaseName.Trim()
    }

    if ($url -match '\{ARPVERSION\}') {
        $assetsValue = Get-WingetGraphQlFieldValue -InputObject (Get-WingetGraphQlFieldValue -InputObject $release -Name 'releaseAssets') -Name 'nodes'
        $assetNodes = if ($null -eq $assetsValue) { @() } else { @($assetsValue) }
        # A full first page could mean truncated results; fail open then.
        if ($assetNodes.Count -eq 0 -or $assetNodes.Count -ge 100) {
            return $null
        }
        # Same URL-derived regexes as Get-LatestARPVersion.
        $assetRegexes = @($url.Split(' ') -replace '{ARPVERSION}', '(.+?)' -replace '{TAG}', [Regex]::Escape($tag))
        foreach ($assetNode in $assetNodes) {
            $downloadUrl = [string](Get-WingetGraphQlFieldValue -InputObject $assetNode -Name 'downloadUrl')
            foreach ($assetRegex in $assetRegexes) {
                if ($downloadUrl -match $assetRegex) {
                    return $matches[1]
                }
            }
        }
        return $null
    }

    return Remove-GHTagPrefixes -Tag $tag
}

function Select-GitHubPackagesNeedingUpdate {
    <#
    .SYNOPSIS
        Determines which monitored GitHub packages actually need a manifest update.

    .DESCRIPTION
        Uses batched GraphQL queries (instead of one REST round-trip per package)
        to read every repository's latest release tag and every package's published
        winget-pkgs versions, then compares them. Packages whose version needs
        more than the latest tag (tagPattern, versionSource=ReleaseName,
        {ARPVERSION} URLs) are resolved from release metadata in an extra
        batched query. Packages whose latest release is
        already published are skipped; every ambiguous case is included so a
        precheck miss can never suppress a real update (fail-open).

        GraphQL failures are contained per batch: packages in a failed batch are
        included (Reason 'PrecheckBatchFailed') while other batches still produce
        normal skip decisions. Partial GraphQL errors (HTTP 200 with an errors
        array) are attributed per aliased field: an errored alias is a failed
        lookup — never evidence of a missing release or manifest folder — and
        unattributable errors or null data fail the whole batch. When the
        winget-pkgs published-versions query
        fails, the winget source index (a CDN copy of the catalog) supplies the
        published versions instead, so a transient GitHub error no longer forces
        the whole run open.

    .OUTPUTS
        PSCustomObject with Include and Skipped lists. Each entry carries the
        original Package object plus a Reason string.
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
        [ValidateRange(1, 200)]
        [int] $BatchSize = 100,

        # Optional path to package-state.json. When provided, packages whose new
        # version already has an open upstream PR are skipped, using a cached
        # marker in the state file (TTL-bound) to avoid repeated live searches.
        [Parameter()]
        [string] $StateFilePath,

        # Optional preloaded Config Health blocks. Supplying this lets callers
        # retain definitive URL blocks even when the GraphQL precheck fails open.
        [Parameter()]
        [System.Collections.IDictionary] $ConfigHealthBlocks,

        # Optional preloaded channel cooldown blocks (see
        # Get-PackageStateChannelCooldownBlocks). Computed from the state file
        # when omitted; an empty dictionary disables the throttle.
        [Parameter()]
        [System.Collections.IDictionary] $ChannelCooldownBlocks,

        # Minimum days between validation runs of a Nightly/Beta/Canary package.
        [Parameter()]
        [ValidateRange(0, 365)]
        [double] $ChannelCooldownDays = 3,

        [Parameter()]
        [ValidateRange(1, 8760)]
        [int] $OpenPrTtlHours = 24,

        # Injectable for tests: receives (PackageIdentifier, Version), returns
        # $true when an open upstream PR for that version exists.
        [Parameter()]
        [scriptblock] $OpenPrTester,

        # Cap on live PR searches per invocation; candidates beyond the cap are
        # included without a check (fail-open).
        [Parameter()]
        [ValidateRange(0, 1000)]
        [int] $MaxOpenPrChecks = 30,

        # Injectable for tests: returns winget source-index rows (objects with
        # PackageIdentifier and WingetVersion properties) used as the
        # published-versions fallback when a winget-pkgs batch query fails.
        # Defaults to Get-WingetSourceIndexPackage.
        [Parameter()]
        [scriptblock] $SourceIndexProvider
    )

    if ($null -eq $GraphQlInvoker) {
        $GraphQlInvoker = { param([string] $Query) Invoke-WingetPrecheckGraphQlRequest -Query $Query }
    }
    if ($null -eq $SourceIndexProvider) {
        $SourceIndexProvider = { Get-WingetSourceIndexPackage }
    }

    $openPrCheckEnabled = -not [string]::IsNullOrWhiteSpace($StateFilePath)
    if ($openPrCheckEnabled -and $null -eq $OpenPrTester) {
        $OpenPrTester = { param([string] $PackageIdentifier, [string] $Version) Test-ExistingPRs -Version $Version -PackageIdentifier $PackageIdentifier -OnlyOpen }
    }
    if ($null -eq $ConfigHealthBlocks) {
        $ConfigHealthBlocks = if ($openPrCheckEnabled) {
            Get-PackageStateConfigHealthBlocks -StateFilePath $StateFilePath
        }
        else {
            @{}
        }
    }
    if ($null -eq $ChannelCooldownBlocks) {
        $ChannelCooldownBlocks = if ($openPrCheckEnabled) {
            Get-PackageStateChannelCooldownBlocks -StateFilePath $StateFilePath -CooldownDays $ChannelCooldownDays
        }
        else {
            @{}
        }
    }
    $openPrChecksUsed = 0

    $include = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $comparable = [System.Collections.Generic.List[object]]::new()
    $resolvable = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $Packages) {
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'
        $url = Get-WingetPrecheckPackageField -Package $package -Name 'url'
        $tagPattern = Get-WingetPrecheckPackageField -Package $package -Name 'tagPattern'
        $versionSource = Get-WingetPrecheckPackageField -Package $package -Name 'versionSource'
        $overridePack = Get-WingetPrecheckPackageField -Package $package -Name 'overridePack'

        if ($ConfigHealthBlocks.Contains($packageId)) {
            $health = $ConfigHealthBlocks[$packageId]
            $skipped.Add([PSCustomObject]@{
                    Package      = $package
                    Reason       = 'ConfigHealthBlocked'
                    HealthStatus = [string]$health['status']
                    Detail       = [string]$health['detail']
                    CheckedAt    = [string]$health['checkedAt']
                })
        }
        elseif ($ChannelCooldownBlocks.Contains($packageId)) {
            # Nightly/Beta/Canary throttle: one validation run per cooldown
            # window, independent of whether the last one passed or failed.
            $cooldown = $ChannelCooldownBlocks[$packageId]
            $skipped.Add([PSCustomObject]@{
                    Package     = $package
                    Reason      = 'ChannelCooldown'
                    LastUpdated = [string]$cooldown['lastUpdated']
                    LastVersion = [string]$cooldown['lastVersion']
                    Detail      = "last validation run $([string]$cooldown['ageDays']) day(s) ago ($([string]$cooldown['lastVersion']) $([string]$cooldown['lastState'])); channel packages wait $([string]$cooldown['cooldownDays']) day(s) between submissions"
                })
        }
        elseif ([string]::IsNullOrWhiteSpace($packageId) -or [string]::IsNullOrWhiteSpace($repo)) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'IncompleteConfiguration' })
        }
        elseif (Test-WingetPreReleaseOptIn -Value (Get-WingetGraphQlFieldValue -InputObject $package -Name 'pre-release')) {
            # Prerelease-channel packages cannot be resolved from latestRelease
            # (GraphQL latestRelease and isLatest never point at prereleases) and
            # the precheck's release matching is stable-only, so a stable-derived
            # comparison could wrongly skip them. Always run the full job (fail-open).
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'PrereleaseChannel' })
        }
        elseif (-not [string]::IsNullOrWhiteSpace($tagPattern) -or
            (-not [string]::IsNullOrWhiteSpace($versionSource) -and $versionSource -ne 'Tag') -or
            -not [string]::IsNullOrWhiteSpace($overridePack) -or
            $url -match '\{ARPVERSION\}') {
            # Version determination goes beyond "latest release tag". Most such
            # cases can still be resolved here from release metadata (release
            # name, asset URLs, tag pattern); the rest always run the full job.
            $isResolvable = [string]::IsNullOrWhiteSpace($overridePack) -and
                ([string]::IsNullOrWhiteSpace($versionSource) -or $versionSource -in @('Tag', 'ReleaseName')) -and
                $repo -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
                -not (-not [string]::IsNullOrWhiteSpace($tagPattern) -and $url -match '\{ARPVERSION\}')
            if ($isResolvable) {
                $resolvable.Add($package)
            }
            else {
                $include.Add([PSCustomObject]@{ Package = $package; Reason = 'UnpredictableVersionSource' })
            }
        }
        elseif ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'InvalidRepoFormat' })
        }
        else {
            $comparable.Add($package)
        }
    }

    if ($comparable.Count -eq 0 -and $resolvable.Count -eq 0) {
        return [PSCustomObject]@{ Include = @($include); Skipped = @($skipped) }
    }

    # Pass 1: latest release tag per unique repository, batched with aliases.
    # A failed batch marks its repositories so their packages fail open below,
    # while other batches still produce normal skip decisions.
    $uniqueRepos = @($comparable | ForEach-Object { Get-WingetPrecheckPackageField -Package $_ -Name 'repo' } | Sort-Object -Unique)
    $latestTagByRepo = @{}
    $failedRepoLookups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    for ($offset = 0; $offset -lt $uniqueRepos.Count; $offset += $BatchSize) {
        $repoSlice = @($uniqueRepos[$offset..([Math]::Min($offset + $BatchSize, $uniqueRepos.Count) - 1)])
        $fields = for ($i = 0; $i -lt $repoSlice.Count; $i++) {
            $owner, $name = $repoSlice[$i].Split('/', 2)
            "r$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { latestRelease { tagName } }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = $null
        try {
            $response = & $GraphQlInvoker $query
        }
        catch {
            Write-Warning "Update precheck release query failed for a batch of $($repoSlice.Count) repositories: $($_.Exception.Message). Including their packages."
            foreach ($failedRepo in $repoSlice) {
                $null = $failedRepoLookups.Add($failedRepo)
            }
            continue
        }
        $graphQlErrorInfo = Get-WingetPrecheckErroredAlias -Response $response -ExpectedAliases @(for ($i = 0; $i -lt $repoSlice.Count; $i++) { "r$i" })
        if ($graphQlErrorInfo.WholeBatchFailed) {
            Write-Warning "Update precheck release query returned unattributable GraphQL errors for a batch of $($repoSlice.Count) repositories. Including their packages."
            foreach ($failedRepo in $repoSlice) {
                $null = $failedRepoLookups.Add($failedRepo)
            }
            continue
        }
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $repoSlice.Count; $i++) {
            if ($graphQlErrorInfo.ErroredAliases.Contains("r$i")) {
                # A per-alias error is a failed lookup, not evidence the
                # repository has no releases; only positive evidence may skip.
                Write-Warning "Update precheck release query returned an error for repository $($repoSlice[$i]). Including its packages."
                $null = $failedRepoLookups.Add($repoSlice[$i])
                continue
            }
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "r$i"
            $latestRelease = Get-WingetGraphQlFieldValue -InputObject $repository -Name 'latestRelease'
            $tagName = Get-WingetGraphQlFieldValue -InputObject $latestRelease -Name 'tagName'
            $latestTagByRepo[$repoSlice[$i]] = $tagName
        }
    }

    # Candidates carry a package plus its resolved pending version; they feed
    # the published-version comparison and the open-PR check below.
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($package in @($comparable)) {
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'

        if ($failedRepoLookups.Contains($repo)) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'PrecheckBatchFailed' })
            continue
        }

        $latestTag = [string]$latestTagByRepo[$repo]
        if ([string]::IsNullOrWhiteSpace($latestTag)) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NoReleaseFound' })
            continue
        }

        $version = Remove-GHTagPrefixes -Tag $latestTag
        if ([string]::IsNullOrWhiteSpace($version)) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NoReleaseFound' })
            continue
        }

        $candidates.Add([PSCustomObject]@{ Package = $package; Version = $version })
    }

    # Pass 1b: resolve versions for packages whose version needs release
    # metadata beyond the latest tag (tagPattern / ReleaseName / {ARPVERSION}),
    # batched with one aliased repository field per package. Any resolution
    # failure includes the package unconditionally (fail-open); a failed batch
    # query includes only that batch.
    $resolvableArray = @($resolvable)
    for ($offset = 0; $offset -lt $resolvableArray.Count; $offset += $BatchSize) {
        $packageSlice = @($resolvableArray[$offset..([Math]::Min($offset + $BatchSize, $resolvableArray.Count) - 1)])
        $fields = for ($i = 0; $i -lt $packageSlice.Count; $i++) {
            $slicePackage = $packageSlice[$i]
            $owner, $name = (Get-WingetPrecheckPackageField -Package $slicePackage -Name 'repo').Split('/', 2)
            $sliceTagPattern = Get-WingetPrecheckPackageField -Package $slicePackage -Name 'tagPattern'
            $sliceVersionSource = Get-WingetPrecheckPackageField -Package $slicePackage -Name 'versionSource'
            $sliceUrl = Get-WingetPrecheckPackageField -Package $slicePackage -Name 'url'

            $selection = if (-not [string]::IsNullOrWhiteSpace($sliceTagPattern)) {
                # Window shared with Get-LatestGHVersionTag so precheck and full
                # job scan the same set of recent releases.
                "releases(first: $(Get-WingetReleaseLookbackWindow), orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName name isDraft isPrerelease publishedAt } }"
            }
            else {
                $releaseFields = 'tagName'
                if ($sliceVersionSource -eq 'ReleaseName') { $releaseFields += ' name' }
                if ($sliceUrl -match '\{ARPVERSION\}') { $releaseFields += ' releaseAssets(first: 100) { nodes { downloadUrl } }' }
                "latestRelease { $releaseFields }"
            }
            "u$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { $selection }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = $null
        try {
            $response = & $GraphQlInvoker $query
        }
        catch {
            Write-Warning "Update precheck release-metadata query failed for a batch of $($packageSlice.Count) packages: $($_.Exception.Message). Including them."
            foreach ($slicePackage in $packageSlice) {
                $include.Add([PSCustomObject]@{ Package = $slicePackage; Reason = 'PrecheckBatchFailed' })
            }
            continue
        }
        $graphQlErrorInfo = Get-WingetPrecheckErroredAlias -Response $response -ExpectedAliases @(for ($i = 0; $i -lt $packageSlice.Count; $i++) { "u$i" })
        if ($graphQlErrorInfo.WholeBatchFailed) {
            Write-Warning "Update precheck release-metadata query returned unattributable GraphQL errors for a batch of $($packageSlice.Count) packages. Including them."
            foreach ($slicePackage in $packageSlice) {
                $include.Add([PSCustomObject]@{ Package = $slicePackage; Reason = 'PrecheckBatchFailed' })
            }
            continue
        }
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $packageSlice.Count; $i++) {
            $slicePackage = $packageSlice[$i]
            if ($graphQlErrorInfo.ErroredAliases.Contains("u$i")) {
                # A per-alias error is a failed lookup, not an unresolvable
                # version source; include the package like a failed batch.
                Write-Warning "Update precheck release-metadata query returned an error for package $(Get-WingetPrecheckPackageField -Package $slicePackage -Name 'id'). Including it."
                $include.Add([PSCustomObject]@{ Package = $slicePackage; Reason = 'PrecheckBatchFailed' })
                continue
            }
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "u$i"
            $resolvedVersion = Resolve-WingetPrecheckReleaseVersion -Package $slicePackage -Repository $repository
            if ([string]::IsNullOrWhiteSpace([string]$resolvedVersion)) {
                $include.Add([PSCustomObject]@{ Package = $slicePackage; Reason = 'UnpredictableVersionSource' })
            }
            else {
                $candidates.Add([PSCustomObject]@{ Package = $slicePackage; Version = [string]$resolvedVersion })
            }
        }
    }

    # Pass 2: published versions per package from microsoft/winget-pkgs, batched
    # as multiple object() fields under a single repository field. When a batch
    # fails even after retries, the winget source index (a CDN copy of the
    # catalog that lags master by a few hours) supplies the published versions
    # instead — the lag can only cause an extra include, never a false skip.
    # Packages the fallback cannot resolve are included.
    $publishedStateByPackageId = @{}
    $sourceIndexVersionsById = $null
    $sourceIndexLoadAttempted = $false
    $candidatesArray = @($candidates)
    for ($offset = 0; $offset -lt $candidatesArray.Count; $offset += $BatchSize) {
        $candidateSlice = @($candidatesArray[$offset..([Math]::Min($offset + $BatchSize, $candidatesArray.Count) - 1)])
        $fields = for ($i = 0; $i -lt $candidateSlice.Count; $i++) {
            $packageId = Get-WingetPrecheckPackageField -Package $candidateSlice[$i].Package -Name 'id'
            $expression = 'master:' + (Get-WingetPackageRelativePath -PackageIdentifier $packageId)
            "p$($i): object(expression: $(ConvertTo-WingetGraphQlStringLiteral -Value $expression)) { ... on Tree { entries { name type } } }"
        }
        $query = "query {`n  repository(owner: `"microsoft`", name: `"winget-pkgs`") {`n" +
            (($fields | ForEach-Object { "    $_" }) -join "`n") +
            "`n  }`n}"
        $repository = $null
        $batchFailure = $null
        $graphQlErrorInfo = $null
        try {
            $response = & $GraphQlInvoker $query
            $graphQlErrorInfo = Get-WingetPrecheckErroredAlias -Response $response -ExpectedAliases @(for ($i = 0; $i -lt $candidateSlice.Count; $i++) { "p$i" })
            if ($graphQlErrorInfo.WholeBatchFailed) {
                throw 'GitHub GraphQL update precheck returned unattributable errors for the winget-pkgs batch.'
            }
            $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name 'repository'
            if ($null -eq $repository) {
                throw 'GitHub GraphQL update precheck could not read microsoft/winget-pkgs.'
            }
        }
        catch {
            $batchFailure = $_.Exception.Message
        }

        # Candidate indexes whose lookup failed: the whole slice after a failed
        # call, or the individually errored aliases of an otherwise successful
        # call. Both fall back to the winget source index below.
        $failedCandidateIndexes = [System.Collections.Generic.List[int]]::new()
        if ($null -eq $batchFailure) {
            for ($i = 0; $i -lt $candidateSlice.Count; $i++) {
                $packageId = Get-WingetPrecheckPackageField -Package $candidateSlice[$i].Package -Name 'id'
                if ($graphQlErrorInfo.ErroredAliases.Contains("p$i")) {
                    # A per-alias error is a failed lookup, never evidence the
                    # manifest folder is absent; only positive evidence may skip.
                    $failedCandidateIndexes.Add($i)
                    continue
                }
                $treeObject = Get-WingetGraphQlFieldValue -InputObject $repository -Name "p$i"
                if ($null -eq $treeObject) {
                    $publishedStateByPackageId[$packageId] = [PSCustomObject]@{ Status = 'Missing'; Versions = @() }
                    continue
                }
                $entriesValue = Get-WingetGraphQlFieldValue -InputObject $treeObject -Name 'entries'
                $entries = if ($null -eq $entriesValue) { @() } else { @($entriesValue) }
                $publishedVersions = @($entries |
                        Where-Object { "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'type')" -eq 'tree' } |
                        ForEach-Object { [string](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'name') })
                $publishedStateByPackageId[$packageId] = [PSCustomObject]@{ Status = 'Resolved'; Versions = $publishedVersions }
            }
            if ($failedCandidateIndexes.Count -eq 0) {
                continue
            }
            Write-Warning "Update precheck winget-pkgs query returned errors for $($failedCandidateIndexes.Count) of $($candidateSlice.Count) packages in a batch. Falling back to the winget source index for them."
        }
        else {
            Write-Warning "Update precheck winget-pkgs query failed for a batch of $($candidateSlice.Count) packages: $batchFailure. Falling back to the winget source index."
            for ($i = 0; $i -lt $candidateSlice.Count; $i++) {
                $failedCandidateIndexes.Add($i)
            }
        }

        if (-not $sourceIndexLoadAttempted) {
            $sourceIndexLoadAttempted = $true
            try {
                $indexVersions = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($row in @(& $SourceIndexProvider)) {
                    $rowId = [string](Get-WingetGraphQlFieldValue -InputObject $row -Name 'PackageIdentifier')
                    $rowVersion = [string](Get-WingetGraphQlFieldValue -InputObject $row -Name 'WingetVersion')
                    if (-not [string]::IsNullOrWhiteSpace($rowId) -and -not [string]::IsNullOrWhiteSpace($rowVersion)) {
                        $indexVersions[$rowId] = $rowVersion
                    }
                }
                $sourceIndexVersionsById = $indexVersions
            }
            catch {
                # Fail-open: without the index, failed batches stay included.
                Write-Warning "Winget source index fallback unavailable: $($_.Exception.Message). Including the affected packages."
            }
        }

        foreach ($i in $failedCandidateIndexes) {
            $packageId = Get-WingetPrecheckPackageField -Package $candidateSlice[$i].Package -Name 'id'
            if ($null -ne $sourceIndexVersionsById -and $sourceIndexVersionsById.ContainsKey($packageId)) {
                $publishedStateByPackageId[$packageId] = [PSCustomObject]@{ Status = 'Resolved'; Versions = @([string]$sourceIndexVersionsById[$packageId]) }
            }
            else {
                # Not in the index (brand-new package, or index unavailable): the
                # precheck cannot prove it is published, so it stays included.
                $publishedStateByPackageId[$packageId] = [PSCustomObject]@{ Status = 'Failed'; Versions = @() }
            }
        }
    }

    foreach ($candidate in $candidatesArray) {
        $package = $candidate.Package
        $version = [string]$candidate.Version
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'

        $publishedState = $publishedStateByPackageId[$packageId]
        if ($null -eq $publishedState -or $publishedState.Status -eq 'Failed') {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'PrecheckBatchFailed'; Version = $version })
            continue
        }

        if ($publishedState.Status -eq 'Missing') {
            Write-Warning "Package $packageId was not found in microsoft/winget-pkgs. Skipping it in the update precheck."
            $skipped.Add([PSCustomObject]@{ Package = $package; Reason = 'PackageMissing' })
            continue
        }

        $match = Find-WingetPublishedVersionMatch -Version $version -PublishedVersions @($publishedState.Versions)
        if ($null -ne $match) {
            $skipped.Add([PSCustomObject]@{ Package = $package; Reason = 'AlreadyPublished'; Version = $version })
        }
        elseif (-not $openPrCheckEnabled) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NewVersion'; Version = $version })
        }
        elseif (Test-PackageStateOpenPrFresh -StateFilePath $StateFilePath -PackageIdentifier $packageId -Version $version -TtlHours $OpenPrTtlHours) {
            # Cached marker is fresh — an open upstream PR for this version was
            # seen recently, so skip without spending a live search.
            $skipped.Add([PSCustomObject]@{ Package = $package; Reason = 'OpenPrExists'; Version = $version })
        }
        elseif ($openPrChecksUsed -ge $MaxOpenPrChecks) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NewVersion'; Version = $version })
        }
        else {
            $openPrChecksUsed++
            $hasOpenPr = $false
            $openPrCheckSucceeded = $true
            try {
                $hasOpenPr = [bool](& $OpenPrTester $packageId $version)
            }
            catch {
                # Fail-open: a PR search error must never suppress a real update.
                Write-Warning "Open-PR check for $packageId $version failed: $($_.Exception.Message). Including the package."
                $openPrCheckSucceeded = $false
            }

            if (-not $openPrCheckSucceeded) {
                $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NewVersion'; Version = $version })
            }
            elseif ($hasOpenPr) {
                $skipped.Add([PSCustomObject]@{ Package = $package; Reason = 'OpenPrExists'; Version = $version })
                try {
                    Set-PackageStateOpenPr -StateFilePath $StateFilePath -PackageIdentifier $packageId -Version $version
                }
                catch {
                    Write-Warning "Could not record open-PR marker for $packageId : $($_.Exception.Message)"
                }
            }
            else {
                $include.Add([PSCustomObject]@{ Package = $package; Reason = 'NewVersion'; Version = $version })
                try {
                    # Drop any stale marker so future runs don't trust it.
                    Set-PackageStateOpenPr -StateFilePath $StateFilePath -PackageIdentifier $packageId -Clear
                }
                catch {
                    Write-Warning "Could not clear open-PR marker for $packageId : $($_.Exception.Message)"
                }
            }
        }
    }

    return [PSCustomObject]@{ Include = @($include); Skipped = @($skipped) }
}
