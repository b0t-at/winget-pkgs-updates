function Apply-ManifestOverrides {
    param(
        [Parameter(Mandatory = $true)] [string] $ManifestPath,
        [Parameter(Mandatory = $false)] [string] $OverridePath,
        [Parameter(Mandatory = $false)] [hashtable] $PlaceholderValues = @{}
    )

    # Check if manifest file exists
    if (-not (Test-Path $ManifestPath)) {
        Write-Warning "Manifest file not found: $ManifestPath"
        return
    }

    # If no override path specified, look for override files next to the manifest
    if (-not $OverridePath) {
        $manifestDir = Split-Path $ManifestPath -Parent
        $manifestBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ManifestPath)
        $OverridePath = Join-Path $manifestDir "$manifestBaseName.overrides.yaml"
    }

    # Check if override file exists
    if (-not (Test-Path $OverridePath)) {
        Write-Verbose "No override file found: $OverridePath"
        return
    }

    Write-Host "Applying overrides from $OverridePath to $ManifestPath"

    try {
        # Read the override file
        $overrideContent = Get-Content -Path $OverridePath -Raw
        
        # Replace placeholders in override content
        foreach ($placeholder in $PlaceholderValues.Keys) {
            $overrideContent = $overrideContent -replace "\{\{$placeholder\}\}", $PlaceholderValues[$placeholder]
        }
        
        # Parse override using simple key-value approach
        $overrides = Parse-SimpleYaml $overrideContent
        
        # Read and parse the current manifest
        $manifestContent = Get-Content -Path $ManifestPath -Raw
        $manifest = Parse-SimpleYaml $manifestContent
        
        # Apply operations in order: Drop, Add, Override
        if ($overrides.ContainsKey('Drop') -and $overrides['Drop'] -is [array]) {
            Write-Host "Dropping fields: $($overrides['Drop'] -join ', ')"
            foreach ($fieldToDrop in $overrides['Drop']) {
                if ($manifest.ContainsKey($fieldToDrop)) {
                    $manifest.Remove($fieldToDrop)
                    Write-Verbose "Dropped field: $fieldToDrop"
                } else {
                    Write-Verbose "Field to drop not found: $fieldToDrop"
                }
            }
        }
        
        if ($overrides.ContainsKey('Add') -and $overrides['Add'] -is [hashtable]) {
            Write-Host "Adding fields: $($overrides['Add'].Keys -join ', ')"
            foreach ($key in $overrides['Add'].Keys) {
                if (-not $manifest.ContainsKey($key)) {
                    $manifest[$key] = $overrides['Add'][$key]
                    Write-Verbose "Added field: $key"
                } else {
                    Write-Verbose "Field already exists, not adding: $key"
                }
            }
        }
        
        if ($overrides.ContainsKey('Override') -and $overrides['Override'] -is [hashtable]) {
            Write-Host "Overriding fields: $($overrides['Override'].Keys -join ', ')"
            foreach ($key in $overrides['Override'].Keys) {
                $manifest[$key] = $overrides['Override'][$key]
                Write-Verbose "Overrode field: $key"
            }
        }
        
        # Convert back to YAML and write to file
        $newYamlContent = Convert-HashtableToYaml $manifest
        Set-Content -Path $ManifestPath -Value $newYamlContent -Encoding UTF8
        
        Write-Host "Successfully applied overrides to $ManifestPath"
        
    } catch {
        Write-Error "Failed to apply overrides to $ManifestPath`: $_"
    }
}

function Parse-SimpleYaml {
    param([string] $YamlContent)
    
    $result = @{}
    $lines = $YamlContent -split "`r?`n"
    $i = 0
    
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $trimmedLine = $line.Trim()
        
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
            $i++
            continue
        }
        
        # Check if this is a top-level section (no indentation and ends with :)
        if ($line -match '^[A-Za-z][^:]*:$') {
            $sectionName = $trimmedLine.TrimEnd(':')
            $i++
            
            # Parse the content of this section
            $sectionContent = @{}
            $sectionArray = @()
            $isArray = $false
            
            # Look ahead to determine structure
            while ($i -lt $lines.Count) {
                $sectionLine = $lines[$i]
                $sectionTrimmed = $sectionLine.Trim()
                
                if ([string]::IsNullOrWhiteSpace($sectionTrimmed) -or $sectionTrimmed.StartsWith('#')) {
                    $i++
                    continue
                }
                
                # Check if we've moved to a new top-level section
                if ($sectionLine -match '^[A-Za-z][^:]*:$') {
                    break  # Start of new section
                }
                
                # Check indentation - must be indented to be part of this section
                if (-not $sectionLine.StartsWith('  ')) {
                    break  # Not indented, so not part of this section
                }
                
                if ($sectionTrimmed.StartsWith('- ')) {
                    # Array item
                    $isArray = $true
                    $arrayValue = $sectionTrimmed.Substring(2).Trim()
                    $sectionArray += $arrayValue
                    $i++
                } elseif ($sectionTrimmed.Contains(':')) {
                    # Key-value pair
                    $parts = $sectionTrimmed.Split(':', 2)
                    $key = $parts[0].Trim()
                    $value = $parts[1].Trim()
                    
                    # Check if this value is an array (empty value with following array items)
                    if ([string]::IsNullOrEmpty($value)) {
                        $subArray = @()
                        $j = $i + 1
                        while ($j -lt $lines.Count) {
                            $arrayLine = $lines[$j]
                            $arrayTrimmed = $arrayLine.Trim()
                            
                            if ([string]::IsNullOrWhiteSpace($arrayTrimmed) -or $arrayTrimmed.StartsWith('#')) {
                                $j++
                                continue
                            }
                            
                            if ($arrayLine.StartsWith('    - ')) {
                                $subArray += $arrayTrimmed.Substring(2).Trim()
                                $j++
                            } else {
                                break
                            }
                        }
                        if ($subArray.Count -gt 0) {
                            $sectionContent[$key] = $subArray
                            $i = $j
                            continue
                        }
                    }
                    
                    # Parse simple value
                    if ($value -eq 'true') { $value = $true }
                    elseif ($value -eq 'false') { $value = $false }
                    elseif ($value -match '^\d+$') { $value = [int]$value }
                    elseif ($value.StartsWith('"') -and $value.EndsWith('"')) { 
                        $value = $value.Substring(1, $value.Length - 2) 
                    }
                    
                    $sectionContent[$key] = $value
                    $i++
                } else {
                    $i++
                }
            }
            
            # Store the section
            if ($isArray) {
                $result[$sectionName] = $sectionArray
            } else {
                $result[$sectionName] = $sectionContent
            }
            
        } elseif ($trimmedLine.Contains(':')) {
            # Top-level key-value pair
            $parts = $trimmedLine.Split(':', 2)
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            
            # Parse value
            if ($value -eq 'true') { $value = $true }
            elseif ($value -eq 'false') { $value = $false }
            elseif ($value -match '^\d+$') { $value = [int]$value }
            elseif ($value.StartsWith('"') -and $value.EndsWith('"')) { 
                $value = $value.Substring(1, $value.Length - 2) 
            }
            
            $result[$key] = $value
            $i++
        } else {
            $i++
        }
    }
    
    return $result
}

function Convert-HashtableToYaml {
    param([hashtable] $Hashtable)
    
    $result = ""
    
    foreach ($key in $Hashtable.Keys | Sort-Object) {
        $value = $Hashtable[$key]
        
        if ($value -is [hashtable]) {
            $result += "$key`:`n"
            foreach ($subKey in $value.Keys | Sort-Object) {
                $subValue = $value[$subKey]
                if ($subValue -is [array]) {
                    $result += "  $subKey`:`n"
                    foreach ($item in $subValue) {
                        if ($item -is [hashtable]) {
                            $result += "    -`n"
                            foreach ($itemKey in $item.Keys | Sort-Object) {
                                $formattedValue = if ($item[$itemKey] -is [string] -and ($item[$itemKey].Contains(' ') -or $item[$itemKey].Contains(':'))) { "`"$($item[$itemKey])`"" } else { $item[$itemKey] }
                                $result += "      $itemKey`: $formattedValue`n"
                            }
                        } else {
                            $result += "    - $item`n"
                        }
                    }
                } else {
                    $formattedValue = if ($subValue -is [string] -and ($subValue.Contains(' ') -or $subValue.Contains(':'))) { "`"$subValue`"" } else { $subValue }
                    $result += "  $subKey`: $formattedValue`n"
                }
            }
        } elseif ($value -is [array]) {
            $result += "$key`:`n"
            foreach ($item in $value) {
                if ($item -is [hashtable]) {
                    $result += "  -`n"
                    foreach ($itemKey in $item.Keys | Sort-Object) {
                        $formattedValue = if ($item[$itemKey] -is [string] -and ($item[$itemKey].Contains(' ') -or $item[$itemKey].Contains(':'))) { "`"$($item[$itemKey])`"" } else { $item[$itemKey] }
                        $result += "    $itemKey`: $formattedValue`n"
                    }
                } else {
                    $result += "  - $item`n"
                }
            }
        } else {
            $formattedValue = if ($value -is [string] -and ($value.Contains(' ') -or $value.Contains(':'))) { "`"$value`"" } else { $value }
            $result += "$key`: $formattedValue`n"
        }
    }
    
    return $result
}

