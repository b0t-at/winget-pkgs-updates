<#
.SYNOPSIS
    Validates winget manifest content before submission.

.DESCRIPTION
    Parses and validates YAML manifest files to ensure they meet quality requirements
    before submitting a Pull Request. This script performs pre-validation checks that
    complement the Windows Sandbox testing.

.PARAMETER ManifestPath
    Path to the manifest folder containing the YAML files.

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
    [string] $ManifestPath
)

#region Helper Functions

function Write-ValidationResult {
    param(
        [bool] $Valid,
        [string[]] $Errors,
        [string[]] $Warnings
    )
    
    $result = [PSCustomObject]@{
        Valid    = $Valid
        Errors   = $Errors
        Warnings = $Warnings
    }
    
    return $result
}

function Get-ManifestFiles {
    param([string] $Path)
    
    $yamlFiles = Get-ChildItem -Path $Path -Filter "*.yaml" -File
    
    if ($yamlFiles.Count -eq 0) {
        return $null
    }
    
    $manifests = @{
        Version   = $null
        Installer = $null
        Locales   = @()
    }
    
    foreach ($file in $yamlFiles) {
        if ($file.Name -match '\.installer\.yaml$') {
            $manifests.Installer = $file
        }
        elseif ($file.Name -match '\.locale\..+\.yaml$') {
            $manifests.Locales += $file
        }
        elseif ($file.Name -match '^[^.]+\.[^.]+.*\.yaml$' -and $file.Name -notmatch '\.(installer|locale)\.') {
            $manifests.Version = $file
        }
    }
    
    return $manifests
}

function Test-YamlParseable {
    param([string] $FilePath)
    
    try {
        $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        $parsed = $content | ConvertFrom-Yaml -ErrorAction Stop
        return @{ Success = $true; Data = $parsed; Error = $null }
    }
    catch {
        return @{ Success = $false; Data = $null; Error = $_.Exception.Message }
    }
}

#endregion

#region Main Validation Logic

Write-Host "=== Winget Manifest Content Validation ===" -ForegroundColor Cyan
Write-Host "Manifest Path: $ManifestPath" -ForegroundColor Gray
Write-Host ""

$errors = @()
$warnings = @()

# Ensure powershell-yaml module is available
if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
    Write-Host "Installing powershell-yaml module..." -ForegroundColor Yellow
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
}
Import-Module -Name powershell-yaml -ErrorAction Stop

# Get manifest files
Write-Host "--> Locating manifest files..." -ForegroundColor White
$manifestFiles = Get-ManifestFiles -Path $ManifestPath

if ($null -eq $manifestFiles) {
    $errors += "No YAML files found in manifest folder: $ManifestPath"
    Write-Host "ERROR: No YAML files found" -ForegroundColor Red
    Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    exit 4
}

# Check for required files
if ($null -eq $manifestFiles.Version) {
    $warnings += "Version manifest file not found (may be using single-file format)"
}
if ($null -eq $manifestFiles.Installer) {
    $warnings += "Installer manifest file not found (may be using single-file format)"
}
if ($manifestFiles.Locales.Count -eq 0) {
    $warnings += "No locale manifest files found"
}

$allFiles = @()
if ($manifestFiles.Version) { $allFiles += $manifestFiles.Version }
if ($manifestFiles.Installer) { $allFiles += $manifestFiles.Installer }
$allFiles += $manifestFiles.Locales

Write-Host "  Found $($allFiles.Count) manifest file(s):" -ForegroundColor Gray
foreach ($file in $allFiles) {
    Write-Host "    - $($file.Name)" -ForegroundColor Gray
}

# Validate each file is parseable YAML
Write-Host ""
Write-Host "--> Validating YAML syntax..." -ForegroundColor White

foreach ($file in $allFiles) {
    $parseResult = Test-YamlParseable -FilePath $file.FullName
    
    if ($parseResult.Success) {
        Write-Host "  [OK] $($file.Name)" -ForegroundColor Green
    }
    else {
        $errors += "Failed to parse $($file.Name): $($parseResult.Error)"
        Write-Host "  [FAIL] $($file.Name): $($parseResult.Error)" -ForegroundColor Red
    }
}

#region Placeholder Validation Checks
# TODO: Add additional validation checks here as needed:
# - Required fields presence (PackageIdentifier, PackageVersion, etc.)
# - URL format validation
# - Version format validation
# - Hash format validation (SHA256)
# - Installer type validation
# - Architecture validation
# - Scope validation
# - URL reachability checks (optional, can be slow)

Write-Host ""
Write-Host "--> Running content validation checks..." -ForegroundColor White

# Placeholder: Always pass for now
# This is where future validation logic will be added
Write-Host "  [PLACEHOLDER] Content validation checks passed (placeholder implementation)" -ForegroundColor Yellow
$warnings += "Content validation is using placeholder implementation - actual checks not yet implemented"

#endregion

# Summary
Write-Host ""
Write-Host "=== Validation Summary ===" -ForegroundColor Cyan

if ($warnings.Count -gt 0) {
    Write-Host "Warnings ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Errors ($($errors.Count)):" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "RESULT: FAILED" -ForegroundColor Red
    
    $result = Write-ValidationResult -Valid $false -Errors $errors -Warnings $warnings
    Write-Output $result
    exit 4
}

Write-Host ""
Write-Host "RESULT: PASSED" -ForegroundColor Green

$result = Write-ValidationResult -Valid $true -Errors $errors -Warnings $warnings
Write-Output $result
exit 0

#endregion
