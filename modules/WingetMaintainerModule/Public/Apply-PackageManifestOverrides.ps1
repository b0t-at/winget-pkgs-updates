function Apply-PackageManifestOverrides {
    param(
        [Parameter(Mandatory = $true)] [string] $ManifestPath,
        [Parameter(Mandatory = $true)] [string] $PackageName,
        [Parameter(Mandatory = $false)] [hashtable] $PlaceholderValues = @{}
    )
    
    Write-Host "Applying package manifest overrides for $PackageName"
    
    # Find all YAML manifest files in the manifest directory
    $manifestFiles = Get-ChildItem -Path $ManifestPath -Filter "*.yaml" -Recurse
    
    foreach ($manifestFile in $manifestFiles) {
        Write-Verbose "Processing manifest file: $($manifestFile.FullName)"
        
        # Determine override file path based on package name and manifest type
        $overridePath = Get-OverrideFilePath -PackageName $PackageName -ManifestFile $manifestFile.FullName
        
        if ($overridePath -and (Test-Path $overridePath)) {
            Write-Host "Found override file: $overridePath"
            Apply-ManifestOverrides -ManifestPath $manifestFile.FullName -OverridePath $overridePath -PlaceholderValues $PlaceholderValues
        } else {
            Write-Verbose "No override file found for $($manifestFile.Name)"
        }
    }
}

function Get-OverrideFilePath {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageName,
        [Parameter(Mandatory = $true)] [string] $ManifestFile
    )
    
    # Extract manifest type from filename (e.g., "installer", "locale.en-US", "defaultLocale")
    $manifestFileName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestFile)
    $manifestType = ""
    
    if ($manifestFileName.Contains(".installer")) {
        $manifestType = "installer"
    } elseif ($manifestFileName.Contains(".locale.")) {
        $localeMatch = [regex]::Match($manifestFileName, '\.locale\.([^.]+)')
        if ($localeMatch.Success) {
            $manifestType = "locale.$($localeMatch.Groups[1].Value)"
        }
    } elseif ($manifestFileName.EndsWith(".yaml")) {
        # This might be the main manifest file
        $manifestType = "version"
    }
    
    if ([string]::IsNullOrEmpty($manifestType)) {
        return $null
    }
    
    # Look for override files in the package scripts directory
    $packageScriptPath = "./scripts/Packages/Update-$PackageName.ps1"
    $packageDir = Split-Path $packageScriptPath -Parent
    
    # Try different override file naming patterns
    $overridePatterns = @(
        "$packageDir/$PackageName.$manifestType.overrides.yaml",
        "$packageDir/$PackageName.overrides.$manifestType.yaml",
        "$packageDir/overrides/$PackageName.$manifestType.yaml",
        "$packageDir/overrides/$manifestType.yaml"
    )
    
    foreach ($pattern in $overridePatterns) {
        if (Test-Path $pattern) {
            return $pattern
        }
    }
    
    return $null
}

function Get-PackageSpecificPlaceholders {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageName,
        [Parameter(Mandatory = $false)] [string] $Version,
        [Parameter(Mandatory = $false)] [string] $ReleaseNotes,
        [Parameter(Mandatory = $false)] [hashtable] $AdditionalValues = @{}
    )
    
    $placeholders = @{
        'PACKAGE_NAME' = $PackageName
        'VERSION' = $Version
        'RELEASE_NOTES' = $ReleaseNotes
        'CURRENT_DATE' = (Get-Date).ToString('yyyy-MM-dd')
        'CURRENT_YEAR' = (Get-Date).Year.ToString()
    }
    
    # Add any additional placeholder values
    foreach ($key in $AdditionalValues.Keys) {
        $placeholders[$key] = $AdditionalValues[$key]
    }
    
    return $placeholders
}