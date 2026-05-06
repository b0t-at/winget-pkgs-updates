function Set-PackageState {
    <#
    .SYNOPSIS
        Creates or updates a package validation state entry in the state file.

    .DESCRIPTION
        If the same version and manifestHash already exist, increments validationCount and updates state/description/timestamp.
        If version or manifestHash differ, resets the entry entirely (new manifest supersedes old state).

    .PARAMETER StateFilePath
        Path to the package-state.json file.

    .PARAMETER PackageIdentifier
        The winget package identifier (e.g., "MongoDB.Server").

    .PARAMETER Version
        The package version string.

    .PARAMETER ManifestHash
        SHA256 hash of the combined manifest YAML files (the decision fingerprint).

    .PARAMETER InstallerHashes
        Array of all InstallerSha256 values from the installer manifest.

    .PARAMETER State
        Validation state: "VALIDATION_PASSED" or "VALIDATION_FAILED".

    .PARAMETER Description
        Optional description of the validation result (e.g., failure reason).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [string] $ManifestHash,

        [Parameter(Mandatory = $true)]
        [string[]] $InstallerHashes,

        [Parameter(Mandatory = $true)]
        [ValidateSet('VALIDATION_PASSED', 'VALIDATION_FAILED')]
        [string] $State,

        [Parameter(Mandatory = $false)]
        [string] $Description
    )

    # Load existing state or create new
    $stateData = @{}
    if (Test-Path -Path $StateFilePath -PathType Leaf) {
        $stateData = Get-Content -Path $StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $existingEntry = if ($stateData.ContainsKey($PackageIdentifier)) { $stateData[$PackageIdentifier] } else { $null }

    if ($null -ne $existingEntry -and $existingEntry.version -eq $Version -and $existingEntry.manifestHash -eq $ManifestHash) {
        # Same manifest — increment count, update state
        $existingEntry.validationCount = [int]$existingEntry.validationCount + 1
        $existingEntry.state = $State
        $existingEntry.lastUpdated = $now
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            $existingEntry.description = $Description
        }
        $existingEntry.installerHashes = @($InstallerHashes)
    }
    else {
        # New version or new manifest — reset entry
        $stateData[$PackageIdentifier] = @{
            version         = $Version
            manifestHash    = $ManifestHash
            installerHashes = @($InstallerHashes)
            state           = $State
            validationCount = 1
            description     = if (-not [string]::IsNullOrWhiteSpace($Description)) { $Description } else { '' }
            lastUpdated     = $now
        }
    }

    # Ensure directory exists
    $directory = Split-Path -Path $StateFilePath -Parent
    if (-not (Test-Path -Path $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    # Write state file with consistent formatting
    $stateData | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFilePath -Encoding utf8 -Force
}
