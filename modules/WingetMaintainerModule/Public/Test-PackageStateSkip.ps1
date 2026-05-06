function Test-PackageStateSkip {
    <#
    .SYNOPSIS
        Determines whether a package should be skipped based on its validation history.

    .DESCRIPTION
        Returns $true if the package has the same version and manifestHash with state VALIDATION_FAILED
        and validationCount >= MaxFailures. Returns $false otherwise (new version, different manifest,
        previously passed, or fewer failures than threshold).

    .PARAMETER StateFilePath
        Path to the package-state.json file.

    .PARAMETER PackageIdentifier
        The winget package identifier.

    .PARAMETER Version
        The package version string.

    .PARAMETER ManifestHash
        SHA256 hash of the combined manifest YAML files.

    .PARAMETER MaxFailures
        Maximum number of failures before skipping. Default is 3.

    .OUTPUTS
        [bool] $true if the package should be skipped, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [string] $ManifestHash,

        [Parameter(Mandatory = $false)]
        [int] $MaxFailures = 3
    )

    $entry = Get-PackageState -StateFilePath $StateFilePath -PackageIdentifier $PackageIdentifier

    if ($null -eq $entry) {
        return $false
    }

    if ($entry.version -ne $Version) {
        return $false
    }

    if ($entry.manifestHash -ne $ManifestHash) {
        return $false
    }

    if ($entry.state -ne 'VALIDATION_FAILED') {
        return $false
    }

    if ([int]$entry.validationCount -ge $MaxFailures) {
        return $true
    }

    return $false
}
