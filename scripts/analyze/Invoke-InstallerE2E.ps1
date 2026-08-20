#Requires -Version 7.0

<#
.SYNOPSIS
    Package-agnostic end-to-end probe: URL (or winget-pkgs PR) -> analyze ->
    demo manifest -> optional sandbox install -> report.

.DESCRIPTION
    Answers the question "what would our pipeline do with this installer?"
    without touching any monitored package:

      1. Resolve installer URLs - either given directly via -InstallerUrl or
         extracted from a microsoft/winget-pkgs pull request (-WingetPkgsPr).
      2. Run `winmatsch analyze` on every installer (architecture, installer
         type, detected silent switches, hashes, signature, ...).
      3. Generate a throwaway manifest with `winmatsch new` under a demo
         package identifier. Nothing is submitted; names are placeholders.
      4. Validate the demo manifest with `winmatsch validate`.
      5. Optionally install it in Windows Sandbox via
         scripts/validation/Test-Manifest-Sandbox.ps1 (skipped automatically
         when the Sandbox feature is unavailable).
      6. Write report.json and report.md to the output directory.

.EXAMPLE
    ./scripts/analyze/Invoke-InstallerE2E.ps1 -InstallerUrl 'https://example.com/setup.exe'

.EXAMPLE
    ./scripts/analyze/Invoke-InstallerE2E.ps1 -WingetPkgsPr 421311

.EXAMPLE
    ./scripts/analyze/Invoke-InstallerE2E.ps1 -WingetPkgsPr 421311 -SkipSandbox -PackageId 'Demo.PGlove'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Url')]
    [string[]] $InstallerUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'Pr')]
    [int] $WingetPkgsPr,

    [Parameter(ParameterSetName = 'Pr')]
    [string] $PrRepo = 'microsoft/winget-pkgs',

    [string] $PackageId = 'Demo.Analysis',
    [string] $Version,
    [string] $Publisher = 'Demo Publisher',
    [string] $PackageName = 'Demo Analysis Package',

    [switch] $SkipAnalyze,
    [switch] $SkipManifest,
    [switch] $SkipSandbox,
    [switch] $KeepSandboxOpen,

    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot "data\e2e-analysis\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Import-Module (Join-Path $repoRoot 'modules\WingetMaintainerModule') -Force
Install-WinMatsch

$report = [ordered]@{
    StartedAt = (Get-Date).ToString('o')
    Source    = $PSCmdlet.ParameterSetName
    PackageId = $PackageId
    Urls      = @()
    PrInfo    = $null
    Analyses  = @()
    Manifest  = $null
    Sandbox   = $null
}

# --- 1. resolve installer URLs -------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'Pr') {
    Write-Host "`n=== Resolving installer URLs from $PrRepo PR #$WingetPkgsPr ===" -ForegroundColor Cyan

    $pr = gh pr view $WingetPkgsPr --repo $PrRepo --json files,headRefOid,headRepositoryOwner,title | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "gh pr view failed for PR #$WingetPkgsPr" }

    $report.PrInfo = [ordered]@{
        Number = $WingetPkgsPr
        Title  = $pr.title
        Owner  = $pr.headRepositoryOwner.login
        Sha    = $pr.headRefOid
    }

    $installerFiles = @($pr.files | Where-Object { $_.path -match '\.installer\.ya?ml$' })
    if ($installerFiles.Count -eq 0) { throw "PR #$WingetPkgsPr contains no *.installer.yaml manifest" }

    $prManifestInfo = @()
    $resolvedUrls = @()
    foreach ($file in $installerFiles) {
        $escapedPath = ($file.path -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $rawUrl = "https://raw.githubusercontent.com/$($pr.headRepositoryOwner.login)/winget-pkgs/$($pr.headRefOid)/$escapedPath"
        $content = ((Invoke-RestMethod -Uri $rawUrl) -join "`n") -split "`n"

        $urlsInFile = @($content | Where-Object { $_ -match '^\s*InstallerUrl:\s*' } | ForEach-Object { ($_ -replace '^\s*InstallerUrl:\s*', '').Trim() })
        $resolvedUrls += $urlsInFile
        $prManifestInfo += [ordered]@{
            Path    = $file.path
            Version = (($content | Where-Object { $_ -match '^PackageVersion:' } | Select-Object -First 1) -replace '^PackageVersion:\s*', '').Trim()
            Type    = (($content | Where-Object { $_ -match '^InstallerType:' } | Select-Object -First 1) -replace '^InstallerType:\s*', '').Trim()
            Urls    = $urlsInFile
        }
    }
    $InstallerUrl = @($resolvedUrls | Select-Object -Unique)
    $report.PrInfo.Manifests = $prManifestInfo
}

if (-not $InstallerUrl -or $InstallerUrl.Count -eq 0) { throw 'No installer URLs to analyze.' }
$report.Urls = $InstallerUrl
Write-Host "Installer URL(s):" -ForegroundColor Cyan
$InstallerUrl | ForEach-Object { Write-Host "  $_" }

# --- 2. analyze -----------------------------------------------------------------

if (-not $SkipAnalyze) {
    foreach ($url in $InstallerUrl) {
        Write-Host "`n=== Analyzing $url ===" -ForegroundColor Cyan
        $safeName = ([uri]$url).Segments[-1] -replace '[^\w\.-]', '_'
        $analysisPath = Join-Path $OutputDir "analyze-$safeName.json"

        $json = & winmatsch analyze $url --format json --interaction never --no-cache 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $json | Set-Content -LiteralPath $analysisPath -Encoding utf8

        $parsed = $null
        try { $parsed = $json | ConvertFrom-Json } catch { Write-Warning "analyze output was not JSON: $_" }

        $report.Analyses += [ordered]@{
            Url      = $url
            ExitCode = $exitCode
            RawPath  = $analysisPath
            Result   = $parsed
        }
        Write-Host $json
        if ($exitCode -ne 0) { Write-Warning "winmatsch analyze exited with $exitCode for $url" }
    }
}

# --- 3. demo manifest -----------------------------------------------------------

if (-not $SkipManifest) {
    Write-Host "`n=== Generating demo manifest for $PackageId ===" -ForegroundColor Cyan

    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = '1.0.0'
        # Prefer a product version detected during analysis over the placeholder.
        foreach ($analysis in $report.Analyses) {
            $candidate = $null
            if ($analysis.Result -and $analysis.Result.PSObject.Properties['product']) {
                $candidate = $analysis.Result.product.version
            }
            if ($candidate -and $candidate -match '^\d+(\.\d+){0,3}$') { $Version = $candidate; break }
        }
    }

    $manifestDir = Join-Path $OutputDir 'manifest'
    $newArgs = @(
        'new', $PackageId
        '--version', $Version
        '--urls'
    ) + $InstallerUrl + @(
        '--publisher', $Publisher
        '--package-name', $PackageName
        '--short-description', 'Throwaway manifest for end-to-end pipeline analysis'
        '--license', 'Proprietary'
        '--skip-pr-check'
        '--interaction', 'never'
        '--format', 'json'
        '--no-cache'
        '--output', $manifestDir
    )
    if ($env:GITHUB_TOKEN) { $newArgs += @('--token', $env:GITHUB_TOKEN) }

    $displayArgs = $newArgs | ForEach-Object { if ($_ -eq $env:GITHUB_TOKEN) { '***' } else { $_ } }
    Write-Host "Running: winmatsch $($displayArgs -join ' ')"
    $newOutput = & winmatsch @newArgs 2>&1 | Out-String
    $newExit = $LASTEXITCODE
    Write-Host $newOutput
    $newOutput | Set-Content -LiteralPath (Join-Path $OutputDir 'manifest-new.log') -Encoding utf8

    $newParsed = $null
    try { $newParsed = $newOutput | ConvertFrom-Json } catch { }
    $newResultCode = if ($newParsed -and $newParsed.PSObject.Properties['resultCode']) { $newParsed.resultCode } else { "exit$newExit" }

    $generatedFiles = @()
    if (Test-Path $manifestDir) {
        $generatedFiles = @(Get-ChildItem -Path $manifestDir -Recurse -Filter '*.yaml' |
            Where-Object { $_.FullName -notmatch '\.winmatsch-transaction' } |
            ForEach-Object { $_.FullName })
    }

    $report.Manifest = [ordered]@{
        ExitCode         = $newExit
        ResultCode       = $newResultCode
        Version          = $Version
        Path             = $manifestDir
        Files            = $generatedFiles
        ValidateExitCode = $null
        ValidateOutput   = $null
    }

    # --- 4. validate --------------------------------------------------------------
    if ($generatedFiles.Count -gt 0) {
        Write-Host "`n=== Validating demo manifest ===" -ForegroundColor Cyan
        $validateOutput = & winmatsch validate $generatedFiles --interaction never --format json 2>&1 | Out-String
        $report.Manifest.ValidateExitCode = $LASTEXITCODE
        $report.Manifest.ValidateOutput = $validateOutput
        Write-Host $validateOutput
    }
    else {
        Write-Warning 'No manifest files were generated; skipping validation and sandbox.'
        $SkipSandbox = $true
    }
}
else {
    $SkipSandbox = $true
}

# --- 5. sandbox -----------------------------------------------------------------

if (-not $SkipSandbox) {
    $sandboxAvailable = $false
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -ErrorAction Stop
        $sandboxAvailable = ($feature.State -eq 'Enabled')
    }
    catch {
        Write-Warning "Cannot query Windows Sandbox feature state (needs elevation?): $($_.Exception.Message)"
    }

    if (-not $sandboxAvailable) {
        Write-Warning 'Windows Sandbox is not enabled on this machine; skipping sandbox install.'
    }
    else {
        Write-Host "`n=== Installing demo manifest in Windows Sandbox ===" -ForegroundColor Cyan
        $sandboxScript = Join-Path $repoRoot 'scripts\validation\Test-Manifest-Sandbox.ps1'
        # Test-Manifest-Sandbox expects the flat folder that directly contains the yaml files.
        $installerYaml = @($report.Manifest.Files | Where-Object { $_ -match '\.installer\.yaml$' } | Select-Object -First 1)
        $sandboxManifestPath = if ($installerYaml) { Split-Path -Parent $installerYaml } else { $report.Manifest.Path }
        & $sandboxScript -ManifestPath $sandboxManifestPath -KeepSandboxOpen:$KeepSandboxOpen
        $sandboxExit = $LASTEXITCODE
        $report.Sandbox = [ordered]@{ ExitCode = $sandboxExit }
        Write-Host "Sandbox exit code: $sandboxExit (0 = success)"
    }
}

# --- 6. report ------------------------------------------------------------------

$report.FinishedAt = (Get-Date).ToString('o')
$reportPath = Join-Path $OutputDir 'report.json'
($report | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $reportPath -Encoding utf8

$md = [System.Text.StringBuilder]::new()
[void] $md.AppendLine("# E2E installer analysis - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
[void] $md.AppendLine()
if ($report.PrInfo) {
    [void] $md.AppendLine("**Source:** $PrRepo PR #$($report.PrInfo.Number) - $($report.PrInfo.Title)")
}
else {
    [void] $md.AppendLine('**Source:** direct URL(s)')
}
[void] $md.AppendLine()
foreach ($analysis in $report.Analyses) {
    [void] $md.AppendLine("## $($analysis.Url)")
    [void] $md.AppendLine()
    [void] $md.AppendLine("- analyze exit code: $($analysis.ExitCode)")
    $r = $analysis.Result
    if ($r -and $r.installers) {
        foreach ($inst in $r.installers) {
            $prop = { param($o, $n) if ($o.PSObject.Properties[$n]) { $o.$n } else { $null } }
            [void] $md.AppendLine("- arch: $(& $prop $inst 'architecture') | type: $(& $prop $inst 'installerType') | scope: $(& $prop $inst 'scope')")
            $switches = & $prop $inst 'switches'
            if ($switches) { [void] $md.AppendLine("- switches: $($switches | ConvertTo-Json -Compress)") }
            $sha = & $prop $inst 'sha256'
            if (-not $sha -and $r.PSObject.Properties['sha256']) { $sha = $r.sha256 }
            if ($sha) { [void] $md.AppendLine("- sha256: $sha") }
        }
    }
    [void] $md.AppendLine()
}
if ($report.Manifest) {
    [void] $md.AppendLine("## Demo manifest ($PackageId $Version)")
    [void] $md.AppendLine()
    [void] $md.AppendLine("- generation: $($report.Manifest.ResultCode) (exit $($report.Manifest.ExitCode))")
    [void] $md.AppendLine("- validation exit code: $($report.Manifest.ValidateExitCode)")
    [void] $md.AppendLine("- path: $($report.Manifest.Path)")
    [void] $md.AppendLine()
}
[void] $md.AppendLine('## Sandbox')
[void] $md.AppendLine()
if ($report.Sandbox) {
    [void] $md.AppendLine("- exit code: $($report.Sandbox.ExitCode) (0 = installed successfully)")
}
else {
    [void] $md.AppendLine('- skipped')
}
$mdPath = Join-Path $OutputDir 'report.md'
$md.ToString() | Set-Content -LiteralPath $mdPath -Encoding utf8

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  URLs analyzed : $($report.Analyses.Count)"
if ($report.Manifest) {
    $validateExit = if ($null -ne $report.Manifest.ValidateExitCode) { $report.Manifest.ValidateExitCode } else { 'n/a' }
    Write-Host "  Manifest      : $($report.Manifest.ResultCode) (exit $($report.Manifest.ExitCode)), validate exit $validateExit"
}
if ($report.Sandbox) {
    Write-Host "  Sandbox       : exit $($report.Sandbox.ExitCode)"
}
else {
    Write-Host "  Sandbox       : skipped"
}
Write-Host "  Report        : $mdPath"
