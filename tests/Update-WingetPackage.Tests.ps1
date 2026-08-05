$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Actual,

        [Parameter(Mandatory = $true)]
        [object[]]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $actualJson = ConvertTo-Json @($Actual) -Compress
    $expectedJson = ConvertTo-Json @($Expected) -Compress
    if ($actualJson -cne $expectedJson) {
        throw "$Message Expected $expectedJson, got $actualJson."
    }
}

function Get-TestWinMatschUrlArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$InstallerValues
    )

    return @(& $module {
            param([string[]]$Values)

            $entries = @(Get-InstallerUrlEntries -InstallerValues $Values)
            Get-WinMatschInstallerUrlArguments -InstallerEntries $entries
        } $InstallerValues)
}

function Invoke-TestUpdateWingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallerValue,

        [Parameter(Mandatory = $false)]
        [bool]$AllowStructuralRewrite = $false
    )

    return @(& $module {
            param(
                [string]$Value,
                [bool]$AllowRewrite
            )

            function Test-GitHubToken { 'test-token' }
            function Test-PackageAndVersionInGithub {
                [PSCustomObject]@{
                    PackageExists         = $true
                    ShouldGenerate        = $true
                    VersionExists         = $false
                    CanonicalVersion      = '1.0.0'
                    PublishedVersion      = $null
                    LatestPublishedVersion = $null
                }
            }
            function Test-ExistingPRs { $false }
            function Install-WinMatsch {}
            function Test-GeneratedInstallerArchitecture {}
            function winmatsch {
                $script:CapturedWinMatschArguments = @($args)
                $global:LASTEXITCODE = 0
            }

            $script:CapturedWinMatschArguments = @()
            Update-WingetPackage `
                -WingetPackage 'Test.Package' `
                -With 'WinMatsch' `
                -latestVersion '1.0.0' `
                -latestVersionURL $Value `
                -AllowStructuralRewrite $AllowRewrite | Out-Null

            $script:CapturedWinMatschArguments
        } $InstallerValue $AllowStructuralRewrite)
}

Write-Host 'TEST: plain URL is passed only through --urls'
$plainUrl = 'https://example.invalid/app.zip'
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $plainUrl) `
    -Expected @('--urls', $plainUrl) `
    -Message 'Plain URL arguments were incorrect.'

Write-Host 'TEST: multiple plain URLs are each passed only through --urls'
$plainUrls = @(
    'https://example.invalid/app-x64.zip'
    'https://example.invalid/app-arm64.zip'
)
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $plainUrls) `
    -Expected @('--urls', $plainUrls[0], '--urls', $plainUrls[1]) `
    -Message 'Multiple plain URL arguments were incorrect.'

Write-Host 'TEST: architecture-qualified URL is passed only through --url'
$architectureUrl = 'https://github.com/sunfish-shogi/shogihome/releases/download/v1.0.0/release-v1.0.0-win.zip|x86'
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $architectureUrl) `
    -Expected @('--url', $architectureUrl) `
    -Message 'Architecture-qualified URL arguments were incorrect.'

Write-Host 'TEST: F95Checker neutral URL is not passed a second time as a plain URL'
$f95CheckerUrl = 'https://github.com/Willy-JL/F95Checker/releases/download/12.0.0/F95Checker-Windows.zip|neutral'
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $f95CheckerUrl) `
    -Expected @('--url', $f95CheckerUrl) `
    -Message 'F95Checker URL arguments were incorrect.'

Write-Host 'TEST: scoped URL is passed only through --url'
$scopedUrl = 'https://example.invalid/app.zip|neutral|machine'
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $scopedUrl) `
    -Expected @('--url', $scopedUrl) `
    -Message 'Scoped URL arguments were incorrect.'

Write-Host 'TEST: mixed URL list passes every installer exactly once'
$mixedUrls = @(
    'https://example.invalid/plain-x64.zip'
    'https://example.invalid/qualified-x86.zip|x86'
    'https://example.invalid/plain-arm64.zip'
    'https://example.invalid/qualified-neutral.zip|neutral|user'
)
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $mixedUrls) `
    -Expected @(
        '--urls', $mixedUrls[0]
        '--url', $mixedUrls[1]
        '--urls', $mixedUrls[2]
        '--url', $mixedUrls[3]
    ) `
    -Message 'Mixed URL arguments were incorrect.'

Write-Host 'TEST: Update-WingetPackage sends the production-shaped URL only once'
$updateArguments = Invoke-TestUpdateWingetPackage -InstallerValue $f95CheckerUrl
$updateUrlArguments = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $updateArguments.Count; $index++) {
    if ($updateArguments[$index] -in @('--url', '--urls')) {
        $updateUrlArguments.Add($updateArguments[$index])
        $updateUrlArguments.Add($updateArguments[$index + 1])
        $index++
    }
}
Assert-SequenceEqual `
    -Actual $updateUrlArguments `
    -Expected @('--url', $f95CheckerUrl) `
    -Message 'Update-WingetPackage duplicated the F95Checker URL.'

Write-Host 'TEST: structural rewrite approval is opt-in'
$defaultUpdateArguments = Invoke-TestUpdateWingetPackage -InstallerValue $plainUrl
if ($defaultUpdateArguments -contains '--allow-structural-rewrite') {
    throw 'Update-WingetPackage enabled structural rewrite approval by default.'
}
$rewriteUpdateArguments = Invoke-TestUpdateWingetPackage -InstallerValue $plainUrl -AllowStructuralRewrite $true
if (@($rewriteUpdateArguments | Where-Object { $_ -eq '--allow-structural-rewrite' }).Count -ne 1) {
    throw 'Update-WingetPackage did not pass structural rewrite approval exactly once.'
}

Write-Host 'All Update-WingetPackage regression tests passed.' -ForegroundColor Green
