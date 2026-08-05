<#
.SYNOPSIS
    Helpers for WinMatsch's machine-readable --result-json output.

.DESCRIPTION
    Newer WinMatsch builds can write a structured JSON result describing the outcome of a
    run (pull request URL/number on submit, error code/message on failure). Consuming that
    is far more reliable than scraping console text, but older builds reject the unknown
    flag and fail the whole run, so support is probed once per process before the flag is
    added. Every reader here degrades to $null so callers can fall back to text scraping.
#>

function Test-WinMatschSupportsResultJson {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # WinMatsch subcommand whose help is inspected first (e.g. 'submit', 'update').
        [Parameter(Mandatory = $false)]
        [string] $Command
    )

    if ($null -eq $script:WinMatschResultJsonSupport) {
        $script:WinMatschResultJsonSupport = @{}
    }

    $cacheKey = if ([string]::IsNullOrWhiteSpace($Command)) { '<global>' } else { $Command }
    if ($script:WinMatschResultJsonSupport.ContainsKey($cacheKey)) {
        return $script:WinMatschResultJsonSupport[$cacheKey]
    }

    # A probe must never disturb the exit code the caller is about to inspect.
    $previousExitCode = $global:LASTEXITCODE
    $supported = $false

    try {
        $helpArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($Command)) { $helpArgs += $Command }
        $helpArgs += '--help'

        $helpText = (& winmatsch @helpArgs 2>&1 | Out-String)
        $supported = $helpText -match '--result-json'

        if (-not $supported -and -not [string]::IsNullOrWhiteSpace($Command)) {
            # Fall back to global help in case the flag is documented only there.
            $globalHelp = (& winmatsch '--help' 2>&1 | Out-String)
            $supported = $globalHelp -match '--result-json'
        }
    }
    catch {
        Write-Verbose "Could not probe WinMatsch for --result-json support: $($_.Exception.Message)"
        $supported = $false
    }
    finally {
        $global:LASTEXITCODE = $previousExitCode
    }

    Write-Verbose "WinMatsch --result-json supported for '$cacheKey': $supported"
    $script:WinMatschResultJsonSupport[$cacheKey] = $supported
    return $supported
}

function Read-WinMatschResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Could not read WinMatsch result JSON '$Path': $($_.Exception.Message)"
        return $null
    }
}

function New-WinMatschResultJsonPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label
    )

    return Join-Path ([System.IO.Path]::GetTempPath()) "winmatsch-$Label-$([guid]::NewGuid().ToString('N')).json"
}

function Get-WinMatschResultError {
    <#
    .SYNOPSIS
        Formats the error block of a WinMatsch result as "CODE : message".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result -or $null -eq $Result.error) {
        return $null
    }

    $code = "$($Result.error.code)".Trim()
    $message = "$($Result.error.message)".Trim()

    if ($code -and $message) { return "$code : $message" }
    if ($message) { return $message }
    if ($code) { return $code }
    return $null
}
