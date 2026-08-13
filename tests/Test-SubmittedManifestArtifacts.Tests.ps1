$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winget-submitted-manifest-artifacts-$([guid]::NewGuid().ToString('N'))")

function New-TestManifestFile {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [byte[]] $Bytes
    )

    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    Write-Host 'TEST: valid CRLF manifests pass artifact validation'
    $validPath = Join-Path $testRoot 'valid'
    New-TestManifestFile -Path (Join-Path $validPath 'Test.Package.yaml') -Bytes ([System.Text.Encoding]::UTF8.GetBytes("PackageIdentifier: Test.Package`r`nPackageVersion: 1.0.0`r`n"))
    $validResult = & $module { param($Path) Test-SubmittedManifestArtifacts -ManifestPath $Path } $validPath
    if (-not $validResult.Valid) {
        throw "Expected valid CRLF manifest to pass, got: $($validResult.Errors -join '; ')"
    }

    Write-Host 'TEST: bare LF manifests fail artifact validation'
    $lfPath = Join-Path $testRoot 'lf'
    New-TestManifestFile -Path (Join-Path $lfPath 'Test.Package.yaml') -Bytes ([System.Text.Encoding]::UTF8.GetBytes("PackageIdentifier: Test.Package`nPackageVersion: 1.0.0`n"))
    $lfResult = & $module { param($Path) Test-SubmittedManifestArtifacts -ManifestPath $Path } $lfPath
    if ($lfResult.Valid -or -not ($lfResult.Errors -join "`n" -match 'bare LF')) {
        throw "Expected bare LF manifest to fail with a line-ending error, got: $($lfResult | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: manifests without final CRLF fail artifact validation'
    $noFinalCrlfPath = Join-Path $testRoot 'no-final-crlf'
    New-TestManifestFile -Path (Join-Path $noFinalCrlfPath 'Test.Package.yaml') -Bytes ([System.Text.Encoding]::UTF8.GetBytes("PackageIdentifier: Test.Package`r`nPackageVersion: 1.0.0"))
    $noFinalCrlfResult = & $module { param($Path) Test-SubmittedManifestArtifacts -ManifestPath $Path } $noFinalCrlfPath
    if ($noFinalCrlfResult.Valid -or -not ($noFinalCrlfResult.Errors -join "`n" -match 'exactly one final CRLF')) {
        throw "Expected missing final CRLF to fail, got: $($noFinalCrlfResult | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: manifests with extra trailing blank lines fail artifact validation'
    $extraTrailingPath = Join-Path $testRoot 'extra-trailing'
    New-TestManifestFile -Path (Join-Path $extraTrailingPath 'Test.Package.yaml') -Bytes ([System.Text.Encoding]::UTF8.GetBytes("PackageIdentifier: Test.Package`r`nPackageVersion: 1.0.0`r`n`r`n"))
    $extraTrailingResult = & $module { param($Path) Test-SubmittedManifestArtifacts -ManifestPath $Path } $extraTrailingPath
    if ($extraTrailingResult.Valid -or -not ($extraTrailingResult.Errors -join "`n" -match 'more than one trailing blank line')) {
        throw "Expected extra trailing blank lines to fail, got: $($extraTrailingResult | ConvertTo-Json -Compress)"
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host 'Submitted manifest artifact validation tests passed.' -ForegroundColor Green
