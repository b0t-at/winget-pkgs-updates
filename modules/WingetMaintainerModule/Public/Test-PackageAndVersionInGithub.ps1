function Test-PackageAndVersionInGithub {
    <#
    .SYNOPSIS
        Checks whether a package exists in winget-pkgs on GitHub and whether a specific
        version is already published.

    .OUTPUTS
        PSCustomObject with properties:
          - PackageExists  : $true if the package folder exists on winget-pkgs/master.
          - VersionExists  : $true if the specified version is already published.
          - ShouldGenerate : $true when the package exists and the version does NOT yet exist.

    .NOTES
        Historically this function called `exit 0` / `exit 1` directly, which
        terminated the entire PowerShell host (and therefore the calling CI
        step) instead of letting the caller react. It now returns a status
        object and leaves control-flow decisions to `Update-WingetPackage`.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $latestVersion,
        [Parameter(Mandatory = $false)] [string] $wingetPackage = ${Env:PackageName}
    )
    Write-Host "Checking if $wingetPackage is already in winget (via GH) and version $latestVersion is already present"
    $publishedVersionInfo = Get-WingetPublishedVersionsFromGitHub -PackageIdentifier $wingetPackage
    $publishedVersions = @($publishedVersionInfo.Versions)

    $result = [PSCustomObject]@{
        PackageExists    = $true
        VersionExists    = $false
        ShouldGenerate   = $false
        RequestedVersion = $latestVersion
        PublishedVersion = $null
        VersionMatchType = $null
        CanonicalVersion = $latestVersion
    }

    if (-not $publishedVersionInfo.PackageExists) {
        Write-Host "Package not yet in winget. Please add new package manually"
        $result.PackageExists = $false
        return $result
    }

    $versionMatch = Find-WingetPublishedVersionMatch -Version $latestVersion -PublishedVersions $publishedVersions
    if ($versionMatch) {
        $result.VersionExists = $true
        $result.PublishedVersion = $versionMatch.Version
        $result.VersionMatchType = $versionMatch.MatchType
        $result.CanonicalVersion = $versionMatch.Version

        if ($versionMatch.MatchType -eq 'Exact') {
            Write-Host "Latest version of $wingetPackage $latestVersion is already present in winget."
        }
        else {
            Write-Host "Latest version of $wingetPackage $latestVersion is already present in winget as $($versionMatch.Version) ($($versionMatch.MatchType))."
        }

        return $result
    }

    $canonicalVersion = ConvertTo-WingetVersionStyle -Version $latestVersion -PublishedVersions $publishedVersions
    $result.CanonicalVersion = $canonicalVersion

    if ($canonicalVersion -ne $latestVersion) {
        Write-Host "Aligning PackageVersion notation with published winget versions: $latestVersion -> $canonicalVersion"
    }

    Write-Host "Package $wingetPackage is in winget, but version $latestVersion is not present."
    $result.ShouldGenerate = $true
    return $result
}