function Normalize-WingetManifestLineEndings {
    <#
    .SYNOPSIS
        Normalizes submitted manifest YAML files to CRLF with one final newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath
    )

    $manifestFiles = @(
        Get-ChildItem -LiteralPath $ManifestPath -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.yaml', '.yml') }
    )

    foreach ($manifestFile in $manifestFiles) {
        $fileBytes = [System.IO.File]::ReadAllBytes($manifestFile.FullName)
        $encoding = if ($fileBytes.Length -ge 4 -and
            $fileBytes[0] -eq 0xFF -and $fileBytes[1] -eq 0xFE -and
            $fileBytes[2] -eq 0x00 -and $fileBytes[3] -eq 0x00) {
            [System.Text.UTF32Encoding]::new($false, $true)
        }
        elseif ($fileBytes.Length -ge 4 -and
            $fileBytes[0] -eq 0x00 -and $fileBytes[1] -eq 0x00 -and
            $fileBytes[2] -eq 0xFE -and $fileBytes[3] -eq 0xFF) {
            [System.Text.UTF32Encoding]::new($true, $true)
        }
        elseif ($fileBytes.Length -ge 3 -and
            $fileBytes[0] -eq 0xEF -and $fileBytes[1] -eq 0xBB -and $fileBytes[2] -eq 0xBF) {
            [System.Text.UTF8Encoding]::new($true)
        }
        elseif ($fileBytes.Length -ge 2 -and $fileBytes[0] -eq 0xFF -and $fileBytes[1] -eq 0xFE) {
            [System.Text.UnicodeEncoding]::new($false, $true)
        }
        elseif ($fileBytes.Length -ge 2 -and $fileBytes[0] -eq 0xFE -and $fileBytes[1] -eq 0xFF) {
            [System.Text.UnicodeEncoding]::new($true, $true)
        }
        else {
            [System.Text.UTF8Encoding]::new($false)
        }

        $content = [System.IO.File]::ReadAllText($manifestFile.FullName)
        $normalizedContent = [regex]::Replace($content, "`r`n|`r|`n", "`r`n")
        $normalizedContent = [regex]::Replace($normalizedContent, "(?:`r`n)+$", '')
        $normalizedContent += "`r`n"

        [System.IO.File]::WriteAllText($manifestFile.FullName, $normalizedContent, $encoding)
    }
}
