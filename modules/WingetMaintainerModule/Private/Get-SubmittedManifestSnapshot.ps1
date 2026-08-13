function Get-SubmittedManifestSnapshot {
    <#
    .SYNOPSIS
        Captures a stable fingerprint for submit-ready manifest artifacts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath
    )

    $manifestFiles = @(
        Get-ChildItem -LiteralPath $ManifestPath -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.yaml', '.yml') } |
            Sort-Object -Property Name, FullName
    )

    if ($manifestFiles.Count -eq 0) {
        throw "No YAML manifest files found in manifest path: $ManifestPath"
    }

    $fileFingerprints = foreach ($manifestFile in $manifestFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($manifestFile.FullName)
        $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
        [PSCustomObject]@{
            Name = $manifestFile.Name
            Hash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToUpperInvariant()
        }
    }

    $manifestHash = Get-ManifestHash -ManifestPath $ManifestPath

    return [PSCustomObject]@{
        ManifestHash    = $manifestHash.ManifestHash
        InstallerHashes = @($manifestHash.InstallerHashes)
        Files           = @($fileFingerprints)
    }
}
