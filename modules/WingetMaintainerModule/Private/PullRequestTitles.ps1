function Test-WingetPkgsExistingPrTitle {
    <#
    .SYNOPSIS
        Tests whether a pull request title represents the package/version pair.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $updateTitle = "Update version: $PackageIdentifier version $Version"
    $legacyCombinedTitle = "Add version: $PackageIdentifier version $Version - $updateTitle"

    return $Title -ieq $updateTitle -or $Title -ieq $legacyCombinedTitle
}
