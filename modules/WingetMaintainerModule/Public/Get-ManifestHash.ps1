function Get-ManifestHash {
    <#
    .SYNOPSIS
        Computes a SHA256 hash of the manifest files and extracts installer hashes.

    .DESCRIPTION
        Gets all .yaml files in the manifest directory, sorts them by name, concatenates
        their content, and computes a SHA256 hash. This hash serves as a fingerprint to
        determine if the manifest has changed between runs.

        Also extracts all InstallerSha256 values from installer YAML files.

    .PARAMETER ManifestPath
        Path to the directory containing the manifest YAML files.

    .OUTPUTS
        PSCustomObject with properties:
        - ManifestHash: SHA256 hash string of the combined manifest content
        - InstallerHashes: Array of InstallerSha256 values found in the manifests
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -Path $_ -PathType Container })]
        [string] $ManifestPath
    )

    $yamlFiles = Get-ChildItem -Path $ManifestPath -Filter '*.yaml' -File | Sort-Object Name

    if ($yamlFiles.Count -eq 0) {
        throw "No YAML files found in manifest path: $ManifestPath"
    }

    # Concatenate all file contents for hashing
    $combinedContent = [System.Text.StringBuilder]::new()
    $installerHashes = [System.Collections.Generic.List[string]]::new()

    foreach ($file in $yamlFiles) {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        [void]$combinedContent.Append($content)

        # Extract InstallerSha256 values using regex (avoids YAML parser dependency)
        $hashMatches = [regex]::Matches($content, 'InstallerSha256\s*:\s*([A-Fa-f0-9]{64})')
        foreach ($match in $hashMatches) {
            $hash = $match.Groups[1].Value.ToUpperInvariant()
            if (-not $installerHashes.Contains($hash)) {
                $installerHashes.Add($hash)
            }
        }
    }

    # Compute SHA256 of combined content
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combinedContent.ToString())
    $hashBytes = $sha256.ComputeHash($bytes)
    $manifestHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToUpperInvariant()

    return [PSCustomObject]@{
        ManifestHash    = $manifestHash
        InstallerHashes = @($installerHashes)
    }
}
