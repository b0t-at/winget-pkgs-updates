$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winget-submitted-manifest-snapshot-$([guid]::NewGuid().ToString('N'))")

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://example.invalid/x64.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@ | Set-Content -LiteralPath (Join-Path $testRoot 'Test.Package.installer.yaml')
    @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
ManifestType: version
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $testRoot 'Test.Package.yaml')

    $first = & $module { param($Path) Get-SubmittedManifestSnapshot -ManifestPath $Path } $testRoot
    $second = & $module { param($Path) Get-SubmittedManifestSnapshot -ManifestPath $Path } $testRoot

    if (($first | ConvertTo-Json -Compress -Depth 5) -cne ($second | ConvertTo-Json -Compress -Depth 5)) {
        throw 'Manifest snapshot is not stable across repeated reads.'
    }

    @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.1
ManifestType: version
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $testRoot 'Test.Package.yaml')

    $third = & $module { param($Path) Get-SubmittedManifestSnapshot -ManifestPath $Path } $testRoot
    if ($third.ManifestHash -ceq $first.ManifestHash) {
        throw 'Manifest snapshot hash did not change after manifest content changed.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Submitted manifest snapshot tests passed.' -ForegroundColor Green
