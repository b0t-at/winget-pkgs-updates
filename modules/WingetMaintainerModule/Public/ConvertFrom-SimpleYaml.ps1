function ConvertFrom-SimpleYaml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlContent
    )
    
    $result = @{}
    $lines = $YamlContent -split "`n" | ForEach-Object { $_.TrimEnd() }
    $currentSection = $null
    
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        
        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        
        $indent = $line.Length - $line.TrimStart().Length
        $trimmedLine = $line.TrimStart()
        
        # Handle top-level sections (Add, Override, Drop)
        if ($indent -eq 0 -and $trimmedLine.EndsWith(':')) {
            $currentSection = $trimmedLine.TrimEnd(':')
            $result[$currentSection] = @{}
            continue
        }
        
        # Handle Drop section (list items)
        if ($currentSection -eq 'Drop' -and $trimmedLine.StartsWith('- ')) {
            if (-not $result.ContainsKey($currentSection) -or $result[$currentSection] -isnot [array]) {
                $result[$currentSection] = @()
            }
            $result[$currentSection] = [array]$result[$currentSection] + $trimmedLine.Substring(2).Trim()
            continue
        }
        
        # Handle key-value pairs for Add and Override sections
        if (($currentSection -eq 'Add' -or $currentSection -eq 'Override') -and $trimmedLine.Contains(':')) {
            $colonIndex = $trimmedLine.IndexOf(':')
            $key = $trimmedLine.Substring(0, $colonIndex).Trim()
            $value = $trimmedLine.Substring($colonIndex + 1).Trim()
            
            # Ensure the section exists and is a hashtable
            if (-not $result.ContainsKey($currentSection)) {
                $result[$currentSection] = @{}
            }
            
            # Handle array values or multi-line content
            if ([string]::IsNullOrEmpty($value) -or $value -eq '|') {
                # Multi-line array or block scalar
                $arrayItems = @()
                $blockScalar = @()
                $j = $i + 1
                $isBlockScalar = ($value -eq '|')
                
                while ($j -lt $lines.Count) {
                    $nextLine = $lines[$j]
                    if ([string]::IsNullOrWhiteSpace($nextLine)) {
                        if ($isBlockScalar) {
                            $blockScalar += ""
                        }
                        $j++
                        continue
                    }
                    
                    $nextIndent = $nextLine.Length - $nextLine.TrimStart().Length
                    if ($nextIndent -le $indent) {
                        break
                    }
                    
                    $nextTrimmed = $nextLine.TrimStart()
                    if ($nextTrimmed.StartsWith('- ') -and -not $isBlockScalar) {
                        $arrayItems += $nextTrimmed.Substring(2).Trim()
                    } elseif ($isBlockScalar) {
                        $blockScalar += $nextLine.Substring($indent + 2)
                    } elseif ($nextTrimmed.Contains(':')) {
                        # Handle nested objects
                        $nestedColonIndex = $nextTrimmed.IndexOf(':')
                        $nestedKey = $nextTrimmed.Substring(0, $nestedColonIndex).Trim()
                        $nestedValue = $nextTrimmed.Substring($nestedColonIndex + 1).Trim()
                        
                        if ($result[$currentSection][$key] -isnot [hashtable]) {
                            $result[$currentSection][$key] = @{}
                        }
                        $result[$currentSection][$key][$nestedKey] = $nestedValue
                    }
                    $j++
                }
                
                if ($isBlockScalar) {
                    $result[$currentSection][$key] = ($blockScalar -join "`n").TrimEnd()
                } elseif ($arrayItems.Count -gt 0) {
                    $result[$currentSection][$key] = $arrayItems
                }
                $i = $j - 1
            } else {
                # Simple key-value pair
                $result[$currentSection][$key] = $value
            }
        }
    }
    
    return $result
}