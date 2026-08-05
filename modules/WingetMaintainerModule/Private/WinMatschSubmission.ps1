function Invoke-WinMatschSubmitAttempt {
    <#
    .SYNOPSIS
        Submits one freshly validated WinMatsch pull request attempt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $PrTitle,

        [Parameter(Mandatory = $true)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [string] $Resolves
    )

    $winmatschArgs = @(
        'submit'
        $ManifestPath
        '--submit'
        '--yes'
        '--prtitle', $PrTitle
        '--token', $Token
    )

    if (-not [string]::IsNullOrWhiteSpace($Resolves)) {
        $winmatschArgs += '--resolves'
        $winmatschArgs += $Resolves
    }

    # Each attempt receives a new result file so retry decisions are based on
    # that attempt's remote preflight and not on stale structured output.
    $resultJsonPath = $null
    if (Test-WinMatschSupportsResultJson -Command 'submit') {
        $resultJsonPath = New-WinMatschResultJsonPath -Label 'submit'
        $winmatschArgs += '--result-json'
        $winmatschArgs += $resultJsonPath
    }

    $displayArgs = $winmatschArgs | ForEach-Object {
        if ($_ -eq $Token) { '***' } else { $_ }
    }
    Write-Host "--> Running: winmatsch $($displayArgs -join ' ')" -ForegroundColor White

    $output = @(& winmatsch @winmatschArgs 2>&1)
    $exitCode = $LASTEXITCODE
    Write-Host $output

    $result = Read-WinMatschResult -Path $resultJsonPath
    if ($resultJsonPath) {
        Remove-Item -LiteralPath $resultJsonPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        ExitCode  = $exitCode
        Output    = $output
        Result    = $result
        ErrorCode = if ($result -and $result.error) { "$($result.error.code)".Trim() } else { $null }
        Error     = Get-WinMatschResultError -Result $result
    }
}

function Test-WinMatschBranchMovedRetryable {
    <#
    .SYNOPSIS
        Returns true only for WinMatsch's known-safe GH2020 retry condition.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Attempt
    )

    if ($Attempt.ExitCode -eq 0) {
        return $false
    }

    $details = @(
        "$($Attempt.ErrorCode)"
        "$($Attempt.Error)"
        ($Attempt.Output | Out-String)
    ) -join "`n"

    if ($details -notmatch '(?i)\bGH2020\b') {
        return $false
    }

    # A retry is unsafe when WinMatsch cannot determine whether a remote write
    # succeeded. Let the run fail instead of risking a duplicate submission.
    return $details -notmatch '(?i)remote outcome uncertain:\s*true|recovery required:\s*true'
}
