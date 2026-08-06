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

Write-Host 'TEST: architecture-qualified URL is passed through --urls and --url'
$architectureUrl = 'https://github.com/sunfish-shogi/shogihome/releases/download/v1.0.0/release-v1.0.0-win.zip|x86'
$architectureInstallerUrl = $architectureUrl.Split('|')[0]
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $architectureUrl) `
    -Expected @('--urls', $architectureInstallerUrl, '--url', $architectureUrl) `
    -Message 'Architecture-qualified URL arguments were incorrect.'

Write-Host 'TEST: F95Checker neutral URL is passed through --urls and --url'
$f95CheckerUrl = 'https://github.com/Willy-JL/F95Checker/releases/download/11.1.3/F95Checker-Windows.zip|neutral'
$f95CheckerInstallerUrl = $f95CheckerUrl.Split('|')[0]
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $f95CheckerUrl) `
    -Expected @('--urls', $f95CheckerInstallerUrl, '--url', $f95CheckerUrl) `
    -Message 'F95Checker URL arguments were incorrect.'

Write-Host 'TEST: scoped URL is passed through --urls and --url'
$scopedUrl = 'https://example.invalid/app.zip|neutral|machine'
$scopedInstallerUrl = $scopedUrl.Split('|')[0]
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $scopedUrl) `
    -Expected @('--urls', $scopedInstallerUrl, '--url', $scopedUrl) `
    -Message 'Scoped URL arguments were incorrect.'

Write-Host 'TEST: same-URL dual-scope entries preserve both source and override representations'
$zeroInstallUrl = 'https://github.com/0install/0install-win/releases/download/2.29.2/zero-install.exe'
$zeroInstallUrls = @(
    "$zeroInstallUrl|x86|user"
    "$zeroInstallUrl|x86|machine"
)
Assert-SequenceEqual `
    -Actual (Get-TestWinMatschUrlArguments -InstallerValues $zeroInstallUrls) `
    -Expected @(
        '--urls', $zeroInstallUrl
        '--url', $zeroInstallUrls[0]
        '--urls', $zeroInstallUrl
        '--url', $zeroInstallUrls[1]
    ) `
    -Message 'Same-URL dual-scope arguments were incorrect.'

Write-Host 'TEST: mixed URL list preserves source entries and qualified overrides'
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
        '--urls', $mixedUrls[1].Split('|')[0]
        '--url', $mixedUrls[1]
        '--urls', $mixedUrls[2]
        '--urls', $mixedUrls[3].Split('|')[0]
        '--url', $mixedUrls[3]
    ) `
    -Message 'Mixed URL arguments were incorrect.'

Write-Host 'TEST: Update-WingetPackage sends both representations for a qualified URL'
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
    -Expected @('--urls', $f95CheckerInstallerUrl, '--url', $f95CheckerUrl) `
    -Message 'Update-WingetPackage did not preserve the F95Checker source and override.'

Write-Host 'TEST: Update-WingetPackage preserves same-URL dual-scope entries'
$zeroInstallUpdateArguments = Invoke-TestUpdateWingetPackage -InstallerValue ($zeroInstallUrls -join ' ')
$zeroInstallUpdateUrlArguments = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $zeroInstallUpdateArguments.Count; $index++) {
    if ($zeroInstallUpdateArguments[$index] -in @('--url', '--urls')) {
        $zeroInstallUpdateUrlArguments.Add($zeroInstallUpdateArguments[$index])
        $zeroInstallUpdateUrlArguments.Add($zeroInstallUpdateArguments[$index + 1])
        $index++
    }
}
Assert-SequenceEqual `
    -Actual $zeroInstallUpdateUrlArguments `
    -Expected @(
        '--urls', $zeroInstallUrl
        '--url', $zeroInstallUrls[0]
        '--urls', $zeroInstallUrl
        '--url', $zeroInstallUrls[1]
    ) `
    -Message 'Update-WingetPackage did not preserve the same-URL dual-scope entries.'

Write-Host 'TEST: structural rewrite approval is opt-in'
$defaultUpdateArguments = Invoke-TestUpdateWingetPackage -InstallerValue $plainUrl
if ($defaultUpdateArguments -contains '--allow-structural-rewrite') {
    throw 'Update-WingetPackage enabled structural rewrite approval by default.'
}
$rewriteUpdateArguments = Invoke-TestUpdateWingetPackage -InstallerValue $plainUrl -AllowStructuralRewrite $true
if (@($rewriteUpdateArguments | Where-Object { $_ -eq '--allow-structural-rewrite' }).Count -ne 1) {
    throw 'Update-WingetPackage did not pass structural rewrite approval exactly once.'
}

Write-Host 'TEST: existing PR guard stops generation before the manifest generator starts'
$preGenerationGuardResult = & $module {
    $script:ExistingPrChecks = 0

    function Test-GitHubToken { 'test-token' }
    function Test-PackageAndVersionInGithub {
        [PSCustomObject]@{
            PackageExists          = $true
            ShouldGenerate         = $true
            VersionExists          = $false
            CanonicalVersion       = '1.0.0'
            PublishedVersion       = $null
            LatestPublishedVersion = $null
        }
    }
    function Test-ExistingPRs {
        $script:ExistingPrChecks++
        return $true
    }
    function Install-WinMatsch {
        throw 'Manifest generation started despite an existing upstream PR.'
    }

    $result = Update-WingetPackage `
        -WingetPackage 'Test.Package' `
        -With 'WinMatsch' `
        -latestVersion '1.0.0' `
        -latestVersionURL 'https://example.invalid/app.zip'

    [PSCustomObject]@{
        Result           = $result
        ExistingPrChecks = $script:ExistingPrChecks
    }
}
if ($preGenerationGuardResult.ExistingPrChecks -ne 1) {
    throw "The pre-generation existing-PR guard ran $($preGenerationGuardResult.ExistingPrChecks) times instead of once."
}
if ($preGenerationGuardResult.Result.Generated -or $preGenerationGuardResult.Result.Reason -cne 'PRExists') {
    throw "The pre-generation existing-PR guard did not stop generation: $($preGenerationGuardResult.Result | ConvertTo-Json -Compress)"
}

Write-Host 'All Update-WingetPackage regression tests passed.' -ForegroundColor Green
