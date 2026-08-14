# Tests for Invoke-GhCliWithRetry (gh CLI rate-limit retry wrapper).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru -WarningAction SilentlyContinue

$script:failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)

    if ("$Expected" -ne "$Actual") {
        $script:failures++
        Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')"
    } else {
        Write-Host "PASS: $Name"
    }
}

# 1) Retries on rate-limit stderr + nonzero exit, then returns stdout.
$result = & $module {
    $script:calls = 0
    $script:sleeps = [System.Collections.Generic.List[int]]::new()
    $out = Invoke-GhCliWithRetry -OperationName 'rate limited op' -MaxAttempts 4 -WarningAction SilentlyContinue -Sleep { param($s) $script:sleeps.Add($s) } -ScriptBlock {
        $script:calls++
        if ($script:calls -lt 3) {
            & cmd /c 'echo HTTP 429: API rate limit exceeded 1>&2 & exit 1'
        } else {
            & cmd /c 'echo {"ok":true}'
        }
    }
    [PSCustomObject]@{
        Calls  = $script:calls
        Output = (@($out) -join '').Trim()
        Sleeps = ($script:sleeps -join ',')
    }
}
Assert-Equal 3 $result.Calls 'rate limit retried until success'
Assert-Equal '{"ok":true}' $result.Output 'stdout returned after retries'
Assert-Equal '5,10' $result.Sleeps 'exponential backoff delays'

# 2) Secondary rate limit message is also retried.
$secondary = & $module {
    $script:calls = 0
    Invoke-GhCliWithRetry -OperationName 'secondary limit op' -MaxAttempts 2 -WarningAction SilentlyContinue -Sleep { param($s) } -ScriptBlock {
        $script:calls++
        & cmd /c 'echo You have exceeded a secondary rate limit. 1>&2 & exit 1'
    } | Out-Null
    $script:calls
}
Assert-Equal 2 $secondary 'secondary rate limit exhausts MaxAttempts'

# 3) Non-rate-limit failures are not retried and stdout is still returned.
$nonRateLimit = & $module {
    $script:calls = 0
    $out = Invoke-GhCliWithRetry -OperationName 'failing op' -MaxAttempts 4 -WarningAction SilentlyContinue -ScriptBlock {
        $script:calls++
        & cmd /c 'echo release not found 1>&2 & exit 1'
    }
    [PSCustomObject]@{ Calls = $script:calls; Count = @($out).Count }
}
Assert-Equal 1 $nonRateLimit.Calls 'non-rate-limit failure not retried'
Assert-Equal 0 $nonRateLimit.Count 'no stdout on failure'

# 4) Clean success makes a single attempt.
$success = & $module {
    $script:calls = 0
    $out = Invoke-GhCliWithRetry -OperationName 'clean op' -MaxAttempts 4 -ScriptBlock {
        $script:calls++
        & cmd /c 'echo hello'
    }
    [PSCustomObject]@{ Calls = $script:calls; Output = (@($out) -join '').Trim() }
}
Assert-Equal 1 $success.Calls 'clean success single attempt'
Assert-Equal 'hello' $success.Output 'stdout passthrough on success'

# 5) Rate-limit text with successful exit code is not retried (exit code gates retry).
$successWithNoise = & $module {
    $script:calls = 0
    Invoke-GhCliWithRetry -OperationName 'noisy success' -MaxAttempts 4 -WarningAction SilentlyContinue -ScriptBlock {
        $script:calls++
        & cmd /c 'echo API rate limit exceeded for installation'
    } | Out-Null
    $script:calls
}
Assert-Equal 1 $successWithNoise 'zero exit code never retried'

if ($script:failures -gt 0) {
    Write-Host "FAILED: $script:failures assertion(s)"
    exit 1
}
Write-Host 'PASSED'
