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
    function winmatsch {
        throw 'Manifest generation started despite an existing upstream PR.'
    }
    function Test-GeneratedInstallerArchitecture {
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

Write-Host 'TEST: submission policy hold stops generation and reports its reason'
$policyHoldResult = & $module {
    $script:PolicyHoldCalls = @()

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
    function Test-ExistingPRs { $false }
    function Get-WingetPreSubmissionHold {
        param($PackageId, $Version, $InstallerUrls, $Repository, $GHRepo, $GHTag, $MinReleaseAgeHours)
        $script:PolicyHoldCalls += [PSCustomObject]@{ PackageId = $PackageId; Version = $Version; InstallerUrls = @($InstallerUrls); MinReleaseAgeHours = $MinReleaseAgeHours }
        [PSCustomObject]@{ Reason = 'ReleaseTooFresh'; Detail = 'release is 1 h old' }
    }
    function Install-WinMatsch { throw 'Manifest generation started despite a submission policy hold.' }
    function winmatsch { throw 'Manifest generation started despite a submission policy hold.' }
    function Test-GeneratedInstallerArchitecture { throw 'Manifest generation started despite a submission policy hold.' }

    $result = Update-WingetPackage `
        -WingetPackage 'Test.Package' `
        -With 'WinMatsch' `
        -latestVersion '1.0.0' `
        -latestVersionURL 'https://example.invalid/app.zip|x64' `
        -GHMinReleaseAgeHours '48'

    [PSCustomObject]@{
        Result = $result
        Calls  = $script:PolicyHoldCalls
    }
}
if ($policyHoldResult.Result.Generated -or $policyHoldResult.Result.Reason -cne 'ReleaseTooFresh') {
    throw "The submission policy hold did not stop generation: $($policyHoldResult.Result | ConvertTo-Json -Compress)"
}
if (@($policyHoldResult.Calls).Count -ne 1 -or
    $policyHoldResult.Calls[0].PackageId -cne 'Test.Package' -or
    $policyHoldResult.Calls[0].Version -cne '1.0.0' -or
    $policyHoldResult.Calls[0].MinReleaseAgeHours -cne '48' -or
    (@($policyHoldResult.Calls[0].InstallerUrls) -join ',') -cne 'https://example.invalid/app.zip') {
    throw "The submission policy hold received unexpected arguments: $($policyHoldResult.Calls | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: submission policies are not consulted when an open PR already exists'
$policySkippedResult = & $module {
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
    function Test-ExistingPRs { $true }
    function Get-WingetPreSubmissionHold { throw 'Policy checks ran although a duplicate PR already exists.' }

    Update-WingetPackage `
        -WingetPackage 'Test.Package' `
        -With 'WinMatsch' `
        -latestVersion '1.0.0' `
        -latestVersionURL 'https://example.invalid/app.zip'
}
if ($policySkippedResult.Reason -cne 'PRExists') {
    throw "Expected PRExists without policy checks, got: $($policySkippedResult | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: numeric stream identifiers reject a foreign-stream release at generation time'
$streamGuardError = $null
try {
    & $module {
        function Test-GitHubToken { 'test-token' }
        function Get-LatestGHVersionTag { 'v43.4.0' }
        function Get-LatestARPVersion { '43.4.0' }
        function Test-PackageAndVersionInGithub { throw 'Version lookup ran although the stream guard should have thrown first.' }

        Update-WingetPackage `
            -WingetPackage 'OpenJS.Electron.41' `
            -With 'WinMatsch' `
            -GHRepo 'electron/electron' `
            -GHURLs 'https://github.com/electron/electron/releases/download/v{VERSION}/electron-v{VERSION}-win32-x64.zip' `
            -GHTagPattern '^v4' `
            -IsTemplateUpdate $true | Out-Null
    }
}
catch {
    $streamGuardError = $_
}
if ($null -eq $streamGuardError -or "$streamGuardError" -notmatch 'belongs to the 43 stream') {
    throw "The numeric stream guard did not reject the foreign-stream release: $streamGuardError"
}

Write-Host 'TEST: selected repository scopes version and existing-PR checks'
$selectedRepositoryResult = & $module {
    $script:VersionCheckRepository = $null
    $script:ExistingPrRepository = $null

    function Test-GitHubToken { 'test-token' }
    function Test-PackageAndVersionInGithub {
        param($latestVersion, $wingetPackage, $Repository)

        $script:VersionCheckRepository = $Repository
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
        param($PackageIdentifier, $Version, $Repository)

        $script:ExistingPrRepository = $Repository
        return $true
    }
    function Install-WinMatsch {
        throw 'Manifest generation started despite the selected target having an existing PR.'
    }

    $result = Update-WingetPackage `
        -WingetPackage 'Test.Package' `
        -With 'WinMatsch' `
        -latestVersion '1.0.0' `
        -latestVersionURL 'https://example.invalid/app.zip' `
        -Repository 'damn-good-b0t/winget-pkgs'

    [PSCustomObject]@{
        Result                 = $result
        VersionCheckRepository = $script:VersionCheckRepository
        ExistingPrRepository   = $script:ExistingPrRepository
    }
}
if ($selectedRepositoryResult.VersionCheckRepository -cne 'damn-good-b0t/winget-pkgs' -or
    $selectedRepositoryResult.ExistingPrRepository -cne 'damn-good-b0t/winget-pkgs') {
    throw "Generation did not scope its duplicate checks to the selected repository: $($selectedRepositoryResult | ConvertTo-Json -Compress)"
}
if ($selectedRepositoryResult.Result.Generated -or $selectedRepositoryResult.Result.Reason -cne 'PRExists') {
    throw "The selected-repository existing-PR guard did not stop generation: $($selectedRepositoryResult.Result | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: version lookup queries the selected repository'
$publishedVersionLookupResult = & $module {
    $script:PublishedVersionRepository = $null

    function Get-WingetPublishedVersionsFromGitHub {
        param($PackageIdentifier, $Repository)

        $script:PublishedVersionRepository = $Repository
        [PSCustomObject]@{
            PackageExists = $true
            Versions      = @('0.69.0')
        }
    }

    $result = Test-PackageAndVersionInGithub `
        -wingetPackage 'Wilfred.difftastic' `
        -latestVersion '0.70.0' `
        -Repository 'damn-good-b0t/winget-pkgs'

    [PSCustomObject]@{
        Result       = $result
        Repository   = $script:PublishedVersionRepository
    }
}
if ($publishedVersionLookupResult.Repository -cne 'damn-good-b0t/winget-pkgs') {
    throw "The version lookup did not query the selected repository: $($publishedVersionLookupResult | ConvertTo-Json -Compress)"
}
if (-not $publishedVersionLookupResult.Result.ShouldGenerate) {
    throw "The version lookup incorrectly suppressed a version missing from the selected repository: $($publishedVersionLookupResult.Result | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: WinMatsch exit code 4 (safety question) soft-fails with QuestionsRequired'
$questionsRequiredResult = & $module {
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
    function Test-ExistingPRs { $false }
    function Install-WinMatsch {}
    function Test-GeneratedInstallerArchitecture { throw 'Architecture validation must not run after a safety question.' }
    function winmatsch {
        if ($args -contains '--help') {
            $global:LASTEXITCODE = 0
            return
        }
        Write-Output 'ARCH_CONFLICT : Select an architecture for this asset.'
        $global:LASTEXITCODE = 4
    }

    $originalGitHubOutput = $env:GITHUB_OUTPUT
    $outputFile = Join-Path ([IO.Path]::GetTempPath()) "winget-questions-required-$([guid]::NewGuid().ToString('N')).txt"
    $env:GITHUB_OUTPUT = $outputFile
    try {
        $result = Update-WingetPackage `
            -WingetPackage 'Test.Package' `
            -With 'WinMatsch' `
            -latestVersion '1.0.0' `
            -latestVersionURL 'https://example.invalid/app.zip'
        $exitCodeAfterUpdate = $LASTEXITCODE

        [PSCustomObject]@{
            Result              = $result
            ExitCodeAfterUpdate = $exitCodeAfterUpdate
            OutputContent       = (Get-Content -LiteralPath $outputFile -Raw)
        }
    }
    finally {
        $env:GITHUB_OUTPUT = $originalGitHubOutput
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }
}
if ($questionsRequiredResult.Result.Generated -or $questionsRequiredResult.Result.Reason -cne 'QuestionsRequired') {
    throw "A WinMatsch safety question did not soft-fail with QuestionsRequired: $($questionsRequiredResult.Result | ConvertTo-Json -Compress)"
}
if ($questionsRequiredResult.OutputContent -notmatch '(?m)^reason=QuestionsRequired\s*$') {
    throw "The QuestionsRequired reason was not written to GITHUB_OUTPUT: $($questionsRequiredResult.OutputContent)"
}
if ($questionsRequiredResult.ExitCodeAfterUpdate -ne 0) {
    throw "QuestionsRequired left LASTEXITCODE=$($questionsRequiredResult.ExitCodeAfterUpdate); the GitHub runner pwsh epilogue (exit `$LASTEXITCODE) would fail the step."
}

Write-Host 'TEST: non-question WinMatsch failures still throw as GeneratorFailed'
$generatorFailedResult = & $module {
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
    function Test-ExistingPRs { $false }
    function Install-WinMatsch {}
    function winmatsch {
        if ($args -contains '--help') {
            $global:LASTEXITCODE = 0
            return
        }
        Write-Output 'OPERATION_FAILED : Something genuinely broke.'
        $global:LASTEXITCODE = 5
    }

    $originalGitHubOutput = $env:GITHUB_OUTPUT
    $outputFile = Join-Path ([IO.Path]::GetTempPath()) "winget-generator-failed-$([guid]::NewGuid().ToString('N')).txt"
    $env:GITHUB_OUTPUT = $outputFile
    try {
        $threw = $false
        $message = $null
        try {
            Update-WingetPackage `
                -WingetPackage 'Test.Package' `
                -With 'WinMatsch' `
                -latestVersion '1.0.0' `
                -latestVersionURL 'https://example.invalid/app.zip' | Out-Null
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        [PSCustomObject]@{
            Threw         = $threw
            Message       = $message
            OutputContent = (Get-Content -LiteralPath $outputFile -Raw)
        }
    }
    finally {
        $env:GITHUB_OUTPUT = $originalGitHubOutput
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }
}
if (-not $generatorFailedResult.Threw -or $generatorFailedResult.Message -notmatch 'exit code 5') {
    throw "A real generator failure no longer fails the job: $($generatorFailedResult | ConvertTo-Json -Compress)"
}
if ($generatorFailedResult.OutputContent -notmatch '(?m)^reason=GeneratorFailed\s*$') {
    throw "The GeneratorFailed reason was not written to GITHUB_OUTPUT: $($generatorFailedResult.OutputContent)"
}
if ($generatorFailedResult.OutputContent -match '(?m)^reason=UnhandledError\s*$') {
    throw "The trap overwrote the GeneratorFailed payload: $($generatorFailedResult.OutputContent)"
}

Write-Host 'TEST: architecture-validation failures write the failure payload before throwing'
$archValidationResult = & $module {
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
    function Test-ExistingPRs { $false }
    function Install-WinMatsch {}
    function winmatsch {
        $global:LASTEXITCODE = 0
    }
    function Test-GeneratedInstallerArchitecture {
        throw "Installer architecture validation failed for Test.Package 1.0.0:`n - Generated architecture mismatch for https://example.invalid/app.zip: expected x86, got [x64]"
    }

    $originalGitHubOutput = $env:GITHUB_OUTPUT
    $outputFile = Join-Path ([IO.Path]::GetTempPath()) "winget-arch-failure-$([guid]::NewGuid().ToString('N')).txt"
    $env:GITHUB_OUTPUT = $outputFile
    try {
        $threw = $false
        $message = $null
        try {
            Update-WingetPackage `
                -WingetPackage 'Test.Package' `
                -With 'WinMatsch' `
                -latestVersion '1.0.0' `
                -latestVersionURL 'https://example.invalid/app.zip' | Out-Null
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        [PSCustomObject]@{
            Threw         = $threw
            Message       = $message
            OutputContent = (Get-Content -LiteralPath $outputFile -Raw)
        }
    }
    finally {
        $env:GITHUB_OUTPUT = $originalGitHubOutput
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }
}
if (-not $archValidationResult.Threw -or $archValidationResult.Message -notmatch 'architecture validation failed') {
    throw "The architecture-validation failure no longer propagates: $($archValidationResult | ConvertTo-Json -Compress)"
}
if ($archValidationResult.OutputContent -notmatch '(?m)^reason=UnhandledError\s*$') {
    throw "The architecture-validation failure did not write the failure payload: $($archValidationResult.OutputContent)"
}
if ($archValidationResult.OutputContent -notmatch '(?m)^package-id=Test\.Package\s*$') {
    throw "The failure payload is missing the package id: $($archValidationResult.OutputContent)"
}
if ($archValidationResult.OutputContent -notmatch '(?m)^version=1\.0\.0\s*$') {
    throw "The failure payload is missing the version: $($archValidationResult.OutputContent)"
}
if ($archValidationResult.OutputContent -notmatch '(?m)^error=.*architecture validation failed.*Generated architecture mismatch.*$') {
    throw "The failure payload did not flatten the error message onto one line: $($archValidationResult.OutputContent)"
}

Write-Host 'TEST: early validation failures write the failure payload before throwing'
$earlyValidationResult = & $module {
    $originalGitHubOutput = $env:GITHUB_OUTPUT
    $outputFile = Join-Path ([IO.Path]::GetTempPath()) "winget-early-failure-$([guid]::NewGuid().ToString('N')).txt"
    $env:GITHUB_OUTPUT = $outputFile
    try {
        $threw = $false
        $message = $null
        try {
            Update-WingetPackage -WingetPackage 'Test.Package' -With 'WinMatsch' | Out-Null
        }
        catch {
            $threw = $true
            $message = $_.Exception.Message
        }
        [PSCustomObject]@{
            Threw         = $threw
            Message       = $message
            OutputContent = (Get-Content -LiteralPath $outputFile -Raw)
        }
    }
    finally {
        $env:GITHUB_OUTPUT = $originalGitHubOutput
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }
}
if (-not $earlyValidationResult.Threw -or $earlyValidationResult.Message -notmatch 'WebsiteURL') {
    throw "The early validation failure no longer propagates: $($earlyValidationResult | ConvertTo-Json -Compress)"
}
if ($earlyValidationResult.OutputContent -notmatch '(?m)^reason=UnhandledError\s*$') {
    throw "The early validation failure did not write the failure payload: $($earlyValidationResult.OutputContent)"
}
if ($earlyValidationResult.OutputContent -notmatch '(?m)^package-id=Test\.Package\s*$') {
    throw "The early failure payload is missing the package id: $($earlyValidationResult.OutputContent)"
}

Write-Host 'All Update-WingetPackage regression tests passed.' -ForegroundColor Green
