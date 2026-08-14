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
    $result = Select-GitHubPackagesNeedingUpdate -Packages $packages
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

$includeJson = ConvertTo-Json -InputObject @($include) -Depth 10 -Compress
$any = if (@($include).Count -gt 0) { 'true' } else { 'false' }

Write-Host "Selected $(@($include).Count) of $($packages.Count) monitored package(s) for manifest generation."

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "include=$includeJson"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "any=$any"
}
