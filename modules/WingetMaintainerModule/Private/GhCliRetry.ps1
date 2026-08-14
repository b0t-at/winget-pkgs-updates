# Retry wrapper for gh CLI invocations that hit GitHub rate limits.
function Test-GhCliRateLimitOutput {
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    return $Output -match '(?i)HTTP 429|API rate limit exceeded|secondary rate limit|abuse detection|exceeded a secondary rate limit'
}

function Invoke-GhCliWithRetry {
    <#
    .SYNOPSIS
        Runs a gh CLI scriptblock and retries when the output indicates a GitHub rate limit.

    .DESCRIPTION
        Executes the scriptblock capturing stdout and stderr. When the command fails
        ($LASTEXITCODE -ne 0) and its combined output matches known rate-limit
        messages, the call is retried with exponential backoff. All other results
        (success or non-rate-limit failures) are returned/surfaced unchanged so
        callers keep their existing behavior.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock] $ScriptBlock,

        [Parameter()]
        [string] $OperationName = 'gh CLI call',

        [Parameter()]
        [ValidateRange(1, 10)]
        [int] $MaxAttempts = 4,

        [Parameter()]
        [scriptblock] $Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $capturedOutput = @(& $ScriptBlock 2>&1)
        $exitCode = $LASTEXITCODE
        $standardOutput = @($capturedOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $errorText = (@($capturedOutput |
                Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                ForEach-Object { [string]$_ }) -join "`n")
        $combinedText = ($errorText, (@($standardOutput | ForEach-Object { [string]$_ }) -join "`n")) -join "`n"

        $isRateLimited = $exitCode -ne 0 -and (Test-GhCliRateLimitOutput -Output $combinedText)
        if ($isRateLimited -and $attempt -lt $MaxAttempts) {
            $delaySeconds = [int][Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1))
            Write-Warning "$OperationName hit a GitHub rate limit. Retrying in $delaySeconds seconds (attempt $($attempt + 1)/$MaxAttempts)."
            & $Sleep $delaySeconds
            continue
        }

        if (![string]::IsNullOrWhiteSpace($errorText)) {
            # Keep gh's stderr diagnostics visible without turning them into errors.
            Write-Warning "$OperationName reported: $errorText"
        }

        return $standardOutput
    }
}
