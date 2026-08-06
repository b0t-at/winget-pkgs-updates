<#
.SYNOPSIS
    Checks for existing pull requests (PRs) for a specified package identifier and version in the 'microsoft/winget-pkgs' repository.

.DESCRIPTION
    The `Test-ExistingPRs` function searches for existing open and merged pull requests in the 'microsoft/winget-pkgs' repository that match the specified package identifier and version.
    It uses GitHub's public REST search endpoint without credentials so a
    fine-grained submission token scoped only to the source fork cannot turn a
    readable upstream lookup into a 404. It returns `true` if matching open or
    merged PRs are found, otherwise returns `false`.

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

    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'winget-pkgs-updates'
    }
    $escapedPackageIdentifier = $PackageIdentifier.Replace('"', '\"')
    $escapedVersion = $Version.Replace('"', '\"')
    $stateQuery = if ($OnlyOpen) { 'is:open' } else { '(is:open OR is:merged)' }
    $query = "repo:$Repository is:pr $stateQuery in:title `"$escapedPackageIdentifier $escapedVersion`""
    $encodedQuery = [uri]::EscapeDataString($query)
    $response = Invoke-RestMethod `
        -Method Get `
        -Uri "https://api.github.com/search/issues?q=$encodedQuery&per_page=100" `
        -Headers $headers `
        -ErrorAction Stop
    $existingPrs = @($response.items)

    if ($existingPrs.Count -gt 0) {
        $existingPrs | ForEach-Object {
            Write-Host "Found existing PR: $($_.title)"
            Write-Host "-> $($_.html_url)"
        }
        return $true
    }

    return $false
}
