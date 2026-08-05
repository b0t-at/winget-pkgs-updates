<#
.SYNOPSIS
    Checks for existing pull requests (PRs) for a specified package identifier and version in the 'microsoft/winget-pkgs' repository.

.DESCRIPTION
    The `Test-ExistingPRs` function searches for existing open and merged pull requests in the 'microsoft/winget-pkgs' repository that match the specified package identifier and version. 
    It uses the GitHub CLI (`gh`) to perform the search and returns `true` if any matching PRs are found, otherwise returns `false`.

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

.NOTES
    This function requires the GitHub CLI (`gh`) to be installed and authenticated.
#>
function Test-ExistingPRs {
    param(
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $false)] [string] $PackageIdentifier = ${Env:PackageName},
        [Parameter(Mandatory = $false)] [switch] $OnlyOpen,
        [Parameter(Mandatory = $false)] [string] $Repository = 'microsoft/winget-pkgs'
    )
    Write-Host "Checking for existing PRs for $PackageIdentifier $Version in $Repository"
    $ExistingOpenPRs = gh pr list --search "$($PackageIdentifier) $($Version) in:title draft:false" --state 'open' --json 'title,url' --repo $Repository | ConvertFrom-Json
    
    $ExistingPRs = if ($OnlyOpen) {
        @($ExistingOpenPRs)
    } else {
        $ExistingMergedPRs = gh pr list --search "$($PackageIdentifier) $($Version) in:title draft:false" --state 'merged' --json 'title,url' --repo $Repository | ConvertFrom-Json
        @($ExistingOpenPRs) + @($ExistingMergedPRs)
    }

    if ($ExistingPRs.Count -gt 0) {
        $ExistingPRs | ForEach-Object {
            Write-Host "Found existing PR: $($_.title)"
            Write-Host "-> $($_.url)"
        }
        return $true
    } else {
        return $false
    }
}
