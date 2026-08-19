<#
.SYNOPSIS
    Checks for existing pull requests (PRs) for a specified package identifier and version in the 'microsoft/winget-pkgs' repository.

.DESCRIPTION
    The `Test-ExistingPRs` function searches for existing open and merged pull
    requests in the selected repository that exactly match the specified
    package identifier and version. It paginates the GitHub Search results and
    validates the returned PR state client-side because GitHub Search does not
    support combining open and merged state qualifiers with a Boolean OR
    expression.

    The search authenticates with the dedicated `WINGET_UPSTREAM_READ_TOKEN`
    first (workflows pass the classic public-read WINGET_PAT there). When
    GitHub rejects that credential with an authorization or rate-limit status
    (401/403/404/429), the search retries once with
    `WINGET_UPSTREAM_READ_FALLBACK_TOKEN` and finally falls back to the
    anonymous public REST search endpoint. The fork-scoped submission token is
    never used for this search. A transient HTTP 422 from GitHub Search is
    retried twice with the same credential before the failure is surfaced.
    Rate-limited responses (HTTP 429, or 403 with an exhausted quota) are
    retried with header-aware backoff before falling over to the next
    credential tier. API and response-shape failures are surfaced so callers
    fail closed instead of treating an uncertain result as no duplicate.

    Title matching alone misses human-opened pull requests whose titles omit
    the package identifier (verified: upstream #419315 'Submitting Godot
    Launcher 1.11.1' raced the bot's duplicate #419629). When no title match
    is found, a second stage searches open pull requests that mention the
    version in their title and verifies their changed files against the
    package's manifest path (manifests/<first letter>/<identifier as
    directories>/<version>/) via the pull request files API. The second stage
    only ever reads the upstream repository and covers open pull requests.

.PARAMETER Version
    The version of the package to check for existing PRs. This parameter is mandatory.

.PARAMETER PackageIdentifier
    The identifier of the package to check for existing PRs. This parameter is optional and defaults to the value of the `PackageName` environment variable if not specified.

.EXAMPLE
    Test-ExistingPRs -Version "1.0.0" -PackageIdentifier "example.package"
    Checks for existing PRs for the package 'example.package' with version '1.0.0'.

.EXAMPLE
    Test-ExistingPRs -Version "1.0.0"
    Checks for existing PRs for the package specified in the `PackageName` environment variable with version '1.0.0'.

.OUTPUTS
    System.Boolean
    Returns `true` if any matching PRs are found, otherwise returns `false`.

#>
function Test-ExistingPRs {
    param(
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $false)] [string] $PackageIdentifier = ${Env:PackageName},
        [Parameter(Mandatory = $false)] [switch] $OnlyOpen,
        [Parameter(Mandatory = $false)] [string] $Repository = 'microsoft/winget-pkgs'
    )
    Write-Host "Checking for existing PRs for $PackageIdentifier $Version in $Repository"

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Repository must be an owner/repository name, not '$Repository'."
    }
    if ([string]::IsNullOrWhiteSpace($PackageIdentifier) -or [string]::IsNullOrWhiteSpace($Version)) {
        throw 'PackageIdentifier and Version are required to search for existing pull requests.'
    }

    $escapedPackageIdentifier = $PackageIdentifier.Replace('"', '\"')
    $escapedVersion = $Version.Replace('"', '\"')
    $openOnlyQuery = if ($OnlyOpen) { ' is:open' } else { '' }
    $query = "repo:$Repository is:pr$openOnlyQuery in:title `"$escapedPackageIdentifier`" `"$escapedVersion`""
    $titleCandidateEvaluator = {
        param($existingPr)

        $titleProperty = $existingPr.PSObject.Properties['title']
        $stateProperty = $existingPr.PSObject.Properties['state']
        if ($null -eq $titleProperty -or $null -eq $stateProperty -or [string]::IsNullOrWhiteSpace("$($titleProperty.Value)")) {
            throw 'GitHub existing-PR search returned a candidate without a title or state.'
        }

        $state = "$($stateProperty.Value)".ToLowerInvariant()
        if ($state -notin @('open', 'closed')) {
            throw "GitHub existing-PR search returned an unrecognized PR state '$state'."
        }

        $pullRequestProperty = $existingPr.PSObject.Properties['pull_request']
        $mergedAt = $null
        if ($state -eq 'closed') {
            if ($null -eq $pullRequestProperty -or $null -eq $pullRequestProperty.Value) {
                throw 'GitHub existing-PR search returned a closed PR without pull request metadata.'
            }

            $mergedAtProperty = $pullRequestProperty.Value.PSObject.Properties['merged_at']
            if ($null -eq $mergedAtProperty) {
                throw 'GitHub existing-PR search returned a closed PR without merged_at metadata.'
            }
            $mergedAt = $mergedAtProperty.Value
        }

        if (-not (Test-WingetPkgsExistingPrTitle `
                    -Title "$($titleProperty.Value)" `
                    -PackageIdentifier $PackageIdentifier `
                    -Version $Version)) {
            return $false
        }

        return ($state -eq 'open' -or (-not $OnlyOpen -and -not [string]::IsNullOrWhiteSpace("$mergedAt")))
    }

    $titleMatch = Find-WingetPkgsExistingPrSearchMatch -Query $query -CandidateEvaluator $titleCandidateEvaluator
    if ($null -ne $titleMatch) {
        Write-Host "Found existing PR: $($titleMatch.title)"
        Write-Host "-> $($titleMatch.html_url)"
        return $true
    }

    # The title search misses human-opened PRs whose titles omit the package
    # identifier. Search open PRs mentioning the version and compare their
    # changed files against the package's manifest path before concluding
    # that no duplicate exists.
    $manifestPathMatch = Find-WingetPkgsOpenPrForManifestPath `
        -Repository $Repository `
        -PackageIdentifier $PackageIdentifier `
        -Version $Version
    if ($null -ne $manifestPathMatch) {
        Write-Host "Found existing PR touching manifest path $($manifestPathMatch.ManifestPathPrefix): $($manifestPathMatch.Title)"
        Write-Host "-> $($manifestPathMatch.Url)"
        return $true
    }

    Write-Host "No matching PR found for $PackageIdentifier $Version in $Repository"
    return $false
}

function Invoke-WingetPkgsUpstreamReadRequest {
    <#
    .SYNOPSIS
        Performs one public upstream GitHub read with credential-tier failover.

    .DESCRIPTION
        Sends a GET request with the upstream read credential tiers
        (WINGET_UPSTREAM_READ_TOKEN, WINGET_UPSTREAM_READ_FALLBACK_TOKEN,
        anonymous), retrying transient HTTP 422 responses per tier and
        rate-limited responses with header-aware backoff. Non-failover
        failures surface to the caller so duplicate decisions fail closed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $OperationName
    )

    $maximumTransientAttempts = 3
    $response = $null
    $requestSucceeded = $false
    $credentialTiers = @(Get-WingetPkgsUpstreamReadCredentialTiers)
    for ($tierIndex = 0; $tierIndex -lt $credentialTiers.Count; $tierIndex++) {
        $tier = $credentialTiers[$tierIndex]
        $headers = @{
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'winget-pkgs-updates'
        }
        if (-not [string]::IsNullOrWhiteSpace($tier.Token)) {
            $headers.Authorization = "Bearer $($tier.Token)"
        }
        for ($attempt = 1; $attempt -le $maximumTransientAttempts; $attempt++) {
            try {
                $response = Invoke-WithGitHubRateLimitRetry `
                    -OperationName $OperationName `
                    -MaxAttempts 4 `
                    -MaxTotalWaitSeconds 120 `
                    -ScriptBlock {
                        Invoke-RestMethod `
                            -Method Get `
                            -Uri $Uri `
                            -Headers $headers `
                            -ErrorAction Stop
                    }
                $requestSucceeded = $true
                break
            }
            catch {
                $statusCode = Get-WingetPkgsUpstreamReadFailureStatusCode -ErrorRecord $_
                $responseBody = Get-WingetPkgsGitHubApiFailureResponseBody -ErrorRecord $_
                $responseDetail = if ([string]::IsNullOrWhiteSpace($responseBody)) {
                    ''
                }
                else {
                    " Response body: $responseBody"
                }

                if ($statusCode -eq 422 -and $attempt -lt $maximumTransientAttempts) {
                    Write-Warning "GitHub $OperationName returned HTTP 422 on attempt $attempt of $maximumTransientAttempts; retrying.$responseDetail"
                    Start-Sleep -Seconds $attempt
                    continue
                }

                $isLastTier = $tierIndex -eq ($credentialTiers.Count - 1)
                if ($isLastTier -or -not (Test-WingetPkgsUpstreamReadFailoverStatus -StatusCode $statusCode)) {
                    if (-not [string]::IsNullOrWhiteSpace($responseDetail)) {
                        Write-Warning "GitHub $OperationName failed with HTTP $statusCode.$responseDetail"
                    }
                    throw
                }
                $nextTier = $credentialTiers[$tierIndex + 1]
                Write-Warning "GitHub $OperationName with $($tier.Label) failed with HTTP $statusCode; retrying with $($nextTier.Label).$responseDetail"
                break
            }
        }
        if ($requestSucceeded) {
            break
        }
    }
    if (-not $requestSucceeded) {
        throw "GitHub $OperationName returned no response."
    }

    return $response
}

function Find-WingetPkgsExistingPrSearchMatch {
    <#
    .SYNOPSIS
        Pages through a GitHub Search query and returns the first matching candidate.

    .DESCRIPTION
        Validates every Search response shape (items, total_count,
        incomplete_results, page size) and fails closed on anomalies so an
        uncertain search never turns into a no-duplicate decision. The
        candidate evaluator receives each item and returns $true to stop the
        search with that item as the match; it may throw to surface malformed
        candidates.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)] [string] $Query,
        [Parameter(Mandatory = $true)] [scriptblock] $CandidateEvaluator,
        [Parameter()] [string] $OperationName = 'existing-PR search',
        [Parameter()] [string] $AdditionalQueryParameters = ''
    )

    $encodedQuery = [uri]::EscapeDataString($Query)
    $pageSize = 100
    $maximumSearchResults = 1000
    $page = 1
    $retrievedCount = 0
    $totalCount = $null

    while ($true) {
        $searchUri = "https://api.github.com/search/issues?q=$encodedQuery&per_page=$pageSize&page=$page$AdditionalQueryParameters"
        $response = Invoke-WingetPkgsUpstreamReadRequest -Uri $searchUri -OperationName "$OperationName page $page"

        $itemsProperty = $response.PSObject.Properties['items']
        $totalCountProperty = $response.PSObject.Properties['total_count']
        if ($null -eq $itemsProperty -or $null -eq $totalCountProperty -or $null -eq $itemsProperty.Value) {
            throw "GitHub $OperationName returned an incomplete response."
        }

        $incompleteResultsProperty = $response.PSObject.Properties['incomplete_results']
        if ($null -ne $incompleteResultsProperty) {
            $incompleteResults = $false
            if (-not [bool]::TryParse("$($incompleteResultsProperty.Value)", [ref] $incompleteResults)) {
                throw "GitHub $OperationName returned an invalid incomplete_results value."
            }
            if ($incompleteResults) {
                throw "GitHub $OperationName reported incomplete_results=true; refusing to make a duplicate decision."
            }
        }

        $responseTotalCount = 0
        if (-not [int]::TryParse("$($totalCountProperty.Value)", [ref] $responseTotalCount) -or $responseTotalCount -lt 0) {
            throw "GitHub $OperationName returned an invalid total_count."
        }
        if ($responseTotalCount -gt $maximumSearchResults) {
            throw "GitHub $OperationName returned $responseTotalCount candidate(s), exceeding the $maximumSearchResults-result API limit; refusing to make an incomplete duplicate decision."
        }
        if ($null -eq $totalCount) {
            $totalCount = $responseTotalCount
        }
        elseif ($totalCount -ne $responseTotalCount) {
            throw "GitHub $OperationName changed total_count while paging; refusing to make a duplicate decision."
        }

        $existingPrs = @($itemsProperty.Value)
        if ($existingPrs.Count -gt $pageSize) {
            throw "GitHub $OperationName returned more than $pageSize candidates on one page."
        }

        foreach ($existingPr in $existingPrs) {
            if ($null -eq $existingPr) {
                throw "GitHub $OperationName returned an invalid candidate."
            }

            if (& $CandidateEvaluator $existingPr) {
                return $existingPr
            }
        }

        $retrievedCount += $existingPrs.Count
        if ($retrievedCount -ge $totalCount) {
            return $null
        }
        if ($existingPrs.Count -lt $pageSize) {
            throw "GitHub $OperationName returned $retrievedCount of $totalCount candidate(s); refusing to make an incomplete duplicate decision."
        }
        $page++
    }
}

function Get-WingetPkgsManifestVersionPathPrefix {
    <#
    .SYNOPSIS
        Builds the winget-pkgs manifest directory prefix for a package version.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    # winget-pkgs layout: manifests/<first letter lowercase>/<identifier with
    # dots as directories>/<version>/, e.g.
    # manifests/g/GodotLauncher/Launcher/1.11.1/.
    $packagePath = $PackageIdentifier -replace '\.', '/'
    $firstChar = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    return "manifests/$firstChar/$packagePath/$Version/"
}

function Test-WingetPkgsTitleNamesOtherPackage {
    <#
    .SYNOPSIS
        Tests whether a PR title clearly names a different package identifier.

    .DESCRIPTION
        Used to skip pull request file reads for manifest-path candidates that
        obviously belong to another package (bot and tool titles always spell
        out the package identifier). A dotted token counts as another package
        identifier only when it plausibly IS a winget package identifier: at
        least two of its dot-separated segments start with a letter, its final
        segment is neither a known file extension (setup.exe, manifest.yaml)
        nor a common top-level domain (example.com), it is not part of a URL
        or a www-prefixed host name, and it neither contains the requested
        identifier nor equals the requested version. File names, domains, and
        version-like tokens ('1.2.3', 'v1.2.3') therefore never suppress a
        candidate.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $Title,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    # File-name tokens (setup.exe) and domain tokens (example.com) look like
    # dotted identifiers but never name a winget package; treating them as one
    # suppressed genuine human duplicates (e.g. 'Add GodotLauncher setup.exe 1.11.1').
    $fileExtensionSegments = @(
        'exe', 'msi', 'msix', 'zip', 'appx', 'appinstaller', 'nupkg', 'yaml',
        'yml', 'json', 'ps1', 'cmd', 'bat', 'dll', 'jar', 'deb', 'rpm', 'dmg',
        'pkg', 'txt', 'md', 'sig', 'sha256', 'iso', '7z', 'gz', 'xz', 'bin'
    )
    $topLevelDomainSegments = @('com', 'org', 'net', 'io', 'dev', 'de', 'app', 'sh', 'co', 'uk', 'us', 'me', 'gg')

    $dottedTokenMatches = @([regex]::Matches($Title, '(?<![A-Za-z0-9._+-])[A-Za-z0-9_+-]+(?:\.[A-Za-z0-9_+-]+)+(?![A-Za-z0-9._+-])'))
    foreach ($tokenMatch in $dottedTokenMatches) {
        $token = $tokenMatch.Value
        $segments = $token.Split('.')
        $letterLedSegments = @($segments | Where-Object { $_ -match '^[A-Za-z]' })
        if ($letterLedSegments.Count -lt 2) {
            continue
        }
        $finalSegment = $segments[-1].ToLowerInvariant()
        if ($finalSegment -in $fileExtensionSegments) {
            continue
        }
        if ($finalSegment -in $topLevelDomainSegments) {
            continue
        }
        if ($segments[0] -ieq 'www') {
            continue
        }
        # Tokens inside a URL (https://example.gallery/path) are host names or
        # path components, not package identifiers.
        if ($Title.Substring(0, $tokenMatch.Index) -match '(?i)[a-z][a-z0-9+.-]*://\S*$') {
            continue
        }
        if ($token -ieq $Version -or $token -ieq "v$Version") {
            continue
        }
        if ($token.IndexOf($PackageIdentifier, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            continue
        }
        return $true
    }

    return $false
}

function Find-WingetPkgsOpenPrForManifestPath {
    <#
    .SYNOPSIS
        Finds an open PR whose changed files touch the package's manifest path.

    .DESCRIPTION
        Searches open pull requests that mention the version in their title
        (human titles reliably carry the version even when they omit the
        package identifier) and verifies each candidate's changed files
        against the package's manifest version directory via the pull request
        files API. Returns the first matching candidate or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    $manifestPathPrefix = Get-WingetPkgsManifestVersionPathPrefix -PackageIdentifier $PackageIdentifier -Version $Version
    $escapedVersion = $Version.Replace('"', '\"')
    $searchQuery = "repo:$Repository is:pr is:open in:title `"$escapedVersion`""
    $candidates = [System.Collections.Generic.List[object]]::new()

    $candidateCollector = {
        param($existingPr)

        $titleProperty = $existingPr.PSObject.Properties['title']
        $stateProperty = $existingPr.PSObject.Properties['state']
        if ($null -eq $titleProperty -or $null -eq $stateProperty -or [string]::IsNullOrWhiteSpace("$($titleProperty.Value)")) {
            throw 'GitHub existing-PR manifest-path search returned a candidate without a title or state.'
        }
        if ("$($stateProperty.Value)".ToLowerInvariant() -ne 'open') {
            return $false
        }

        $numberProperty = $existingPr.PSObject.Properties['number']
        $pullRequestNumber = 0
        if ($null -eq $numberProperty -or -not [int]::TryParse("$($numberProperty.Value)", [ref] $pullRequestNumber) -or $pullRequestNumber -le 0) {
            throw 'GitHub existing-PR manifest-path search returned a candidate without a pull request number.'
        }

        if (Test-WingetPkgsTitleNamesOtherPackage `
                -Title "$($titleProperty.Value)" `
                -PackageIdentifier $PackageIdentifier `
                -Version $Version) {
            return $false
        }

        $urlProperty = $existingPr.PSObject.Properties['html_url']
        $candidates.Add([pscustomobject]@{
            Number = $pullRequestNumber
            Title  = "$($titleProperty.Value)"
            Url    = if ($null -ne $urlProperty) { "$($urlProperty.Value)" } else { '' }
        })
        return $false
    }

    $null = Find-WingetPkgsExistingPrSearchMatch `
        -Query $searchQuery `
        -CandidateEvaluator $candidateCollector `
        -OperationName 'existing-PR manifest-path search' `
        -AdditionalQueryParameters '&sort=created&order=desc'

    if ($candidates.Count -eq 0) {
        return $null
    }

    $maximumCandidateFileReads = 25
    $candidatesToCheck = @($candidates)
    if ($candidatesToCheck.Count -gt $maximumCandidateFileReads) {
        Write-Warning "The manifest-path duplicate check found $($candidatesToCheck.Count) open PR(s) mentioning version $Version; only the $maximumCandidateFileReads most recently created are compared against $manifestPathPrefix."
        $candidatesToCheck = @($candidatesToCheck[0..($maximumCandidateFileReads - 1)])
    }

    foreach ($candidate in $candidatesToCheck) {
        if (Test-WingetPkgsPullRequestTouchesPath -Repository $Repository -PullRequestNumber $candidate.Number -PathPrefix $manifestPathPrefix) {
            return [pscustomobject]@{
                Number             = $candidate.Number
                Title              = $candidate.Title
                Url                = $candidate.Url
                ManifestPathPrefix = $manifestPathPrefix
            }
        }
    }

    return $null
}

function Test-WingetPkgsPullRequestTouchesPath {
    <#
    .SYNOPSIS
        Tests whether a pull request changes any file under a path prefix.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [int] $PullRequestNumber,
        [Parameter(Mandatory = $true)] [string] $PathPrefix
    )

    $pageSize = 100
    $maximumFilePages = 10
    for ($page = 1; $page -le $maximumFilePages; $page++) {
        $filesUri = "https://api.github.com/repos/$Repository/pulls/$PullRequestNumber/files?per_page=$pageSize&page=$page"
        $response = Invoke-WingetPkgsUpstreamReadRequest -Uri $filesUri -OperationName "existing-PR files read for #$PullRequestNumber page $page"
        $files = if ($null -eq $response) { @() } else { @($response) }
        foreach ($file in $files) {
            if ($null -eq $file) {
                continue
            }
            $filenameProperty = $file.PSObject.Properties['filename']
            if ($null -eq $filenameProperty -or [string]::IsNullOrWhiteSpace("$($filenameProperty.Value)")) {
                throw "GitHub existing-PR files read for #$PullRequestNumber returned an entry without a filename."
            }
            if ("$($filenameProperty.Value)".StartsWith($PathPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        if ($files.Count -lt $pageSize) {
            return $false
        }
    }

    Write-Warning "Pull request #$PullRequestNumber in $Repository changes more than $($maximumFilePages * $pageSize) files; stopping the manifest-path comparison for it."
    return $false
}
