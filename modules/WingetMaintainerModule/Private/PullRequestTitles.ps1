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

    if ($Title -ieq $updateTitle -or $Title -ieq $legacyCombinedTitle) {
        return $true
    }

    # GitHub Search can return community and tool-specific title wording. Match
    # the requested package and normalized version as whole title tokens so
    # "Foo.Bar" never accepts "Foo.BarPro", nor "1.2" accepts "1.2.1".
    $packagePattern = '(?<![A-Za-z0-9._-])' + [regex]::Escape($PackageIdentifier) + '(?![A-Za-z0-9._-])'
    if (-not [regex]::IsMatch($Title, $packagePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        return $false
    }

    $normalizedVersion = $Version.Trim()
    if ($normalizedVersion.Length -gt 1 -and $normalizedVersion[0] -in @('v', 'V')) {
        $normalizedVersion = $normalizedVersion.Substring(1)
    }
    if ([string]::IsNullOrWhiteSpace($normalizedVersion)) {
        return $false
    }

    $versionPattern = '(?<![A-Za-z0-9._+-])(?:v)?' + [regex]::Escape($normalizedVersion) + '(?![A-Za-z0-9._+-])'
    return [regex]::IsMatch($Title, $versionPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
