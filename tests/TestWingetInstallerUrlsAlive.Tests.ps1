$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winget-url-preflight-$([guid]::NewGuid().ToString('N'))")

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    Write-Host 'TEST: alive URLs pass'
    $result = & $module {
        param($Urls)
        Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe { param($Url, $Method) 200 } -Sleep {}
    } @('https://example.invalid/a.exe', 'https://example.invalid/b.exe')
    if (-not $result.Valid -or $result.CheckedCount -ne 2 -or @($result.DeadUrls).Count -ne 0) {
        throw "Expected two alive URLs, got: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: HTTP 404 blocks submission'
    $result = & $module {
        param($Urls)
        Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe { param($Url, $Method) 404 } -Sleep {}
    } @('https://example.invalid/gone.exe')
    if ($result.Valid -or @($result.DeadUrls) -notcontains 'https://example.invalid/gone.exe') {
        throw "Expected a dead 404 URL, got: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: HTTP 410 blocks submission'
    $result = & $module {
        param($Urls)
        Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe { param($Url, $Method) 410 } -Sleep {}
    } @('https://example.invalid/gone.exe')
    if ($result.Valid) {
        throw "Expected HTTP 410 to be treated as dead, got: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: HEAD 405 falls back to a ranged GET'
    $result = & $module {
        param($Urls)
        $script:probeCalls = @()
        $probe = {
            param($Url, $Method)
            $script:probeCalls += $Method
            if ($Method -eq 'Head') { 405 } else { 206 }
        }
        $outcome = Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe $probe -Sleep {}
        [PSCustomObject]@{ Outcome = $outcome; Calls = $script:probeCalls }
    } @('https://example.invalid/no-head.exe')
    if (-not $result.Outcome.Valid -or (@($result.Calls) -join ',') -ne 'Head,Get') {
        throw "Expected Head then Get fallback, got: $($result | ConvertTo-Json -Compress -Depth 4)"
    }

    Write-Host 'TEST: transient failures retry and then fail open with a warning'
    $result = & $module {
        param($Urls)
        $script:attempts = 0
        $probe = { param($Url, $Method) $script:attempts++; throw 'connection reset' }
        $outcome = Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe $probe -MaxAttempts 3 -Sleep {}
        [PSCustomObject]@{ Outcome = $outcome; Attempts = $script:attempts }
    } @('https://example.invalid/flaky.exe')
    if (-not $result.Outcome.Valid -or @($result.Outcome.Warnings).Count -ne 1 -or $result.Attempts -ne 3) {
        throw "Expected fail-open after 3 attempts with one warning, got: $($result | ConvertTo-Json -Compress -Depth 4)"
    }

    Write-Host 'TEST: HTTP 429 recovers on a later attempt'
    $result = & $module {
        param($Urls)
        $script:attempts = 0
        $probe = { param($Url, $Method) $script:attempts++; if ($script:attempts -lt 2) { 429 } else { 200 } }
        Test-WingetInstallerUrlsAlive -InstallerUrls $Urls -HttpProbe $probe -Sleep {}
    } @('https://example.invalid/limited.exe')
    if (-not $result.Valid -or @($result.Warnings).Count -ne 0) {
        throw "Expected recovery after a 429, got: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: manifest mode extracts InstallerUrls from the installer yaml'
    $manifestDir = Join-Path $testRoot 'manifest'
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
Installers:
  - Architecture: x64
    InstallerUrl: https://example.invalid/pkg-x64.exe
    InstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111
  - Architecture: arm64
    InstallerUrl: https://example.invalid/pkg-arm64.exe
    InstallerSha256: 2222222222222222222222222222222222222222222222222222222222222222
ManifestType: installer
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $manifestDir 'Test.Package.installer.yaml')

    $result = & $module {
        param($Path)
        $script:seenUrls = @()
        $probe = { param($Url, $Method) $script:seenUrls += $Url; if ($Url -match 'arm64') { 404 } else { 200 } }
        $outcome = Test-WingetInstallerUrlsAlive -ManifestPath $Path -HttpProbe $probe -Sleep {}
        [PSCustomObject]@{ Outcome = $outcome; Seen = $script:seenUrls }
    } $manifestDir
    if (@($result.Seen).Count -ne 2 -or $result.Outcome.Valid -or @($result.Outcome.DeadUrls) -notcontains 'https://example.invalid/pkg-arm64.exe') {
        throw "Expected both manifest URLs probed and the arm64 one dead, got: $($result | ConvertTo-Json -Compress -Depth 4)"
    }

    Write-Host 'TEST: a manifest folder without an installer yaml is skipped with a warning'
    $emptyDir = Join-Path $testRoot 'empty'
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    $result = & $module {
        param($Path)
        Test-WingetInstallerUrlsAlive -ManifestPath $Path -HttpProbe { param($Url, $Method) throw 'must not be called' } -Sleep {}
    } $emptyDir
    if (-not $result.Valid -or $result.CheckedCount -ne 0 -or @($result.Warnings).Count -ne 1) {
        throw "Expected a skip with warning for a manifest without installer yaml, got: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'All Test-WingetInstallerUrlsAlive tests passed.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
