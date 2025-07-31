function Get-ManifestOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageIdentifier,
        
        [Parameter(Mandatory = $true)]
        [string]$ManifestType,
        
        [Parameter(Mandatory = $false)]
        [string]$OverrideBasePath = "./overrides"
    )
    
    $overrides = @{}
    
    # Look for override files in this order of precedence:
    # 1. Package-specific override file: overrides/{PackageIdentifier}/{ManifestType}.yaml
    # 2. Package-specific generic override: overrides/{PackageIdentifier}/default.yaml
    # 3. Global override for manifest type: overrides/global/{ManifestType}.yaml
    # 4. Global default override: overrides/global/default.yaml
    
    $overrideFiles = @()
    
    # Package-specific overrides
    $packageOverrideDir = Join-Path $OverrideBasePath $PackageIdentifier
    if (Test-Path $packageOverrideDir) {
        $specificOverride = Join-Path $packageOverrideDir "$ManifestType.yaml"
        if (Test-Path $specificOverride) {
            $overrideFiles += $specificOverride
        }
        
        $defaultOverride = Join-Path $packageOverrideDir "default.yaml"
        if (Test-Path $defaultOverride) {
            $overrideFiles += $defaultOverride
        }
    }
    
    # Global overrides
    $globalOverrideDir = Join-Path $OverrideBasePath "global"
    if (Test-Path $globalOverrideDir) {
        $globalSpecificOverride = Join-Path $globalOverrideDir "$ManifestType.yaml"
        if (Test-Path $globalSpecificOverride) {
            $overrideFiles += $globalSpecificOverride
        }
        
        $globalDefaultOverride = Join-Path $globalOverrideDir "default.yaml"
        if (Test-Path $globalDefaultOverride) {
            $overrideFiles += $globalDefaultOverride
        }
    }
    
    # Merge overrides from all files (later files take precedence)
    foreach ($overrideFile in $overrideFiles) {
        try {
            Write-Host "Loading override file: $overrideFile"
            $yamlContent = Get-Content -Path $overrideFile -Raw
            $fileOverrides = ConvertFrom-SimpleYaml -YamlContent $yamlContent
            
            # Merge the overrides
            foreach ($section in @('Add', 'Override', 'Drop')) {
                if ($fileOverrides.ContainsKey($section)) {
                    if ($section -eq 'Drop') {
                        # For Drop section, combine arrays and remove duplicates
                        if (-not $overrides.ContainsKey($section)) {
                            $overrides[$section] = @()
                        }
                        $combinedItems = [array]$overrides[$section] + [array]$fileOverrides[$section]
                        $overrides[$section] = $combinedItems | Select-Object -Unique
                    } else {
                        # For Add and Override sections, merge hashtables
                        if (-not $overrides.ContainsKey($section)) {
                            $overrides[$section] = @{}
                        }
                        foreach ($key in $fileOverrides[$section].Keys) {
                            $overrides[$section][$key] = $fileOverrides[$section][$key]
                        }
                    }
                }
            }
        } catch {
            Write-Warning "Failed to load override file '$overrideFile': $($_.Exception.Message)"
        }
    }
    
    return $overrides
}

