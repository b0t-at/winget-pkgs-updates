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
    $ghVersionURL = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/$($wingetPackage.Substring(0, 1).ToLower())/$($wingetPackage.replace(".","/"))/$latestVersion/$wingetPackage.yaml"
    $ghCheckURL = "https://github.com/microsoft/winget-pkgs/blob/master/manifests/$($wingetPackage.Substring(0, 1).ToLower())/$($wingetPackage.replace(".","/"))/"

    $ghCheck = Invoke-WebRequest -Uri $ghCheckURL -Method Head -SkipHttpErrorCheck
    $ghVersionCheck = Invoke-WebRequest -Uri $ghVersionURL -Method Head -SkipHttpErrorCheck

    $result = [PSCustomObject]@{
        PackageExists  = $true
        VersionExists  = $false
        ShouldGenerate = $false
    }

    if ($ghCheck.StatusCode -eq 404) {
        Write-Host "Package not yet in winget. Please add new package manually"
        $result.PackageExists = $false
        return $result
    }

    if ($ghVersionCheck.StatusCode -eq 200) {
        Write-Host "Latest version of $wingetPackage $latestVersion is already present in winget."
        $result.VersionExists = $true
        return $result
    }

    Write-Host "Package $wingetPackage is in winget, but version $latestVersion is not present."
    $result.ShouldGenerate = $true
    return $result
}