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
        [string] $BatchSize,
        [Parameter(Mandatory = $false)]
        [switch] $ViaFile,
        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary] $PackageState,
        [Parameter(Mandatory = $false)]
        [string] $PackageStateContent
    )

    $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("precheck-output-" + [guid]::NewGuid().ToString('N') + ".txt")
    New-Item -Path $outputFile -ItemType File -Force | Out-Null
    $packagesFile = $null
    $stateFile = $null
    try {
        $batchSizeLine = if ([string]::IsNullOrWhiteSpace($BatchSize)) {
            "`$env:UPDATE_BATCH_SIZE = `$null"
        }
        else {
            "`$env:UPDATE_BATCH_SIZE = '$BatchSize'"
        }

        $packagesJson = ConvertTo-Json -InputObject $Packages -Depth 10 -Compress

        # The generated workflows pass a file path; inline JSON stays supported
        # for ad-hoc runs.
        if ($ViaFile) {
            $packagesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("precheck-packages-" + [guid]::NewGuid().ToString('N') + ".json")
            Set-Content -LiteralPath $packagesFile -Value $packagesJson -Encoding utf8
            $packageLines = @(
                "`$env:MONITORED_PACKAGES = `$null",
                "`$env:MONITORED_PACKAGES_FILE = '$packagesFile'"
            )
        }
        else {
            $packageLines = @(
                "`$env:MONITORED_PACKAGES_FILE = `$null",
                "`$env:MONITORED_PACKAGES = @'",
                $packagesJson,
                "'@"
            )
        }

        $hasPackageState = $PSBoundParameters.ContainsKey('PackageState')
        $hasPackageStateContent = $PSBoundParameters.ContainsKey('PackageStateContent')
        if ($hasPackageState -or $hasPackageStateContent) {
            $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) ("precheck-state-" + [guid]::NewGuid().ToString('N') + ".json")
            if ($hasPackageStateContent) {
                Set-Content -LiteralPath $stateFile -Value $PackageStateContent -Encoding utf8
            }
            else {
                $PackageState | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stateFile -Encoding utf8
            }
            $stateLines = @("`$env:PACKAGE_STATE_FILE = '$stateFile'")
        }
        else {
            $stateLines = @("`$env:PACKAGE_STATE_FILE = `$null")
        }

        # No tokens: the precheck GraphQL call fails, exercising the fail-open path.
        $psi = @(
            "`$env:WINGET_UPSTREAM_READ_TOKEN = `$null",
            "`$env:GITHUB_TOKEN = `$null",
            "`$env:GH_TOKEN = `$null",
            $batchSizeLine
        ) + $stateLines + $packageLines + @(
            "`$env:GITHUB_OUTPUT = '$outputFile'",
            "& '$scriptPath'"
        ) -join [Environment]::NewLine
        $childOutput = @(& pwsh -NoProfile -Command $psi 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Precheck script exited with code ${LASTEXITCODE}: $($childOutput -join "`n")"
        }

        $outputContent = Get-Content -LiteralPath $outputFile -Raw
        $includeLine = ($outputContent -split "`r?`n") | Where-Object { $_ -like 'include=*' } | Select-Object -First 1
        $anyLine = ($outputContent -split "`r?`n") | Where-Object { $_ -like 'any=*' } | Select-Object -First 1
        $healthBlockedLine = ($outputContent -split "`r?`n") | Where-Object { $_ -like 'health_blocked_count=*' } | Select-Object -First 1
        if (-not $includeLine -or -not $anyLine -or -not $healthBlockedLine) {
            throw "GITHUB_OUTPUT is missing include=/any=/health_blocked_count= lines: $outputContent"
        }

        return [PSCustomObject]@{
            Include            = @(($includeLine.Substring('include='.Length)) | ConvertFrom-Json)
            Any                = $anyLine.Substring('any='.Length)
            HealthBlockedCount = [int]$healthBlockedLine.Substring('health_blocked_count='.Length)
            ChildOutput        = ($childOutput | ForEach-Object { "$_" }) -join "`n"
            StateContent       = if ($stateFile) { Get-Content -LiteralPath $stateFile -Raw } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
        if ($packagesFile) {
            Remove-Item -LiteralPath $packagesFile -Force -ErrorAction SilentlyContinue
        }
        if ($stateFile) {
            Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        }
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

# --- The package list can be supplied as a file, which is what the generated
#     workflows do: the full list far exceeds the Linux 128 KiB limit for a
#     single environment variable. ---
$fileResult = Invoke-PrecheckScript -Packages $underBatch -ViaFile
if (@($fileResult.Include).Count -ne 7) {
    $failures += "MONITORED_PACKAGES_FILE must be honoured, got $(@($fileResult.Include).Count) of 7."
}
if ($fileResult.Any -ne 'true') {
    $failures += "A file-supplied list must report any=true, got '$($fileResult.Any)'."
}

# --- Definitive Config Health blocks survive GraphQL precheck fallback. ---
$healthState = @{
    'Package.Blocked' = @{
        configHealth = @{
            status    = 'AssetMissing'
            detail    = 'Expected setup.exe is absent.'
            checkedAt = '2026-08-18T00:00:00Z'
        }
    }
}
$healthPackages = @(
    [PSCustomObject]@{ id = 'Package.Blocked'; repo = 'owner/blocked'; url = 'https://example.invalid/blocked' },
    [PSCustomObject]@{ id = 'Package.Healthy'; repo = 'owner/healthy'; url = 'https://example.invalid/healthy' }
)
$healthResult = Invoke-PrecheckScript -Packages $healthPackages -PackageState $healthState
if (@($healthResult.Include).Count -ne 1 -or $healthResult.Include[0].id -ne 'Package.Healthy') {
    $failures += "Config Health block must remain excluded when GraphQL precheck falls back. State: $($healthResult.StateContent) Child output: $($healthResult.ChildOutput)"
}
if ($healthResult.HealthBlockedCount -ne 1) {
    $failures += "Expected one Config Health block in fallback, got $($healthResult.HealthBlockedCount). State: $($healthResult.StateContent) Child output: $($healthResult.ChildOutput)"
}
if ($healthResult.Any -ne 'true') {
    $failures += "Fallback with one healthy package must report any=true, got '$($healthResult.Any)'."
}

$allBlockedResult = Invoke-PrecheckScript -Packages @($healthPackages[0]) -PackageState $healthState
if (@($allBlockedResult.Include).Count -ne 0 -or $allBlockedResult.Any -ne 'false') {
    $failures += 'All Config Health-blocked packages must suppress the generation matrix.'
}

# --- A corrupt health cache is loud but does not halt healthy packages. ---
$corruptStateResult = Invoke-PrecheckScript -Packages $healthPackages -PackageStateContent '{not-json'
if (@($corruptStateResult.Include).Count -ne 2 -or $corruptStateResult.Any -ne 'true') {
    $failures += 'A corrupt Config Health cache must fall back to processing all packages.'
}
if ($corruptStateResult.HealthBlockedCount -ne 0) {
    $failures += "A corrupt Config Health cache must report zero trusted blocks, got $($corruptStateResult.HealthBlockedCount)."
}

# --- A missing package file must fail loudly instead of silently doing nothing ---
$missingFileOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("precheck-output-" + [guid]::NewGuid().ToString('N') + ".txt")
New-Item -Path $missingFileOutput -ItemType File -Force | Out-Null
$missingScript = @(
    "`$env:MONITORED_PACKAGES = `$null",
    "`$env:MONITORED_PACKAGES_FILE = 'does-not-exist.packages.json'",
    "`$env:GITHUB_OUTPUT = '$missingFileOutput'",
    "& '$scriptPath'"
) -join [Environment]::NewLine
$null = & pwsh -NoProfile -Command $missingScript 2>&1
if ($LASTEXITCODE -eq 0) {
    $failures += 'A missing MONITORED_PACKAGES_FILE must fail the precheck.'
}
Remove-Item -LiteralPath $missingFileOutput -Force -ErrorAction SilentlyContinue

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAILED: $_" -ForegroundColor Red }
    exit 1
}

Write-Host 'All Select-PackagesNeedingUpdate script tests passed.' -ForegroundColor Green
