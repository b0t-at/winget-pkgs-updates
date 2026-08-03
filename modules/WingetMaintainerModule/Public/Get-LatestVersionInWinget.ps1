function Get-LatestVersionInWinget {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageId
    )

    Write-Host "Checking if $PackageId is already in winget (via GH) and find latest Version"

    $publishedVersionInfo = Get-WingetPublishedVersionsFromGitHub -PackageIdentifier $PackageId
    $latestVersion = $publishedVersionInfo.Versions |
        Sort-Object { Get-WingetSortableVersionKey -Version $_ } -Descending |
        Select-Object -First 1

    if ($latestVersion) {
        Write-Host "Latest Version of $PackageId in Winget: $latestVersion"
        return $latestVersion
    }

    Write-Host "No Version found for Package $PackageId"
    return $null
}
