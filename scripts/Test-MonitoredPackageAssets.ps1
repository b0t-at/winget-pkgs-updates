# Read-only health check for the monitored package configuration.
#
# Verifies that every active package's release-asset URL template still
# matches a real asset on the package's current GitHub release, so broken
# templates (renamed assets, deleted releases, archived repositories) are
# caught in a weekly report instead of surfacing as failed generations or
# upstream URL-Validation-Error pull requests.
#
# Inputs (environment):
#   MONITORED_PACKAGES_FILE  Path to the generated packages JSON sidecar
#                            (defaults to the 1-z sidecar).
#   GITHUB_STEP_SUMMARY      Markdown summary target (optional).
#   GITHUB_OUTPUT            Receives broken_count / checked_count (optional).
#
# The script always exits 0: it produces the report consumed by the workflow,
# which persists definitive findings as per-package submission blocks.
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'WingetMaintainerModule' 'WingetMaintainerModule.psd1') -Force

$packagesPath = $env:MONITORED_PACKAGES_FILE
if ([string]::IsNullOrWhiteSpace($packagesPath)) {
    $packagesPath = Join-Path $PSScriptRoot '..' '.github' 'workflows-data' 'update-github-packages-1-z.packages.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($packagesPath)) {
    $packagesPath = Join-Path $PSScriptRoot '..' $packagesPath
}

if (-not (Test-Path -LiteralPath $packagesPath)) {
    throw "Monitored packages file not found: $packagesPath"
}

$packages = @(Get-Content -LiteralPath $packagesPath -Raw | ConvertFrom-Json)
Write-Host "Checking release-asset URL templates for $($packages.Count) monitored package(s)."

$results = @(Test-MonitoredPackageAssets -Packages $packages)

$broken = @($results | Where-Object { $_.Status -in @('RepoMissing', 'NoRelease', 'NoMatchingRelease', 'VersionUnresolved', 'AssetMissing') })
$inconclusive = @($results | Where-Object { $_.Status -eq 'Inconclusive' })
$ok = @($results | Where-Object { $_.Status -eq 'OK' })
$skipped = @($results | Where-Object { $_.Status -eq 'Skipped' })

$reportPath = './config-health-report.json'
ConvertTo-Json -InputObject @($results) -Depth 4 | Set-Content -Path $reportPath -Encoding utf8
Write-Host "Wrote $reportPath"

$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('## Monitored package config health')
$summary.Add('')
$summary.Add("Checked **$($results.Count)** package(s): $($ok.Count) OK, **$($broken.Count) broken**, $($inconclusive.Count) inconclusive, $($skipped.Count) skipped.")
$summary.Add('')

if ($broken.Count -gt 0) {
    $summary.Add('### :x: Broken URL templates (fix or exclude these packages)')
    $summary.Add('')
    $summary.Add('| Package | Repo | Status | Detail |')
    $summary.Add('| --- | --- | --- | --- |')
    foreach ($row in $broken) {
        $detail = ("$($row.Detail)" -replace '\s*[\r\n]+\s*', ' ').Replace('|', '\|')
        $summary.Add("| $($row.PackageId) | $($row.Repo) | ``$($row.Status)`` | $detail |")
    }
    $summary.Add('')
}

if ($inconclusive.Count -gt 0) {
    $summary.Add('### :grey_question: Inconclusive (asset list truncated)')
    $summary.Add('')
    foreach ($row in $inconclusive) {
        $summary.Add("- **$($row.PackageId)** ($($row.Repo)): $($row.Detail)")
    }
    $summary.Add('')
}

if ($broken.Count -eq 0) {
    $summary.Add(':white_check_mark: Every active URL template resolves to an existing release asset.')
}

$summaryText = $summary -join "`n"
Write-Host $summaryText

if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summaryText | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "broken_count=$($broken.Count)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "checked_count=$($results.Count)"
}
