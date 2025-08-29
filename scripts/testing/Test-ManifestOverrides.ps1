# Test script for manifest overrides functionality

$scriptPath = $MyInvocation.MyCommand.Path
$scriptDirectory = Split-Path -Parent $scriptPath
Import-Module "$scriptDirectory\..\..\modules\WingetMaintainerModule" -Force

# Create a test manifest directory
$testDir = "/tmp/test-manifests"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

# Create sample manifest files to test overrides
$sampleLocaleManifest = @"
PackageIdentifier: MongoDB.Server
PackageVersion: 7.0.0
PackageLocale: en-US
Publisher: MongoDB Inc.
PackageName: MongoDB Server
ShortDescription: MongoDB is a document database
Tags:
  - old-tag
ReleaseDate: 2023-08-01
ManifestType: locale
ManifestVersion: 1.5.0
"@

$sampleInstallerManifest = @"
PackageIdentifier: MongoDB.Server
PackageVersion: 7.0.0
Installers:
  - Architecture: x64
    InstallerType: msi
    InstallerUrl: https://example.com/mongodb-server.msi
ReleaseDate: 2023-08-01
ManifestType: installer
ManifestVersion: 1.5.0
"@

# Write test manifests
$localeFile = Join-Path $testDir "MongoDB.Server.locale.en-US.yaml"
$installerFile = Join-Path $testDir "MongoDB.Server.installer.yaml"

Set-Content -Path $localeFile -Value $sampleLocaleManifest -Encoding UTF8
Set-Content -Path $installerFile -Value $sampleInstallerManifest -Encoding UTF8

Write-Host "Created test manifests:"
Write-Host "Locale: $localeFile"
Write-Host "Installer: $installerFile"

Write-Host "`nOriginal locale manifest content:"
Get-Content -Path $localeFile

Write-Host "`nOriginal installer manifest content:"
Get-Content -Path $installerFile

# Test the override functionality
Write-Host "`n--- Testing Override Functionality ---"

# Get overrides for MongoDB.Server
$localeOverrides = Get-ManifestOverrides -PackageIdentifier "MongoDB.Server" -ManifestType "locale" -OverrideBasePath "/home/runner/work/winget-pkgs-updates/winget-pkgs-updates/overrides"
$installerOverrides = Get-ManifestOverrides -PackageIdentifier "MongoDB.Server" -ManifestType "installer" -OverrideBasePath "/home/runner/work/winget-pkgs-updates/winget-pkgs-updates/overrides"

Write-Host "`nLocale overrides found:"
$localeOverrides | ConvertTo-Json -Depth 10

Write-Host "`nInstaller overrides found:"
$installerOverrides | ConvertTo-Json -Depth 10

# Get placeholders
$placeholders = Get-PackagePlaceholders -PackageIdentifier "MongoDB.Server" -Version "7.0.0"
Write-Host "`nPlaceholders:"
$placeholders | ConvertTo-Json -Depth 10

# Apply overrides
if ($localeOverrides.Count -gt 0) {
    Write-Host "`nApplying locale overrides..."
    Apply-ManifestOverrides -ManifestPath $localeFile -Overrides $localeOverrides -Placeholders $placeholders
}

if ($installerOverrides.Count -gt 0) {
    Write-Host "`nApplying installer overrides..."
    Apply-ManifestOverrides -ManifestPath $installerFile -Overrides $installerOverrides -Placeholders $placeholders
}

Write-Host "`n--- Results ---"
Write-Host "`nModified locale manifest content:"
Get-Content -Path $localeFile

Write-Host "`nModified installer manifest content:"
Get-Content -Path $installerFile

# Cleanup
Write-Host "`nCleaning up test files..."
Remove-Item -Path $testDir -Recurse -Force
Write-Host "Test completed!"