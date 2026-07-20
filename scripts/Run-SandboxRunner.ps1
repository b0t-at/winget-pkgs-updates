#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the WingetMaintainer SandboxRunner locally for manual testing.

.DESCRIPTION
    Sets every environment variable the SandboxRunner binds (the `Runner` configuration
    section) and launches the runner either from source (`dotnet run`) or from a published
    executable (`-ExePath`).

    The SandboxRunner is the single consumer of the Worker's validation queue: it polls
    `Runner:WorkerBaseUrl`, runs `Test-Manifest-Sandbox.ps1` for one job at a time, and reports
    the outcome. It is Windows-only and requires an INTERACTIVE desktop session — Windows Sandbox
    will not start from Session 0. Start the Worker first (so there is a queue to poll).

.PARAMETER WorkerBaseUrl
    Base URL of the Worker internal API. Must end with '/'. Default: http://localhost:5099/

.PARAMETER ApiKey
    Value sent as the X-Api-Key header. Must match the Worker's Worker:ApiKey. If omitted the
    script reads $env:WINGET_WORKER_API_KEY so the secret never has to be typed on the command line.

.PARAMETER HostLabel
    Host label reported with claimed jobs. Default: the machine name.

.PARAMETER ScriptPath
    Path to Test-Manifest-Sandbox.ps1. Default: resolved relative to the repo root.

.PARAMETER PollIntervalSeconds
    Idle poll interval when the queue is empty. Default: 15.

.PARAMETER TimeoutMinutes
    Per-job hard timeout. Default: 30.

.PARAMETER Environment
    Deployment environment label used in logs (Production/Test/...). Default: Test.

.PARAMETER LokiUri
    Optional Grafana Loki push URL. When omitted the runner logs to the console only.

.PARAMETER LokiUser
    Optional Loki basic-auth username (when a reverse proxy enforces basic auth).

.PARAMETER Configuration
    dotnet build configuration when running from source. Default: Debug.

.PARAMETER ExePath
    Run a published WingetMaintainer.SandboxRunner.exe instead of `dotnet run` from source.

.EXAMPLE
    # Run from source against a locally-running Worker (reads API key from env)
    $env:WINGET_WORKER_API_KEY = 'dev-secret'
    ./scripts/Run-SandboxRunner.ps1

.EXAMPLE
    # Run a downloaded self-contained bundle
    ./scripts/Run-SandboxRunner.ps1 -ExePath 'C:\winget-maintainer\SandboxRunner\WingetMaintainer.SandboxRunner.exe' `
        -WorkerBaseUrl 'http://worker.internal:5099/' -ApiKey 'prod-secret' -Environment Production
#>
[CmdletBinding()]
param(
    [string]$WorkerBaseUrl = 'http://localhost:5099/',
    [string]$ApiKey = $env:WINGET_WORKER_API_KEY,
    [string]$HostLabel = $env:COMPUTERNAME,
    [string]$ScriptPath,
    [int]$PollIntervalSeconds = 15,
    [int]$TimeoutMinutes = 30,
    [ValidateSet('Production', 'Test', 'Development')]
    [string]$Environment = 'Test',
    [string]$LokiUri,
    [string]$LokiUser,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [string]$ExePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Repo root = parent of this script's folder (scripts/..).
$repoRoot = Split-Path -Parent $PSScriptRoot
$projectPath = Join-Path $repoRoot 'src/WingetMaintainer.SandboxRunner'

if (-not $ScriptPath) {
    $ScriptPath = Join-Path $repoRoot 'scripts/validation/Test-Manifest-Sandbox.ps1'
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Sandbox validation script not found: $ScriptPath"
}

if ($WorkerBaseUrl -notmatch '/$') {
    throw "WorkerBaseUrl must end with '/': $WorkerBaseUrl"
}

# --- Bind the `Runner` configuration section via environment variables (double-underscore = nesting). ---
$env:Runner__WorkerBaseUrl = $WorkerBaseUrl
$env:Runner__Host = $HostLabel
$env:Runner__ScriptPath = $ScriptPath
$env:Runner__PollIntervalSeconds = $PollIntervalSeconds
$env:Runner__TimeoutMinutes = $TimeoutMinutes
$env:Runner__Environment = $Environment

if ($ApiKey) { $env:Runner__ApiKey = $ApiKey }
else { Write-Warning 'No API key set. A secured Worker will reject requests with 401 (set -ApiKey or $env:WINGET_WORKER_API_KEY).' }

if ($LokiUri) { $env:Runner__LokiUri = $LokiUri }
if ($LokiUser) { $env:Runner__LokiUser = $LokiUser }
# Loki password (secret) is only read from the ambient env var, never a script parameter.
if ($env:WINGET_LOKI_PASSWORD) { $env:Runner__LokiPassword = $env:WINGET_LOKI_PASSWORD }

# ASP.NET/Hosting environment name.
$env:DOTNET_ENVIRONMENT = $Environment

Write-Host '--- SandboxRunner configuration ---------------------------------' -ForegroundColor Cyan
Write-Host ("  WorkerBaseUrl : {0}" -f $env:Runner__WorkerBaseUrl)
Write-Host ("  Host          : {0}" -f $env:Runner__Host)
Write-Host ("  ScriptPath    : {0}" -f $env:Runner__ScriptPath)
Write-Host ("  PollInterval  : {0}s" -f $env:Runner__PollIntervalSeconds)
Write-Host ("  Timeout       : {0}m" -f $env:Runner__TimeoutMinutes)
Write-Host ("  Environment   : {0}" -f $env:Runner__Environment)
Write-Host ("  ApiKey        : {0}" -f ($(if ($env:Runner__ApiKey) { '(set)' } else { '(none)' })))
Write-Host ("  LokiUri       : {0}" -f ($(if ($env:Runner__LokiUri) { $env:Runner__LokiUri } else { '(console only)' })))
Write-Host '-----------------------------------------------------------------' -ForegroundColor Cyan

# Reachability hint for the Worker (non-fatal).
try {
    $healthUrl = ($WorkerBaseUrl.TrimEnd('/')) + '/health'
    $null = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 3 -UseBasicParsing
    Write-Host "Worker health check OK: $healthUrl" -ForegroundColor Green
} catch {
    Write-Warning "Worker not reachable at $healthUrl. Start the Worker first, then re-run. (Continuing anyway.)"
}

Write-Host 'Starting SandboxRunner. Press Ctrl+C to stop.' -ForegroundColor Yellow

if ($ExePath) {
    if (-not (Test-Path -LiteralPath $ExePath)) { throw "ExePath not found: $ExePath" }
    & $ExePath
} else {
    dotnet run --project $projectPath -c $Configuration
}
