function Apply-ManifestOverrides {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Overrides,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Placeholders = @{}
    )
    
    if (-not (Test-Path $ManifestPath)) {
        Write-Warning "Manifest file not found: $ManifestPath"
        return
    }
    
    $manifestContent = Get-Content -Path $ManifestPath -Raw
    $manifestLines = Get-Content -Path $ManifestPath
    
    # Apply placeholder substitutions to overrides first
    foreach ($placeholder in $Placeholders.GetEnumerator()) {
        foreach ($section in @('Add', 'Override')) {
            if ($Overrides.ContainsKey($section)) {
                $keys = @($Overrides[$section].Keys)  # Create array copy to avoid modification during iteration
                foreach ($key in $keys) {
                    $value = $Overrides[$section][$key]
                    if ($value -is [string]) {
                        $Overrides[$section][$key] = $value -replace "\{$($placeholder.Key)\}", $placeholder.Value
                    } elseif ($value -is [array]) {
                        for ($i = 0; $i -lt $value.Count; $i++) {
                            if ($value[$i] -is [string]) {
                                $value[$i] = $value[$i] -replace "\{$($placeholder.Key)\}", $placeholder.Value
                            }
                        }
                    }
                }
            }
        }
    }
    
    # Apply placeholder substitutions to original manifest
    foreach ($placeholder in $Placeholders.GetEnumerator()) {
        $manifestContent = $manifestContent -replace "\{$($placeholder.Key)\}", $placeholder.Value
    }
    
    # Convert content back to lines for processing
    $manifestLines = $manifestContent -split "`n"
    
    # Track modified content
    $modifiedLines = @()
    $droppedFields = if ($Overrides.ContainsKey('Drop')) { $Overrides['Drop'] } else { @() }
    $skipLines = @()
    
    # First pass: identify lines to drop
    for ($i = 0; $i -lt $manifestLines.Count; $i++) {
        $line = $manifestLines[$i]
        $trimmedLine = $line.TrimStart()
        
        # Check if this line should be dropped
        $shouldDrop = $false
        foreach ($dropField in $droppedFields) {
            if ($trimmedLine.StartsWith("$dropField" + ":")) {
                $shouldDrop = $true
                
                # Mark this line and any following indented lines for dropping
                $baseIndent = $line.Length - $trimmedLine.Length
                $skipLines += $i
                
                # Skip subsequent indented lines that belong to this field
                $j = $i + 1
                while ($j -lt $manifestLines.Count) {
                    $nextLine = $manifestLines[$j]
                    if ([string]::IsNullOrWhiteSpace($nextLine)) {
                        $skipLines += $j
                        $j++
                        continue
                    }
                    
                    $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                    if ($nextIndent -gt $baseIndent) {
                        $skipLines += $j
                        $j++
                    } else {
                        break
                    }
                }
                break
            }
        }
    }
    
    # Second pass: build modified content with overrides
    $overrideSection = if ($Overrides.ContainsKey('Override')) { $Overrides['Override'] } else { @{} }
    $addSection = if ($Overrides.ContainsKey('Add')) { $Overrides['Add'] } else { @{} }
    
    for ($i = 0; $i -lt $manifestLines.Count; $i++) {
        if ($skipLines -contains $i) {
            continue
        }
        
        $line = $manifestLines[$i]
        $trimmedLine = $line.TrimStart()
        
        # Check for override
        $overridden = $false
        foreach ($overrideKey in $overrideSection.Keys) {
            if ($trimmedLine.StartsWith("$overrideKey" + ":")) {
                $indent = $line.Length - $trimmedLine.Length
                $indentStr = " " * $indent
                
                $overrideValue = $overrideSection[$overrideKey]
                if ($overrideValue -is [array]) {
                    # Handle array values
                    $modifiedLines += "$indentStr$overrideKey" + ":"
                    foreach ($item in $overrideValue) {
                        $modifiedLines += "$indentStr  - $item"
                    }
                } elseif ($overrideValue -is [hashtable]) {
                    # Handle nested objects
                    $modifiedLines += "$indentStr$overrideKey" + ":"
                    foreach ($nestedKey in $overrideValue.Keys) {
                        $modifiedLines += "$indentStr  $nestedKey" + ": $($overrideValue[$nestedKey])"
                    }
                } else {
                    # Handle simple values
                    $modifiedLines += "$indentStr$overrideKey" + ": $overrideValue"
                }
                
                # Skip original lines for this field
                $baseIndent = $line.Length - $trimmedLine.Length
                $j = $i + 1
                while ($j -lt $manifestLines.Count) {
                    $nextLine = $manifestLines[$j]
                    if ([string]::IsNullOrWhiteSpace($nextLine)) {
                        $j++
                        continue
                    }
                    
                    $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                    if ($nextIndent -gt $baseIndent) {
                        $j++
                    } else {
                        break
                    }
                }
                $i = $j - 1
                $overridden = $true
                break
            }
        }
        
        if (-not $overridden) {
            $modifiedLines += $line
        }
    }
    
    # Add new fields at the end, but only if they haven't been overridden
    foreach ($addKey in $addSection.Keys) {
        # Skip if this key was already overridden
        $wasOverridden = $false
        foreach ($overrideKey in $overrideSection.Keys) {
            if ($addKey -eq $overrideKey) {
                $wasOverridden = $true
                break
            }
        }
        
        if (-not $wasOverridden) {
            $addValue = $addSection[$addKey]
            if ($addValue -is [array]) {
                $modifiedLines += "$addKey" + ":"
                foreach ($item in $addValue) {
                    $modifiedLines += "  - $item"
                }
            } elseif ($addValue -is [hashtable]) {
                $modifiedLines += "$addKey" + ":"
                foreach ($nestedKey in $addValue.Keys) {
                    $modifiedLines += "  $nestedKey" + ": $($addValue[$nestedKey])"
                }
            } else {
                $modifiedLines += "$addKey" + ": $addValue"
            }
        }
    }
    
    # Write modified content back to file
    $modifiedLines | Set-Content -Path $ManifestPath -Encoding UTF8
    
    Write-Host "Applied overrides to: $ManifestPath"
}