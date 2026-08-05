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

try {
    Write-Host 'TEST: authenticated GitHub response is fetched once and reused for the UTC day'
    $requests = [System.Collections.Generic.List[int]]::new()
    $authenticatedRequests = [System.Collections.Generic.List[bool]]::new()
    $requestInvoker = {
        param([hashtable]$Parameters)

        $requests.Add(1)
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

    Write-Host 'All GitHub API cache and retry tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $cacheDirectory) {
        Remove-Item -LiteralPath $cacheDirectory -Recurse -Force
    }
}
