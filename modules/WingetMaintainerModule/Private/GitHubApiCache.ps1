# Shared GitHub API retry and per-run cache helpers.
function Get-GitHubHeaderValue {
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Headers,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $Headers) {
        return $null
    }

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string]$key -ieq $Name) {
                return [string]($Headers[$key] -join ',')
            }
        }
        return $null
    }

    foreach ($header in $Headers) {
        $key = $header.PSObject.Properties['Key']
        $value = $header.PSObject.Properties['Value']
        if ($null -ne $key -and $null -ne $value -and $key.Value -ieq $Name) {
            return [string]($value.Value -join ',')
        }
    }

    return $null
}

function Get-GitHubApiErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $statusCode = $ErrorRecord.Exception.Data['StatusCode']
    $headers = $ErrorRecord.Exception.Data['Headers']
    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
        $response = $responseProperty.Value
        $statusCode = $response.StatusCode
        $headers = $response.Headers
    }

    $message = if ($null -ne $ErrorRecord.ErrorDetails -and ![string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        $ErrorRecord.ErrorDetails.Message
    } else {
        $ErrorRecord.Exception.Message
    }

    return [PSCustomObject]@{
        StatusCode = if ($null -eq $statusCode) { $null } else { [int]$statusCode }
        Headers    = $headers
        Message    = $message
    }
}

function Get-GitHubRateLimitDelay {
    param(
        [Parameter()]
        [AllowNull()]
        [object] $Headers,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset] $UtcNow
    )

    $retryAfter = Get-GitHubHeaderValue -Headers $Headers -Name 'Retry-After'
    $retryAfterSeconds = 0
    if ([int]::TryParse($retryAfter, [ref]$retryAfterSeconds)) {
        return [Math]::Max(0, $retryAfterSeconds)
    }

    $retryAfterDate = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($retryAfter, [ref]$retryAfterDate)) {
        return [Math]::Max(0, [Math]::Ceiling(($retryAfterDate - $UtcNow).TotalSeconds))
    }

    $resetHeader = Get-GitHubHeaderValue -Headers $Headers -Name 'X-RateLimit-Reset'
    $resetEpoch = 0L
    if ([long]::TryParse($resetHeader, [ref]$resetEpoch)) {
        $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch)
        return [Math]::Max(0, [Math]::Ceiling(($resetAt - $UtcNow).TotalSeconds) + 1)
    }

    return 0
}

function Test-GitHubRateLimitErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Details
    )

    $remaining = Get-GitHubHeaderValue -Headers $Details.Headers -Name 'X-RateLimit-Remaining'
    return $Details.StatusCode -eq 429 -or (
        $Details.StatusCode -eq 403 -and (
            $remaining -eq '0' -or $Details.Message -match '(?i)rate limit'
        )
    )
}

function Invoke-WithGitHubRateLimitRetry {
    <#
    .SYNOPSIS
        Runs an arbitrary scriptblock and retries it when GitHub rate limits the call.

    .DESCRIPTION
        Retries only rate-limit failures (HTTP 429, or 403 with an exhausted quota).
        Wait time honors Retry-After / X-RateLimit-Reset headers when present and
        falls back to exponential backoff. On exhaustion it throws an exception with
        Data['StatusCode'] = 429 so callers (e.g. credential-tier failover) can still
        detect the rate limit.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [Parameter()]
        [string] $OperationName = 'GitHub API request',

        [Parameter()]
        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 600)]
        [int] $MaxTotalWaitSeconds = 120,

        [Parameter()]
        [scriptblock] $Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds },

        [Parameter()]
        [scriptblock] $UtcNowProvider = { [DateTimeOffset]::UtcNow }
    )

    $totalWaitSeconds = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $details = Get-GitHubApiErrorDetails -ErrorRecord $_
            if (!(Test-GitHubRateLimitErrorDetails -Details $details)) {
                throw
            }

            $utcNow = & $UtcNowProvider
            $headerDelay = Get-GitHubRateLimitDelay -Headers $details.Headers -UtcNow $utcNow
            $backoffDelay = [Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1))
            $delaySeconds = [int][Math]::Max($headerDelay, $backoffDelay)
            $remainingWaitBudget = $MaxTotalWaitSeconds - $totalWaitSeconds

            $resetHeader = Get-GitHubHeaderValue -Headers $details.Headers -Name 'X-RateLimit-Reset'
            $resetAt = 'not provided by GitHub'
            $resetEpoch = 0L
            if ([long]::TryParse($resetHeader, [ref]$resetEpoch)) {
                $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($resetEpoch).ToString('u')
            } elseif ($resetHeader) {
                $resetAt = $resetHeader
            }

            if ($attempt -eq $MaxAttempts -or $delaySeconds -gt $remainingWaitBudget) {
                $exhausted = [System.Exception]::new(
                    "GitHub API rate limit exhausted for $OperationName. Reset: $resetAt. Retry the workflow after the reset or provide a token with available quota."
                )
                $exhausted.Data['StatusCode'] = 429
                if ($null -ne $details.Headers) {
                    $exhausted.Data['Headers'] = $details.Headers
                }
                throw $exhausted
            }

            Write-Warning "GitHub API rate limit reached. Retrying in $delaySeconds seconds (attempt $($attempt + 1)/$MaxAttempts; reset: $resetAt)."
            & $Sleep $delaySeconds
            $totalWaitSeconds += $delaySeconds
        }
    }
}

function Invoke-GitHubApiRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Token,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 600)]
        [int] $MaxTotalWaitSeconds = 120,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $RequestTimeoutSeconds = 30,

        [Parameter()]
        [scriptblock] $RequestInvoker,

        [Parameter()]
        [scriptblock] $Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds },

        [Parameter()]
        [scriptblock] $UtcNowProvider = { [DateTimeOffset]::UtcNow }
    )

    if ($null -eq $RequestInvoker) {
        $RequestInvoker = {
            param([hashtable]$Parameters)

            $response = Invoke-WebRequest @Parameters
            return [PSCustomObject]@{
                Headers = $response.Headers
                Content = $response.Content
            }
        }
    }

    $headers = @{
        Accept                   = 'application/vnd.github+json'
        'X-GitHub-Api-Version'   = '2022-11-28'
        'User-Agent'             = 'winget-pkgs-updates'
    }
    if (![string]::IsNullOrWhiteSpace($Token)) {
        $headers[('Author' + 'ization')] = 'Bearer' + [char]32 + $Token
    }

    $requestParameters = @{
        Uri         = $Uri
        Method      = 'Get'
        Headers     = $headers
        ErrorAction = 'Stop'
        TimeoutSec  = $RequestTimeoutSeconds
    }

    # Plain scriptblock: resolves $RequestInvoker/$requestParameters via dynamic
    # scoping and keeps module-private functions callable (a closure would bind
    # to a new dynamic module and lose them).
    $sendRequest = {
        $response = & $RequestInvoker $requestParameters
        $remaining = Get-GitHubHeaderValue -Headers $response.Headers -Name 'X-RateLimit-Remaining'
        if ($null -ne $remaining -and [int]$remaining -le 10) {
            Write-Warning "GitHub API rate limit is low: $remaining requests remaining."
        }

        return $response.Content | ConvertFrom-Json
    }

    return Invoke-WithGitHubRateLimitRetry `
        -ScriptBlock $sendRequest `
        -OperationName $Uri `
        -MaxAttempts $MaxAttempts `
        -MaxTotalWaitSeconds $MaxTotalWaitSeconds `
        -Sleep $Sleep `
        -UtcNowProvider $UtcNowProvider
}

function Get-CachedGitHubApiResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Uri,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Token,

        [Parameter(Mandatory = $true)]
        [string] $CacheDirectory,

        [Parameter(Mandatory = $true)]
        [string] $CacheName,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(1, 600)]
        [int] $MaxTotalWaitSeconds = 120,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $RequestTimeoutSeconds = 30,

        [Parameter()]
        [ValidateRange(0, 60)]
        [int] $LockWaitMarginSeconds = 15,

        [Parameter()]
        [ValidateRange(10, 5000)]
        [int] $LockPollMilliseconds = 1000,

        [Parameter()]
        [scriptblock] $RequestInvoker,

        [Parameter()]
        [scriptblock] $Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds },

        [Parameter()]
        [scriptblock] $UtcNowProvider = { [DateTimeOffset]::UtcNow }
    )

    $utcNow = & $UtcNowProvider
    $cachePath = Join-Path $CacheDirectory "$CacheName-$($utcNow.ToString('yyyy-MM-dd')).json"
    $lockPath = "$cachePath.lock"

    if (!(Test-Path -LiteralPath $CacheDirectory -PathType Container)) {
        New-Item -Path $CacheDirectory -ItemType Directory -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $CacheDirectory -Filter "$CacheName-*.json*" -File |
        Where-Object { $_.LastWriteTimeUtc -lt $utcNow.UtcDateTime.AddDays(-7) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $readCache = {
        if (!(Test-Path -LiteralPath $cachePath -PathType Leaf)) {
            return $null
        }
        try {
            return Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Warning "Ignoring invalid GitHub API cache file '$cachePath': $($_.Exception.Message)"
            Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
            return $null
        }
    }

    $cachedResponse = & $readCache
    if ($null -ne $cachedResponse) {
        Write-Verbose "Using cached GitHub API response from $cachePath"
        return $cachedResponse
    }

    $invokeParameters = @{
        Uri                   = $Uri
        Token                 = $Token
        MaxAttempts           = $MaxAttempts
        MaxTotalWaitSeconds   = $MaxTotalWaitSeconds
        RequestTimeoutSeconds = $RequestTimeoutSeconds
        Sleep                 = $Sleep
        UtcNowProvider        = $UtcNowProvider
    }
    if ($null -ne $RequestInvoker) {
        $invokeParameters.RequestInvoker = $RequestInvoker
    }

    $lockStream = $null
    $lockWaitSeconds = $MaxTotalWaitSeconds + ($RequestTimeoutSeconds * $MaxAttempts) + $LockWaitMarginSeconds
    $lockDeadline = [DateTimeOffset]::UtcNow.AddSeconds($lockWaitSeconds)
    while ($null -eq $lockStream -and [DateTimeOffset]::UtcNow -lt $lockDeadline) {
        try {
            $lockStream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds $LockPollMilliseconds
        }
    }
    if ($null -eq $lockStream) {
        Write-Warning "Timed out waiting $lockWaitSeconds seconds for the GitHub API cache lock '$lockPath'. Continuing with a direct uncached request."
        return @(Invoke-GitHubApiRequest @invokeParameters)
    }

    try {
        $cachedResponse = & $readCache
        if ($null -ne $cachedResponse) {
            Write-Verbose "Using GitHub API response cached by another process at $cachePath"
            return $cachedResponse
        }

        $apiResponse = @(Invoke-GitHubApiRequest @invokeParameters)
        $temporaryPath = "$cachePath.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            ConvertTo-Json -InputObject $apiResponse -Depth 100 |
                Set-Content -LiteralPath $temporaryPath -Encoding utf8
            Move-Item -LiteralPath $temporaryPath -Destination $cachePath -Force
        }
        finally {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }

        return $apiResponse
    }
    finally {
        $lockStream.Dispose()
    }
}
