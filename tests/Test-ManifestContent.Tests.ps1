$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validationScript = Join-Path $repositoryRoot 'scripts/validation/Test-ManifestContent.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winget-manifest-content-test-$([guid]::NewGuid().ToString('N'))")
$publishedVersionPath = Join-Path $testRoot 'published/1.0.0'
$generatedManifestPath = Join-Path $testRoot 'generated'

function Write-TestManifest {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $Hash,
        [Parameter(Mandatory = $true)] [bool] $IncludeNestedInstallerMetadata
    )

    $nestedInstallerMetadata = if ($IncludeNestedInstallerMetadata) {
        @"
NestedInstallerType: nullsoft
NestedInstallerFiles:
- RelativeFilePath: Pinokio Setup.exe
"@
    }
    else {
        ''
    }

    $installerManifest = @"
PackageIdentifier: Test.StructuralRewrite
PackageVersion: $Version
InstallerType: nullsoft
$nestedInstallerMetadata
Installers:
- Architecture: x64
  InstallerUrl: https://example.invalid/test-$Version.exe
  InstallerSha256: $Hash
ManifestType: installer
ManifestVersion: 1.12.0
"@

    $versionManifest = @"
PackageIdentifier: Test.StructuralRewrite
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        (Join-Path $Path 'Test.StructuralRewrite.installer.yaml'),
        (($installerManifest -replace '\r?\n', "`r`n").TrimEnd([char[]]"`r`n") + "`r`n"),
        $utf8NoBom
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $Path 'Test.StructuralRewrite.yaml'),
        (($versionManifest -replace '\r?\n', "`r`n").TrimEnd([char[]]"`r`n") + "`r`n"),
        $utf8NoBom
    )
}

try {
    New-Item -ItemType Directory -Path $publishedVersionPath, $generatedManifestPath -Force | Out-Null
    Write-TestManifest `
        -Path $publishedVersionPath `
        -Version '1.0.0' `
        -Hash ('A' * 64) `
        -IncludeNestedInstallerMetadata $true
    Write-TestManifest `
        -Path $generatedManifestPath `
        -Version '1.1.0' `
        -Hash ('B' * 64) `
        -IncludeNestedInstallerMetadata $false

    Write-Host 'TEST: structural metadata removal fails without explicit approval'
    $null = & $validationScript -ManifestPath $generatedManifestPath -PublishedPackageRoot (Split-Path -Parent $publishedVersionPath) -AllowStructuralRewrite:$false
    if ($LASTEXITCODE -ne 4) {
        throw "Expected metadata consistency validation to fail with exit code 4, got $LASTEXITCODE."
    }

    Write-Host 'TEST: structural metadata removal passes with explicit approval'
    $null = & $validationScript -ManifestPath $generatedManifestPath -PublishedPackageRoot (Split-Path -Parent $publishedVersionPath) -AllowStructuralRewrite:$true
    if ($LASTEXITCODE -ne 0) {
        throw "Expected approved structural rewrite validation to pass, got exit code $LASTEXITCODE."
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Test-ManifestContent regression tests passed.' -ForegroundColor Green
