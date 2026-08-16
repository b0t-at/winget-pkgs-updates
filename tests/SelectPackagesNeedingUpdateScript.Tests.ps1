$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# End-to-end tests for scripts/Select-PackagesNeedingUpdate.ps1: the fail-open
# fallback and the randomized batch cap.

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'scripts/Select-PackagesNeedingUpdate.ps1'

function Invoke-PrecheckScript {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Packages,
        [Parameter(Mandatory = $false)]
        [string] $BatchSize
    )

    $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("precheck-output-" + [guid]::NewGuid().ToString('N') + ".txt")
    New-Item -Path $outputFile -ItemType File -Force | Out-Null
    try {
        $batchSizeLine = if ([string]::IsNullOrWhiteSpace($BatchSize)) {
            "`$env:UPDATE_BATCH_SIZE = `$null"
        }
        else {
            "`$env:UPDATE_BATCH_SIZE = '$BatchSize'"
        }

        # No tokens: the precheck GraphQL call fails, exercising the fail-open path.
        $psi = @(
            "`$env:WINGET_UPSTREAM_READ_TOKEN = `$null",
            "`$env:GITHUB_TOKEN = `$null",
            "`$env:GH_TOKEN = `$null",
            $batchSizeLine,
            "`$env:MONITORED_PACKAGES = @'",
            (ConvertTo-Json -InputObject $Packages -Depth 10 -Compress),
            "'@",
            "`$env:GITHUB_OUTPUT = '$outputFile'",
            "& '$scriptPath'"
        ) -join [Environment]::NewLine
        $null = & pwsh -NoProfile -Command $psi 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Precheck script exited with code $LASTEXITCODE."
        }

        $outputContent = Get-Content -LiteralPath $outputFile -Raw
        $includeLine = ($outputContent -split "`r?`n") | Where-Object { $_ -like 'include=*' } | Select-Object -First 1
        $anyLine = ($outputContent -split "`r?`n") | Where-Object { $_ -like 'any=*' } | Select-Object -First 1
        if (-not $includeLine -or -not $anyLine) {
            throw "GITHUB_OUTPUT is missing include=/any= lines: $outputContent"
        }

        return [PSCustomObject]@{
            Include = @(($includeLine.Substring('include='.Length)) | ConvertFrom-Json)
            Any     = $anyLine.Substring('any='.Length)
        }
    }
    finally {
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
    }
}

$failures = @()

# --- Fallback below the cap keeps every package ---
$smallList = @(1..5 | ForEach-Object { [PSCustomObject]@{ id = "Package.Small$_"; repo = "owner/repo$_"; url = "https://example.invalid/$_" } })
$smallResult = Invoke-PrecheckScript -Packages $smallList
if (@($smallResult.Include).Count -ne 5) {
    $failures += "Fallback below the cap must keep all packages, got $(@($smallResult.Include).Count) of 5."
}
if ($smallResult.Any -ne 'true') {
    $failures += "Fallback below the cap must report any=true, got '$($smallResult.Any)'."
}

# --- Fallback above the default batch size is limited to 30 random packages ---
$largeList = @(1..300 | ForEach-Object { [PSCustomObject]@{ id = "Package.Large$_"; repo = "owner/repo$_"; url = "https://example.invalid/$_" } })
$largeResult = Invoke-PrecheckScript -Packages $largeList
if (@($largeResult.Include).Count -ne 30) {
    $failures += "Fallback above the cap must select exactly 30 packages, got $(@($largeResult.Include).Count)."
}
if ($largeResult.Any -ne 'true') {
    $failures += "Fallback above the cap must report any=true, got '$($largeResult.Any)'."
}
$knownIds = @($largeList | ForEach-Object { $_.id })
$selectedIds = @($largeResult.Include | ForEach-Object { $_.id })
$unknown = @($selectedIds | Where-Object { $_ -notin $knownIds })
if ($unknown.Count -gt 0) {
    $failures += "Capped selection contains unknown package ids: $($unknown -join ', ')."
}
if (@($selectedIds | Select-Object -Unique).Count -ne 30) {
    $failures += "Capped selection must not contain duplicate packages."
}

# --- The batch size is tunable, and never exceeds the 256-job matrix limit ---
$tunedResult = Invoke-PrecheckScript -Packages $largeList -BatchSize '12'
if (@($tunedResult.Include).Count -ne 12) {
    $failures += "UPDATE_BATCH_SIZE must override the default, expected 12, got $(@($tunedResult.Include).Count)."
}

$overLimitResult = Invoke-PrecheckScript -Packages $largeList -BatchSize '1000'
if (@($overLimitResult.Include).Count -ne 256) {
    $failures += "UPDATE_BATCH_SIZE above the matrix limit must cap at 256, got $(@($overLimitResult.Include).Count)."
}

$invalidResult = Invoke-PrecheckScript -Packages $largeList -BatchSize 'not-a-number'
if (@($invalidResult.Include).Count -ne 30) {
    $failures += "An invalid UPDATE_BATCH_SIZE must fall back to the default of 30, got $(@($invalidResult.Include).Count)."
}

# --- A selection below the batch size keeps every eligible package ---
$underBatch = @(1..7 | ForEach-Object { [PSCustomObject]@{ id = "Package.Under$_"; repo = "owner/repo$_"; url = "https://example.invalid/$_" } })
$underResult = Invoke-PrecheckScript -Packages $underBatch
if (@($underResult.Include).Count -ne 7) {
    $failures += "A list below the batch size must stay intact, got $(@($underResult.Include).Count) of 7."
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAILED: $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'All Select-PackagesNeedingUpdate script tests passed.' -ForegroundColor Green
