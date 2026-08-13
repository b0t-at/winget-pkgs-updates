$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validationScript = Join-Path $repositoryRoot 'scripts/validation/Test-ManifestContent.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winget-manifest-policy-guards-$([guid]::NewGuid().ToString('N'))")

function Write-ManifestFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Content
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $normalizedContent = ($Content -replace '\r?\n', "`r`n").TrimEnd([char[]]"`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $normalizedContent, [System.Text.UTF8Encoding]::new($false))
}

try {
    $emptyPublishedRoot = Join-Path $testRoot 'published-empty'
    New-Item -ItemType Directory -Path $emptyPublishedRoot -Force | Out-Null

    Write-Host 'TEST: default locale file must match declared locale'
    $defaultLocalePath = Join-Path $testRoot 'default-locale-mismatch'
    Write-ManifestFile -Path (Join-Path $defaultLocalePath 'Test.Package.installer.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
InstallerType: exe
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@
    Write-ManifestFile -Path (Join-Path $defaultLocalePath 'Test.Package.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    Write-ManifestFile -Path (Join-Path $defaultLocalePath 'Test.Package.locale.de-DE.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
PackageLocale: en-US
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $defaultLocalePath
    if ($LASTEXITCODE -ne 4) {
        throw "Expected default locale filename mismatch to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: locale manifests must not duplicate the default locale'
    $duplicateLocalePath = Join-Path $testRoot 'duplicate-default-locale'
    Write-ManifestFile -Path (Join-Path $duplicateLocalePath 'Test.Package.installer.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
InstallerType: exe
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@
    Write-ManifestFile -Path (Join-Path $duplicateLocalePath 'Test.Package.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    Write-ManifestFile -Path (Join-Path $duplicateLocalePath 'Test.Package.locale.en-US.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
PackageLocale: en-US
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@
    Write-ManifestFile -Path (Join-Path $duplicateLocalePath 'Test.Package.locale.fr-FR.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
PackageLocale: en-US
ManifestType: locale
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $duplicateLocalePath
    if ($LASTEXITCODE -ne 4) {
        throw "Expected duplicate default locale to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: installer manifest file name must match the document type'
    $wrongInstallerNamePath = Join-Path $testRoot 'wrong-installer-name'
    Write-ManifestFile -Path (Join-Path $wrongInstallerNamePath 'Test.Package.locale.en-US.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
InstallerType: exe
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@
    Write-ManifestFile -Path (Join-Path $wrongInstallerNamePath 'Test.Package.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $wrongInstallerNamePath
    if ($LASTEXITCODE -ne 4) {
        throw "Expected installer filename mismatch to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: installer type must match URL payload'
    $installerTypeMismatchPath = Join-Path $testRoot 'installer-type-mismatch'
    Write-ManifestFile -Path (Join-Path $installerTypeMismatchPath 'Test.Package.installer.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
InstallerType: msi
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.zip
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@
    Write-ManifestFile -Path (Join-Path $installerTypeMismatchPath 'Test.Package.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $installerTypeMismatchPath
    if ($LASTEXITCODE -ne 4) {
        throw "Expected installer type/URL mismatch to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: nested installer metadata must be complete'
    $nestedMetadataPath = Join-Path $testRoot 'nested-installer-incomplete'
    Write-ManifestFile -Path (Join-Path $nestedMetadataPath 'Test.Package.installer.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
InstallerType: zip
NestedInstallerType: portable
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.zip
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
"@
    Write-ManifestFile -Path (Join-Path $nestedMetadataPath 'Test.Package.yaml') -Content @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $nestedMetadataPath
    if ($LASTEXITCODE -ne 4) {
        throw "Expected incomplete nested installer metadata to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: singleton manifests use only the singleton file'
    $singletonPath = Join-Path $testRoot 'singleton'
    Write-ManifestFile -Path (Join-Path $singletonPath 'Test.Singleton.yaml') -Content @"
PackageIdentifier: Test.Singleton
PackageVersion: 1.0.0
PackageLocale: en-US
Publisher: Test Publisher
PackageName: Test Singleton
ShortDescription: Test singleton package
InstallerType: exe
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
ManifestType: singleton
ManifestVersion: 1.12.0
"@
    $null = & $validationScript -ManifestPath $singletonPath -PublishedPackageRoot $emptyPublishedRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Expected a valid singleton manifest to pass, got exit code $LASTEXITCODE."
    }

    Write-Host 'TEST: localized installers do not collide'
    $localizedInstallersPath = Join-Path $testRoot 'localized-installers'
    Write-ManifestFile -Path (Join-Path $localizedInstallersPath 'Test.Localized.yaml') -Content @"
PackageIdentifier: Test.Localized
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    Write-ManifestFile -Path (Join-Path $localizedInstallersPath 'Test.Localized.installer.yaml') -Content @"
PackageIdentifier: Test.Localized
PackageVersion: 1.0.0
InstallerType: exe
Scope: user
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerLocale: en-US
  InstallerUrl: https://downloads.example.invalid/app-en-US.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
- Architecture: x64
  InstallerLocale: de-DE
  InstallerUrl: https://downloads.example.invalid/app-de-DE.exe
  InstallerSha256: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
"@
    $null = & $validationScript -ManifestPath $localizedInstallersPath -PublishedPackageRoot $emptyPublishedRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Expected localized installer entries to pass collision validation, got exit code $LASTEXITCODE."
    }

    Write-Host 'TEST: nested installer files inherit from installer manifest'
    $nestedInheritancePath = Join-Path $testRoot 'nested-installer-inheritance'
    Write-ManifestFile -Path (Join-Path $nestedInheritancePath 'Test.Nested.yaml') -Content @"
PackageIdentifier: Test.Nested
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@
    Write-ManifestFile -Path (Join-Path $nestedInheritancePath 'Test.Nested.installer.yaml') -Content @"
PackageIdentifier: Test.Nested
PackageVersion: 1.0.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
- RelativeFilePath: app.exe
  PortableCommandAlias: app
ManifestType: installer
ManifestVersion: 1.12.0
Installers:
- Architecture: x64
  InstallerUrl: https://downloads.example.invalid/app.zip
  InstallerSha256: CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC
"@
    $null = & $validationScript -ManifestPath $nestedInheritancePath -PublishedPackageRoot $emptyPublishedRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Expected inherited nested installer metadata to pass, got exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Manifest policy guard tests passed.' -ForegroundColor Green
