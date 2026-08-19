$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot '../scripts/validation/GitHubApiCache.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Actual,

        [Parameter(Mandatory = $true)]
        [object] $Expected,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

$fixedNow = [DateTimeOffset]::Parse('2026-08-05T12:00:00Z')
$utcNowProvider = { $fixedNow }
$responseContent = '[{"tag_name":"v1.0.0","prerelease":false,"published_at":"2026-08-01T00:00:00Z","assets":[]}]'
$cacheDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "winget-api-cache-tests-$([Guid]::NewGuid().ToString('N'))"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

try {
    Write-Host 'TEST: winget version lookup uses the shared rate-limit retry helper'
    $versionLookup = & $module {
        $script:CapturedMaxAttempts = $null
        $script:CapturedMaxWaitSeconds = $null

        function Invoke-GitHubApiRequest {
            param($Uri, $Token, $MaxAttempts, $MaxTotalWaitSeconds)

            $script:CapturedMaxAttempts = $MaxAttempts
            $script:CapturedMaxWaitSeconds = $MaxTotalWaitSeconds
            return [PSCustomObject]@{
                type = 'dir'
                name = '2.12.0'
            }
        }

        $result = Get-WingetPublishedVersionsFromGitHub -PackageIdentifier 'Romanitho.Winget-AutoUpdate'
        [PSCustomObject]@{
            Result         = $result
            MaxAttempts    = $script:CapturedMaxAttempts
            MaxWaitSeconds = $script:CapturedMaxWaitSeconds
        }
    }

    Assert-Equal -Actual $versionLookup.MaxAttempts -Expected 6 -Message 'The winget version lookup did not use the extended retry count.'
    Assert-Equal -Actual $versionLookup.MaxWaitSeconds -Expected 300 -Message 'The winget version lookup did not use the extended wait budget.'
    Assert-Equal -Actual $versionLookup.Result.Versions[0] -Expected '2.12.0' -Message 'The winget version lookup did not return the API response.'

    Write-Host 'TEST: authenticated GitHub response is fetched once and reused for the UTC day'
    $requests = [System.Collections.Generic.List[int]]::new()
    $authenticatedRequests = [System.Collections.Generic.List[bool]]::new()
    $requestTimeouts = [System.Collections.Generic.List[int]]::new()
    $requestInvoker = {
        param([hashtable]$Parameters)

        $requests.Add(1)
        $requestTimeouts.Add($Parameters.TimeoutSec)
        $authorizationHeader = $Parameters.Headers[('Author' + 'ization')]
        $expectedHeader = 'Bearer' + [char]32 + 'test-token'
        $authenticatedRequests.Add($authorizationHeader -ceq $expectedHeader)
        return [PSCustomObject]@{
            Headers = @{ 'X-RateLimit-Remaining' = '4999' }
            Content = $responseContent
        }
    }

    $first = @(Get-CachedGitHubApiResponse `
            -Uri 'https://api.github.test/repos/microsoft/winget-cli/releases' `
            -Token 'test-token' `
            -CacheDirectory $cacheDirectory `
            -CacheName 'releases' `
            -RequestInvoker $requestInvoker `
            -UtcNowProvider $utcNowProvider)
    $second = @(Get-CachedGitHubApiResponse `
            -Uri 'https://api.github.test/repos/microsoft/winget-cli/releases' `
            -Token 'test-token' `
            -CacheDirectory $cacheDirectory `
            -CacheName 'releases' `
            -RequestInvoker $requestInvoker `
            -UtcNowProvider $utcNowProvider)

    Assert-Equal -Actual $requests.Count -Expected 1 -Message 'The API request count was incorrect.'
    Assert-Equal -Actual $authenticatedRequests[0] -Expected $true -Message 'The API request was not authenticated.'
    Assert-Equal -Actual $requestTimeouts[0] -Expected 30 -Message 'The API request timeout was incorrect.'
    Assert-Equal -Actual $first[0].tag_name -Expected 'v1.0.0' -Message 'The fetched release was incorrect.'
    Assert-Equal -Actual $second[0].tag_name -Expected 'v1.0.0' -Message 'The cached release was incorrect.'

    Write-Host 'TEST: rate-limited request retries with exponential backoff'
    $retryRequests = [System.Collections.Generic.List[int]]::new()
    $sleepDurations = [System.Collections.Generic.List[int]]::new()
    $retryInvoker = {
        param([hashtable]$Parameters)

        $retryRequests.Add(1)
        if ($retryRequests.Count -eq 1) {
            $exception = [System.Exception]::new('API rate limit exceeded')
            $exception.Data['StatusCode'] = 403
            $exception.Data['Headers'] = @{
                'X-RateLimit-Remaining' = '0'
                'X-RateLimit-Reset'     = $fixedNow.AddSeconds(1).ToUnixTimeSeconds().ToString()
            }
            throw $exception
        }

        return [PSCustomObject]@{
            Headers = @{ 'X-RateLimit-Remaining' = '4998' }
            Content = $responseContent
        }
    }
    $sleep = { param([int]$Seconds) $sleepDurations.Add($Seconds) }

    $retryResult = @(Invoke-GitHubApiRequest `
            -Uri 'https://api.github.test/rate-limited' `
            -Token 'test-token' `
            -RequestInvoker $retryInvoker `
            -Sleep $sleep `
            -UtcNowProvider $utcNowProvider)

    Assert-Equal -Actual $retryRequests.Count -Expected 2 -Message 'The rate-limited request was not retried.'
    Assert-Equal -Actual $sleepDurations[0] -Expected 5 -Message 'The first backoff delay was incorrect.'
    Assert-Equal -Actual $retryResult[0].tag_name -Expected 'v1.0.0' -Message 'The retry result was incorrect.'

    Write-Host 'TEST: HTTP 429 retries after GitHub retry-after delay'
    $tooManyRequests = [System.Collections.Generic.List[int]]::new()
    $retryAfterSleepDurations = [System.Collections.Generic.List[int]]::new()
    $tooManyRequestsInvoker = {
        param([hashtable]$Parameters)

        $tooManyRequests.Add(1)
        if ($tooManyRequests.Count -eq 1) {
            $exception = [System.Exception]::new('Too many requests')
            $exception.Data['StatusCode'] = 429
            $exception.Data['Headers'] = @{ 'Retry-After' = '7' }
            throw $exception
        }

        return [PSCustomObject]@{
            Headers = @{ 'X-RateLimit-Remaining' = '4998' }
            Content = $responseContent
        }
    }
    $retryAfterSleep = { param([int]$Seconds) $retryAfterSleepDurations.Add($Seconds) }

    $tooManyRequestsResult = @(Invoke-GitHubApiRequest `
            -Uri 'https://api.github.test/too-many-requests' `
            -Token 'test-token' `
            -RequestInvoker $tooManyRequestsInvoker `
            -Sleep $retryAfterSleep `
            -UtcNowProvider $utcNowProvider)

    Assert-Equal -Actual $tooManyRequests.Count -Expected 2 -Message 'The HTTP 429 request was not retried.'
    Assert-Equal -Actual $retryAfterSleepDurations[0] -Expected 7 -Message 'The retry-after delay was not honored.'
    Assert-Equal -Actual $tooManyRequestsResult[0].tag_name -Expected 'v1.0.0' -Message 'The HTTP 429 retry result was incorrect.'

    Write-Host 'TEST: transient server errors retry when opted in'
    $transientAttempts = [System.Collections.Generic.List[int]]::new()
    $transientSleeps = [System.Collections.Generic.List[int]]::new()
    $transientResult = Invoke-WithGitHubRateLimitRetry `
        -ScriptBlock {
            $transientAttempts.Add(1)
            if ($transientAttempts.Count -eq 1) {
                $exception = [System.Exception]::new('Bad gateway')
                $exception.Data['StatusCode'] = 502
                throw $exception
            }
            return 'recovered'
        } `
        -OperationName 'transient test' `
        -RetryTransientServerErrors `
        -Sleep { param([int]$Seconds) $transientSleeps.Add($Seconds) } `
        -UtcNowProvider $utcNowProvider `
        -WarningAction SilentlyContinue

    Assert-Equal -Actual $transientAttempts.Count -Expected 2 -Message 'The HTTP 502 request was not retried.'
    Assert-Equal -Actual $transientSleeps[0] -Expected 5 -Message 'The transient retry backoff delay was incorrect.'
    Assert-Equal -Actual $transientResult -Expected 'recovered' -Message 'The transient retry result was incorrect.'

    Write-Host 'TEST: transient server errors are not retried without opt-in'
    $nonOptInAttempts = [System.Collections.Generic.List[int]]::new()
    $nonOptInMessage = $null
    try {
        Invoke-WithGitHubRateLimitRetry `
            -ScriptBlock {
                $nonOptInAttempts.Add(1)
                $exception = [System.Exception]::new('Bad gateway')
                $exception.Data['StatusCode'] = 502
                throw $exception
            } `
            -Sleep { param([int]$Seconds) } `
            -UtcNowProvider $utcNowProvider
    }
    catch {
        $nonOptInMessage = $_.Exception.Message
    }

    Assert-Equal -Actual $nonOptInAttempts.Count -Expected 1 -Message 'The HTTP 502 request was retried without opt-in.'
    Assert-Equal -Actual $nonOptInMessage -Expected 'Bad gateway' -Message 'The non-opt-in failure was not rethrown as-is.'

    Write-Host 'TEST: exhausted transient server errors rethrow the original failure'
    $exhaustedAttempts = [System.Collections.Generic.List[int]]::new()
    $exhaustedStatusCode = $null
    try {
        Invoke-WithGitHubRateLimitRetry `
            -ScriptBlock {
                $exhaustedAttempts.Add(1)
                $exception = [System.Exception]::new('Service unavailable')
                $exception.Data['StatusCode'] = 503
                throw $exception
            } `
            -RetryTransientServerErrors `
            -MaxAttempts 2 `
            -Sleep { param([int]$Seconds) } `
            -UtcNowProvider $utcNowProvider `
            -WarningAction SilentlyContinue
    }
    catch {
        $exhaustedStatusCode = $_.Exception.Data['StatusCode']
    }

    Assert-Equal -Actual $exhaustedAttempts.Count -Expected 2 -Message 'The exhausted transient request attempt count was incorrect.'
    Assert-Equal -Actual $exhaustedStatusCode -Expected 503 -Message 'The exhausted transient failure did not keep its original status code.'

    Write-Host 'TEST: distant rate-limit reset fails with actionable guidance'
    $distantResetInvoker = {
        param([hashtable]$Parameters)

        $exception = [System.Exception]::new('API rate limit exceeded')
        $exception.Data['StatusCode'] = 403
        $exception.Data['Headers'] = @{
            'X-RateLimit-Remaining' = '0'
            'X-RateLimit-Reset'     = $fixedNow.AddMinutes(10).ToUnixTimeSeconds().ToString()
        }
        throw $exception
    }

    $failureMessage = $null
    try {
        Invoke-GitHubApiRequest `
            -Uri 'https://api.github.test/reset-too-far' `
            -Token 'test-token' `
            -RequestInvoker $distantResetInvoker `
            -Sleep $sleep `
            -UtcNowProvider $utcNowProvider `
            -MaxTotalWaitSeconds 120
    }
    catch {
        $failureMessage = $_.Exception.Message
    }

    if ($failureMessage -notmatch 'Retry the workflow after the reset or provide a token with available quota') {
        throw "The distant-reset error was not actionable. Actual message: $failureMessage"
    }

    Write-Host 'TEST: waiter outlasts a slow lock holder and reads its cache'
    $slowCacheName = 'slow-holder'
    $slowCachePath = Join-Path $cacheDirectory "$slowCacheName-$($fixedNow.ToString('yyyy-MM-dd')).json"
    $slowLockPath = "$slowCachePath.lock"
    $slowHolder = Start-Job -ArgumentList $slowLockPath, $slowCachePath, $responseContent -ScriptBlock {
        param($LockPath, $CachePath, $Content)

        $stream = [System.IO.File]::Open(
            $LockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        try {
            Start-Sleep -Milliseconds 1200
            Set-Content -LiteralPath $CachePath -Value $Content -Encoding utf8
        }
        finally {
            $stream.Dispose()
        }
    }

    $holderStartDeadline = [DateTimeOffset]::UtcNow.AddSeconds(5)
    while (!(Test-Path -LiteralPath $slowLockPath) -and [DateTimeOffset]::UtcNow -lt $holderStartDeadline) {
        Start-Sleep -Milliseconds 25
    }
    if (!(Test-Path -LiteralPath $slowLockPath)) {
        throw 'The slow lock holder did not start in time.'
    }

    $unexpectedRequests = [System.Collections.Generic.List[int]]::new()
    try {
        $slowResult = @(Get-CachedGitHubApiResponse `
                -Uri 'https://api.github.test/slow-holder' `
                -Token 'test-token' `
                -CacheDirectory $cacheDirectory `
                -CacheName $slowCacheName `
                -MaxAttempts 1 `
                -MaxTotalWaitSeconds 1 `
                -RequestTimeoutSeconds 1 `
                -LockWaitMarginSeconds 1 `
                -LockPollMilliseconds 50 `
                -RequestInvoker { param($Parameters) $unexpectedRequests.Add(1); throw 'Unexpected request' } `
                -UtcNowProvider $utcNowProvider)
    }
    finally {
        Wait-Job -Job $slowHolder -Timeout 5 | Out-Null
        Receive-Job -Job $slowHolder -ErrorAction Stop | Out-Null
        Remove-Job -Job $slowHolder -Force
    }

    Assert-Equal -Actual $unexpectedRequests.Count -Expected 0 -Message 'The waiter bypassed the slow holder.'
    Assert-Equal -Actual $slowResult[0].tag_name -Expected 'v1.0.0' -Message 'The slow-holder cache result was incorrect.'

    Write-Host 'TEST: lock timeout degrades to a direct uncached request'
    $fallbackCacheName = 'lock-timeout'
    $fallbackCachePath = Join-Path $cacheDirectory "$fallbackCacheName-$($fixedNow.ToString('yyyy-MM-dd')).json"
    $fallbackLockPath = "$fallbackCachePath.lock"
    $heldLock = [System.IO.File]::Open(
        $fallbackLockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $fallbackRequests = [System.Collections.Generic.List[int]]::new()
    try {
        $fallbackResult = @(Get-CachedGitHubApiResponse `
                -Uri 'https://api.github.test/lock-timeout' `
                -Token 'test-token' `
                -CacheDirectory $cacheDirectory `
                -CacheName $fallbackCacheName `
                -MaxAttempts 1 `
                -MaxTotalWaitSeconds 1 `
                -RequestTimeoutSeconds 1 `
                -LockWaitMarginSeconds 0 `
                -LockPollMilliseconds 50 `
                -RequestInvoker {
                    param($Parameters)
                    $fallbackRequests.Add(1)
                    [PSCustomObject]@{
                        Headers = @{ 'X-RateLimit-Remaining' = '4997' }
                        Content = $responseContent
                    }
                } `
                -UtcNowProvider $utcNowProvider)
    }
    finally {
        $heldLock.Dispose()
    }

    Assert-Equal -Actual $fallbackRequests.Count -Expected 1 -Message 'The lock timeout did not make a direct request.'
    Assert-Equal -Actual $fallbackResult[0].tag_name -Expected 'v1.0.0' -Message 'The uncached fallback result was incorrect.'
    Assert-Equal -Actual (Test-Path -LiteralPath $fallbackCachePath) -Expected $false -Message 'The uncached fallback wrote the cache.'

    Write-Host 'All GitHub API cache and retry tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $cacheDirectory) {
        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force
    }
}
