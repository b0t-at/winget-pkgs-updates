#Requires -Version 7.0

<#
.SYNOPSIS
    Verifies that scan candidates would actually resolve to a downloadable
    installer before they are added to `github-releases-monitored.yml`.

.DESCRIPTION
    `Find-OutdatedGitHubPackages.ps1` reports that a newer GitHub release exists.
    That is a necessary but not sufficient condition for automation: the derived
    `{VERSION}` URL template also has to produce a real asset URL for the new
    version, and the manifest may carry several architecture-specific installers
    of which the scan only recorded the first.

    This script performs static checks and then a real HEAD request against the
    templated URL for the new version, which is the only way to prove the
    template survives the version bump.

.PARAMETER InputPath
    Scan report produced by Find-OutdatedGitHubPackages.ps1.

.PARAMETER OutputPath
    CSV report including the probe verdict per package.

.PARAMETER Confidence
    Only test rows with these confidence levels.

.PARAMETER Sample
    Probe only a random sample of N packages instead of all of them.

.PARAMETER ThrottleLimit
    Parallel HEAD requests.

.EXAMPLE
    ./scripts/Test-OutdatedPackageCandidate.ps1 -Sample 150
#>
[CmdletBinding()]
param(
    [string] $InputPath,
    [string] $OutputPath,
    [string[]] $Confidence = @('High'),
    [int] $Sample = 0,
    [int] $ThrottleLimit = 12
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($InputPath)) { $InputPath = Join-Path $repoRoot 'winget-github-versions.csv' }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repoRoot 'data\github-outdated-verified.csv' }

$rows = @(Import-Csv -LiteralPath $InputPath | Where-Object { $_.Confidence -in $Confidence })
Write-Host "Loaded $($rows.Count) candidate(s) at confidence: $($Confidence -join ', ')" -ForegroundColor Cyan

# --- static checks -----------------------------------------------------------

$noPlaceholder = @($rows | Where-Object { $_.UrlTemplate -notmatch '\{VERSION\}' })
$floatingLatest = @($rows | Where-Object { $_.InstallerUrl -match '/releases/latest/download/' })
$tagIsVPlusVersion = @($rows | Where-Object { $_.LatestTag -eq ('v' + $_.LatestVersion) })
$tagIsVersion = @($rows | Where-Object { $_.LatestTag -eq $_.LatestVersion })

Write-Host ''
Write-Host 'Static checks' -ForegroundColor Cyan
Write-Host "  template has no {VERSION} placeholder : $($noPlaceholder.Count)"
Write-Host "  URL uses /releases/latest/download    : $($floatingLatest.Count)"
Write-Host "  tag == 'v' + version                  : $($tagIsVPlusVersion.Count)"
Write-Host "  tag == version                        : $($tagIsVersion.Count)"
Write-Host "  tag uses some other scheme            : $($rows.Count - $tagIsVPlusVersion.Count - $tagIsVersion.Count)"

# --- live probe --------------------------------------------------------------

$toProbe = $rows
if ($Sample -gt 0 -and $Sample -lt $rows.Count) {
    $toProbe = @($rows | Get-Random -Count $Sample)
    Write-Host ''
    Write-Host "Probing a random sample of $Sample candidate(s)..." -ForegroundColor Cyan
}
else {
    Write-Host ''
    Write-Host "Probing all $($toProbe.Count) candidate(s)..." -ForegroundColor Cyan
}

$results = $toProbe | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $row = $_
    $templates = @($row.UrlTemplate -split '\s+' | Where-Object { $_ })

    $status = 'Ok'
    $detail = ''
    $probed = [System.Collections.Generic.List[string]]::new()

    if ($templates.Count -eq 0 -or ($templates | Where-Object { $_ -notmatch '\{VERSION\}' })) {
        $status = 'NoPlaceholder'
        $detail = 'At least one installer URL did not contain the version string; template cannot be bumped.'
    }
    else {
        # Every architecture must resolve: a manifest with one dead asset URL is
        # not submittable, so a single failure fails the whole package.
        foreach ($template in $templates) {
            $probeUrl = $template -replace '\{VERSION\}', $row.LatestVersion
            $probed.Add($probeUrl)

            try {
                $response = Invoke-WebRequest -Uri $probeUrl -Method Head -MaximumRedirection 5 -TimeoutSec 30 -SkipHttpErrorCheck
                if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
                    $status = 'NotFound'
                    $detail = "HTTP $($response.StatusCode) for $probeUrl"
                    break
                }
            }
            catch {
                $status = 'Error'
                $detail = "$($_.Exception.Message) for $probeUrl"
                break
            }
        }
    }

    [PSCustomObject]@{
        PackageId      = $row.PackageId
        CurrentVersion = $row.CurrentVersion
        LatestVersion  = $row.LatestVersion
        LatestTag      = $row.LatestTag
        Confidence     = $row.Confidence
        UrlCount       = $templates.Count
        ProbeStatus    = $status
        ProbeUrl       = $probed -join ' '
        ProbeDetail    = $detail
        UrlTemplate    = $row.UrlTemplate
        GitHubOwner    = $row.GitHubOwner
        GitHubRepo     = $row.GitHubRepo
    }
}

$ordered = @($results | Sort-Object ProbeStatus, PackageId)
New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
$ordered | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8

# Only packages whose every installer URL resolved for the new version are safe
# to drop into github-releases-monitored.yml unattended.
$verifiedPath = Join-Path (Split-Path -Parent $OutputPath) 'github-outdated-candidates-verified.yml'
$snippet = foreach ($row in @($ordered | Where-Object { $_.ProbeStatus -eq 'Ok' })) {
    "          - id: `"$($row.PackageId)`""
    "            repo: `"$($row.GitHubOwner)/$($row.GitHubRepo)`""
    "            url: `"$($row.UrlTemplate)`""
}
Set-Content -LiteralPath $verifiedPath -Value ($snippet -join "`n") -Encoding utf8

# Packages that are genuinely behind but whose URL template does not survive the
# version bump. They need a per-package asset lookup before they can be
# automated, so they are parked in their own list.
$brokenPath = Join-Path (Split-Path -Parent $OutputPath) 'github-outdated-url-broken.csv'
@($ordered | Where-Object { $_.ProbeStatus -ne 'Ok' }) |
    Export-Csv -LiteralPath $brokenPath -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host 'Probe results' -ForegroundColor Cyan
$ordered | Group-Object ProbeStatus | Sort-Object Count -Descending | ForEach-Object {
    $percent = [math]::Round(100 * $_.Count / $ordered.Count, 1)
    Write-Host ("  {0,-14} {1,5}  ({2}%)" -f $_.Name, $_.Count, $percent)
}
Write-Host ''
Write-Host "Report          : $OutputPath"
Write-Host "Verified ready  : $verifiedPath"
Write-Host "Broken URLs     : $brokenPath"
