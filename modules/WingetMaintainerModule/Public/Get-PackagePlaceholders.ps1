function Get-PackagePlaceholders {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageIdentifier,
        
        [Parameter(Mandatory = $true)]
        [string]$Version,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$LatestInfo = @{}
    )
    
    $placeholders = @{
        'PACKAGE_ID' = $PackageIdentifier
        'VERSION' = $Version
        'CURRENT_DATE' = (Get-Date).ToString('yyyy-MM-dd')
        'CURRENT_YEAR' = (Get-Date).Year
    }
    
    # Add any additional info from the latest version data
    foreach ($key in $LatestInfo.Keys) {
        $placeholders["LATEST_$($key.ToUpper())"] = $LatestInfo[$key]
    }
    
    return $placeholders
}