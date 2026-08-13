<#
.SYNOPSIS
    Validates winget manifest content before submission.

.DESCRIPTION
    Parses and validates YAML manifest files to ensure they meet quality requirements
    before submitting a Pull Request. This script performs semantic pre-validation
    checks that complement the Windows Sandbox testing, including comparison against
    the currently published manifest in microsoft/winget-pkgs.

.PARAMETER ManifestPath
    Path to the manifest folder containing the YAML files.

.PARAMETER PublishedPackageRoot
    Optional local path to the published package directory containing version folders.
    When omitted, the script compares against microsoft/winget-pkgs via the GitHub API.

.OUTPUTS
    PSCustomObject with properties:
    - Valid: Boolean indicating if the manifest passed all checks
    - Errors: Array of error messages (empty if Valid is true)
    - Warnings: Array of warning messages

.EXAMPLE
    .\Test-ManifestContent.ps1 -ManifestPath ".\manifests\m\Microsoft\VSCode\1.85.0"

.NOTES
    Exit Codes:
    0 = Success (manifest is valid)
    4 = Validation error (matches existing pattern)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = 'Path to the manifest folder containing YAML files.')]
    [ValidateScript({
        if (-not (Test-Path -Path $_ -PathType Container)) {
            throw "Manifest path '$_' does not exist or is not a directory."
        }
        return $true
    })]
    [string] $ManifestPath,

    [Parameter(Mandatory = $false, HelpMessage = 'Optional path to a published package directory that contains version folders.')]
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) {
            return $true
        }
        if (-not (Test-Path -Path $_ -PathType Container)) {
            throw "PublishedPackageRoot '$_' does not exist or is not a directory."
        }
        return $true
    })]
    [string] $PublishedPackageRoot,

    [Parameter(Mandatory = $false, HelpMessage = 'Allow an explicitly approved generator structural rewrite to remove inherited installer metadata.')]
    [switch] $AllowStructuralRewrite
)

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force
$module = Get-Module WingetMaintainerModule
$result = & $module {
    param($InnerManifestPath, $InnerPublishedPackageRoot, $InnerAllowStructuralRewrite)
    Test-WingetManifestContent -ManifestPath $InnerManifestPath -PublishedPackageRoot $InnerPublishedPackageRoot -AllowStructuralRewrite:$InnerAllowStructuralRewrite
} $ManifestPath $PublishedPackageRoot $AllowStructuralRewrite
Write-Output $result

if ($result.Valid) {
    exit 0
}

exit 4
