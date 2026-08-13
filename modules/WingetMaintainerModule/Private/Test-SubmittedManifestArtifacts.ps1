function Test-SubmittedManifestArtifacts {
    <#
    .SYNOPSIS
        Validates submit-ready manifest artifacts for text-format guardrails.

    .DESCRIPTION
        Checks the generated manifest files that will be submitted to winget-pkgs
        and fails closed when they contain submit-relevant formatting issues such
        as bare LF line endings, mixed line endings, or missing/final extra CRLFs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath
    )

    $manifestFiles = @(
        Get-ChildItem -LiteralPath $ManifestPath -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.yaml', '.yml') } |
            Sort-Object -Property FullName
    )

    if ($manifestFiles.Count -eq 0) {
        return [PSCustomObject]@{
            Valid    = $false
            Errors   = @("No YAML manifest files found under '$ManifestPath'.")
            Warnings = @()
        }
    }

    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($manifestFile in $manifestFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($manifestFile.FullName)
        if ($bytes.Length -eq 0) {
            $errors.Add("$($manifestFile.Name): file is empty.")
            continue
        }

        if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
            $errors.Add("$($manifestFile.Name): UTF-8 BOM is not allowed in submitted manifests.")
        }

        $bareLfCount = 0
        $crOnlyCount = 0
        $crlfCount = 0

        for ($index = 0; $index -lt $bytes.Length; $index++) {
            switch ($bytes[$index]) {
                10 {
                    if ($index -eq 0 -or $bytes[$index - 1] -ne 13) {
                        $bareLfCount++
                    }
                }
                13 {
                    if ($index + 1 -lt $bytes.Length -and $bytes[$index + 1] -eq 10) {
                        $crlfCount++
                    }
                    else {
                        $crOnlyCount++
                    }
                }
            }
        }

        if ($bareLfCount -gt 0) {
            $errors.Add("$($manifestFile.Name): contains $bareLfCount bare LF line ending(s); submitted manifests must use CRLF only.")
        }
        if ($crOnlyCount -gt 0) {
            $errors.Add("$($manifestFile.Name): contains $crOnlyCount bare CR line ending(s); submitted manifests must use CRLF only.")
        }
        if ($bytes.Length -lt 2 -or $bytes[$bytes.Length - 2] -ne 13 -or $bytes[$bytes.Length - 1] -ne 10) {
            $errors.Add("$($manifestFile.Name): must end with exactly one final CRLF.")
            continue
        }

        if ($bytes.Length -ge 4 -and $bytes[$bytes.Length - 4] -eq 13 -and $bytes[$bytes.Length - 3] -eq 10) {
            $errors.Add("$($manifestFile.Name): ends with more than one trailing blank line; expected exactly one final CRLF.")
        }
    }

    return [PSCustomObject]@{
        Valid    = $errors.Count -eq 0
        Errors   = @($errors)
        Warnings = @()
    }
}
