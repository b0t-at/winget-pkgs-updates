function Test-PackageAndVersionInWinget {
    <#
    .SYNOPSIS
        Checks whether a package is present in the configured winget source and
        whether a specific version is already available there.

    .OUTPUTS
        PSCustomObject with properties:
          - PackageExists  : $true if winget has at least one version of the package.
          - VersionExists  : $true if the specified version is already published.
          - ShouldGenerate : $true when the package exists and the version is not present.
    #>
    param(
        [Parameter(Mandatory = $true)] [string] $latestVersion,
        [Parameter(Mandatory = $false)] [string] $wingetPackage = ${Env:PackageName}
    )
    Write-Host "Checking if $wingetPackage is already in winget and version $latestVersion is already present"
    Install-Winget
    $foundMessage, $textVersion, $separator, $wingetVersions = winget search --id $wingetPackage --source winget --versions

    $publishedVersions = @($wingetVersions | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $result = [PSCustomObject]@{
        PackageExists    = $true
        VersionExists    = $false
        ShouldGenerate   = $false
        RequestedVersion = $latestVersion
        PublishedVersion = $null
        VersionMatchType = $null
        CanonicalVersion = $latestVersion
    }

    if (!$publishedVersions) {
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

    $result.ShouldGenerate = $true
    return $result
}
