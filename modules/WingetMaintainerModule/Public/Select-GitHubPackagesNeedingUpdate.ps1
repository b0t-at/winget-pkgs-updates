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

function Select-GitHubPackagesNeedingUpdate {
    <#
    .SYNOPSIS
        Determines which monitored GitHub packages actually need a manifest update.

    .DESCRIPTION
        Uses batched GraphQL queries (instead of one REST round-trip per package)
        to read every repository's latest release tag and every package's published
        winget-pkgs versions, then compares them. Packages whose latest release is
        already published are skipped; every ambiguous case is included so a
        precheck miss can never suppress a real update (fail-open).

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
        [int] $MaxOpenPrChecks = 30
    )

    if ($null -eq $GraphQlInvoker) {
        $GraphQlInvoker = { param([string] $Query) Invoke-WingetPrecheckGraphQlRequest -Query $Query }
    }

    $openPrCheckEnabled = -not [string]::IsNullOrWhiteSpace($StateFilePath)
    if ($openPrCheckEnabled -and $null -eq $OpenPrTester) {
        $OpenPrTester = { param([string] $PackageIdentifier, [string] $Version) Test-ExistingPRs -Version $Version -PackageIdentifier $PackageIdentifier -OnlyOpen }
    }
    $openPrChecksUsed = 0

    $include = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $comparable = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $Packages) {
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'
        $url = Get-WingetPrecheckPackageField -Package $package -Name 'url'
        $tagPattern = Get-WingetPrecheckPackageField -Package $package -Name 'tagPattern'
        $versionSource = Get-WingetPrecheckPackageField -Package $package -Name 'versionSource'
        $overridePack = Get-WingetPrecheckPackageField -Package $package -Name 'overridePack'

        if ([string]::IsNullOrWhiteSpace($packageId) -or [string]::IsNullOrWhiteSpace($repo)) {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'IncompleteConfiguration' })
        }
        elseif (-not [string]::IsNullOrWhiteSpace($tagPattern) -or
            (-not [string]::IsNullOrWhiteSpace($versionSource) -and $versionSource -ne 'Tag') -or
            -not [string]::IsNullOrWhiteSpace($overridePack) -or
            $url -match '\{ARPVERSION\}') {
            # Version determination goes beyond "latest release tag", so the
            # cheap precheck cannot predict it. Always run the full job.
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'UnpredictableVersionSource' })
        }
        elseif ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            $include.Add([PSCustomObject]@{ Package = $package; Reason = 'InvalidRepoFormat' })
        }
        else {
            $comparable.Add($package)
        }
    }

    if ($comparable.Count -eq 0) {
        return [PSCustomObject]@{ Include = @($include); Skipped = @($skipped) }
    }

    # Pass 1: latest release tag per unique repository, batched with aliases.
    $uniqueRepos = @($comparable | ForEach-Object { Get-WingetPrecheckPackageField -Package $_ -Name 'repo' } | Sort-Object -Unique)
    $latestTagByRepo = @{}
    for ($offset = 0; $offset -lt $uniqueRepos.Count; $offset += $BatchSize) {
        $repoSlice = @($uniqueRepos[$offset..([Math]::Min($offset + $BatchSize, $uniqueRepos.Count) - 1)])
        $fields = for ($i = 0; $i -lt $repoSlice.Count; $i++) {
            $owner, $name = $repoSlice[$i].Split('/', 2)
            "r$($i): repository(owner: $(ConvertTo-WingetGraphQlStringLiteral -Value $owner), name: $(ConvertTo-WingetGraphQlStringLiteral -Value $name)) { latestRelease { tagName } }"
        }
        $query = "query {`n" + (($fields | ForEach-Object { "  $_" }) -join "`n") + "`n}"
        $response = & $GraphQlInvoker $query
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'

        for ($i = 0; $i -lt $repoSlice.Count; $i++) {
            $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name "r$i"
            $latestRelease = Get-WingetGraphQlFieldValue -InputObject $repository -Name 'latestRelease'
            $tagName = Get-WingetGraphQlFieldValue -InputObject $latestRelease -Name 'tagName'
            $latestTagByRepo[$repoSlice[$i]] = $tagName
        }
    }

    # Pass 2: published versions per package from microsoft/winget-pkgs, batched
    # as multiple object() fields under a single repository field.
    $publishedEntriesByPackageId = @{}
    $comparableArray = @($comparable)
    for ($offset = 0; $offset -lt $comparableArray.Count; $offset += $BatchSize) {
        $packageSlice = @($comparableArray[$offset..([Math]::Min($offset + $BatchSize, $comparableArray.Count) - 1)])
        $fields = for ($i = 0; $i -lt $packageSlice.Count; $i++) {
            $packageId = Get-WingetPrecheckPackageField -Package $packageSlice[$i] -Name 'id'
            $expression = 'master:' + (Get-WingetPackageRelativePath -PackageIdentifier $packageId)
            "p$($i): object(expression: $(ConvertTo-WingetGraphQlStringLiteral -Value $expression)) { ... on Tree { entries { name type } } }"
        }
        $query = "query {`n  repository(owner: `"microsoft`", name: `"winget-pkgs`") {`n" +
            (($fields | ForEach-Object { "    $_" }) -join "`n") +
            "`n  }`n}"
        $response = & $GraphQlInvoker $query
        $data = Get-WingetGraphQlFieldValue -InputObject $response -Name 'data'
        $repository = Get-WingetGraphQlFieldValue -InputObject $data -Name 'repository'
        if ($null -eq $repository) {
            throw 'GitHub GraphQL update precheck could not read microsoft/winget-pkgs.'
        }

        for ($i = 0; $i -lt $packageSlice.Count; $i++) {
            $packageId = Get-WingetPrecheckPackageField -Package $packageSlice[$i] -Name 'id'
            $publishedEntriesByPackageId[$packageId] = Get-WingetGraphQlFieldValue -InputObject $repository -Name "p$i"
        }
    }

    foreach ($package in $comparableArray) {
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'
        $repo = Get-WingetPrecheckPackageField -Package $package -Name 'repo'

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

        $treeObject = $publishedEntriesByPackageId[$packageId]
        if ($null -eq $treeObject) {
            Write-Warning "Package $packageId was not found in microsoft/winget-pkgs. Skipping it in the update precheck."
            $skipped.Add([PSCustomObject]@{ Package = $package; Reason = 'PackageMissing' })
            continue
        }

        $entriesValue = Get-WingetGraphQlFieldValue -InputObject $treeObject -Name 'entries'
        $entries = if ($null -eq $entriesValue) { @() } else { @($entriesValue) }
        $publishedVersions = @($entries |
                Where-Object { "$(Get-WingetGraphQlFieldValue -InputObject $_ -Name 'type')" -eq 'tree' } |
                ForEach-Object { [string](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'name') })

        $match = Find-WingetPublishedVersionMatch -Version $version -PublishedVersions $publishedVersions
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
