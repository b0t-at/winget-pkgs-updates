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
        # BOM-less fallback encoding: if the reader detects a BOM it swaps in the
        # matching encoding (whose preamble round-trips the BOM on write); otherwise
        # the file is written back as UTF-8 without BOM.
        $reader = [System.IO.StreamReader]::new(
            $manifestFile.FullName,
            [System.Text.UTF8Encoding]::new($false),
            $true
        )
        try {
            $content = $reader.ReadToEnd()
            $encoding = $reader.CurrentEncoding
        }
        finally {
            $reader.Dispose()
        }

        $normalizedContent = [regex]::Replace($content, "`r`n|`r|`n", "`r`n")
        $normalizedContent = [regex]::Replace($normalizedContent, "(?:`r`n)+$", '')
        $normalizedContent += "`r`n"

        if ($normalizedContent -cne $content) {
            [System.IO.File]::WriteAllText($manifestFile.FullName, $normalizedContent, $encoding)
        }
    }
}
