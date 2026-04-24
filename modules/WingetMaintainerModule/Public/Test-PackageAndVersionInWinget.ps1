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

    $result = [PSCustomObject]@{
        PackageExists  = $true
        VersionExists  = $false
        ShouldGenerate = $false
    }

    if (!$wingetVersions) {
        Write-Host "Package not yet in winget. Please add new package manually"
        $result.PackageExists = $false
        return $result
    }

    if ($wingetVersions.contains($latestVersion)) {
        Write-Host "Latest version of $wingetPackage $latestVersion is already present in winget."
        $result.VersionExists = $true
        return $result
    }

    $result.ShouldGenerate = $true
    return $result
}
