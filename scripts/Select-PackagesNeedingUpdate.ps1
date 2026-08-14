# Reads the monitored package list from MONITORED_PACKAGES (JSON), determines
# which packages actually need a manifest update via batched GraphQL queries,
# and writes the resulting matrix include list to GITHUB_OUTPUT.
#
# Fail-open: if the precheck itself fails for any reason, all packages are
# emitted so a broken precheck can never suppress real updates.
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'WingetMaintainerModule' 'WingetMaintainerModule.psd1') -Force

if ([string]::IsNullOrWhiteSpace($env:MONITORED_PACKAGES)) {
    throw 'The MONITORED_PACKAGES environment variable is empty. The orchestrator must inject the package list.'
}

$packages = @($env:MONITORED_PACKAGES | ConvertFrom-Json)
$include = $packages

try {
    $stateFilePath = Join-Path $PSScriptRoot '..' 'data' 'package-state.json'
    $result = Select-GitHubPackagesNeedingUpdate -Packages $packages -StateFilePath $stateFilePath
    $include = @($result.Include | ForEach-Object { $_.Package })

    $skippedGroups = @($result.Skipped | Group-Object -Property Reason)
    foreach ($group in $skippedGroups) {
        Write-Host "Skipping $($group.Count) package(s) [$($group.Name)]: $(@($group.Group | ForEach-Object { $_.Package.id }) -join ', ')"
    }

    $includeGroups = @($result.Include | Group-Object -Property Reason)
    foreach ($group in $includeGroups) {
        Write-Host "Including $($group.Count) package(s) [$($group.Name)]: $(@($group.Group | ForEach-Object { $_.Package.id }) -join ', ')"
    }
}
catch {
    Write-Warning "Update precheck failed: $($_.Exception.Message). Falling back to processing all $($packages.Count) monitored packages."
    $include = $packages
}

# GitHub Actions rejects matrices with more than 256 jobs. This mainly guards
# the fail-open fallback above (full monitored list > 256). The selection is
# randomized so repeated capped runs rotate coverage across all packages
# instead of starving the alphabetical tail.
$maxMatrixJobs = 256
if (@($include).Count -gt $maxMatrixJobs) {
    $deferredCount = @($include).Count - $maxMatrixJobs
    Write-Warning "Include list ($(@($include).Count)) exceeds the $maxMatrixJobs-job matrix limit. Randomly selecting $maxMatrixJobs package(s); $deferredCount deferred to the next scheduled run."
    $include = @($include | Get-Random -Count $maxMatrixJobs)
}

$includeJson = ConvertTo-Json -InputObject @($include) -Depth 10 -Compress
$any = if (@($include).Count -gt 0) { 'true' } else { 'false' }

Write-Host "Selected $(@($include).Count) of $($packages.Count) monitored package(s) for manifest generation."

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "include=$includeJson"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "any=$any"
}
