<#
.SYNOPSIS
    Checks for existing pull requests (PRs) for a specified package identifier and version in the 'microsoft/winget-pkgs' repository.

.DESCRIPTION
    The `Test-ExistingPRs` function searches for existing open and merged pull
    requests in the 'microsoft/winget-pkgs' repository that exactly match the
    specified package identifier and version. It uses one broad title search
    and validates the returned PR state client-side because GitHub Search does
    not support combining open and merged state qualifiers with a Boolean OR
    expression.

    The search authenticates with the dedicated `WINGET_UPSTREAM_READ_TOKEN`
    first (workflows pass the classic public-read WINGET_PAT there). When
    GitHub rejects that credential with an authorization or rate-limit status
    (401/403/404/429), the search retries once with
    `WINGET_UPSTREAM_READ_FALLBACK_TOKEN` and finally falls back to the
    anonymous public REST search endpoint. The fork-scoped submission token is
    never used for this search. API and response-shape failures are surfaced so
    callers fail closed instead of treating an uncertain result as no duplicate.

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
    $encodedQuery = [uri]::EscapeDataString($query)

    $credentialTiers = @(Get-WingetPkgsUpstreamReadCredentialTiers)
    $response = $null
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
        try {
            $response = Invoke-RestMethod `
                -Method Get `
                -Uri "https://api.github.com/search/issues?q=$encodedQuery&per_page=100" `
                -Headers $headers `
                -ErrorAction Stop
            break
        }
        catch {
            $statusCode = Get-WingetPkgsUpstreamReadFailureStatusCode -ErrorRecord $_
            $isLastTier = $tierIndex -eq ($credentialTiers.Count - 1)
            if ($isLastTier -or -not (Test-WingetPkgsUpstreamReadFailoverStatus -StatusCode $statusCode)) {
                throw
            }
            $nextTier = $credentialTiers[$tierIndex + 1]
            Write-Warning "Existing-PR search with $($tier.Label) failed with HTTP $statusCode; retrying with $($nextTier.Label)."
        }
    }
    if ($null -eq $response) {
        throw 'GitHub existing-PR search returned no response.'
    }

    $itemsProperty = $response.PSObject.Properties['items']
    $totalCountProperty = $response.PSObject.Properties['total_count']
    if ($null -eq $itemsProperty -or $null -eq $totalCountProperty -or $null -eq $itemsProperty.Value) {
        throw 'GitHub existing-PR search returned an incomplete response.'
    }

    $incompleteResultsProperty = $response.PSObject.Properties['incomplete_results']
    if ($null -ne $incompleteResultsProperty) {
        $incompleteResults = $false
        if (-not [bool]::TryParse("$($incompleteResultsProperty.Value)", [ref] $incompleteResults)) {
            throw 'GitHub existing-PR search returned an invalid incomplete_results value.'
        }
        if ($incompleteResults) {
            throw 'GitHub existing-PR search reported incomplete_results=true; refusing to make a duplicate decision.'
        }
    }

    $totalCount = 0
    if (-not [int]::TryParse("$($totalCountProperty.Value)", [ref] $totalCount) -or $totalCount -lt 0) {
        throw 'GitHub existing-PR search returned an invalid total_count.'
    }

    $existingPrs = @($itemsProperty.Value)
    if ($existingPrs.Count -ne $totalCount) {
        throw "GitHub existing-PR search returned $($existingPrs.Count) of $totalCount candidate(s); refusing to make an incomplete duplicate decision."
    }

    foreach ($existingPr in $existingPrs) {
        if ($null -eq $existingPr) {
            throw 'GitHub existing-PR search returned an invalid candidate.'
        }

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
            continue
        }

        $isMatchingPr = $state -eq 'open' -or (-not $OnlyOpen -and -not [string]::IsNullOrWhiteSpace("$mergedAt"))
        if ($isMatchingPr) {
            Write-Host "Found existing PR: $($titleProperty.Value)"
            Write-Host "-> $($existingPr.html_url)"
            return $true
        }
    }

    return $false
}
