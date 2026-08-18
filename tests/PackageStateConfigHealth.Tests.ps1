# Tests for the Config Health package-state blocklist.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -WarningAction SilentlyContinue

$script:failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)

    if ("$Expected" -ne "$Actual") {
        $script:failures++
        Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')"
    }
    else {
        Write-Host "PASS: $Name"
    }
}

$stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "packagestate-config-health-$([guid]::NewGuid()).json"

try {
    Set-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Version '1.0.0' -ManifestHash 'hash1' -InstallerHashes @('abc') -State 'VALIDATION_PASSED'
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Version '2.0.0'

    $results = @(
        [PSCustomObject]@{ PackageId = 'Vendor.Validated'; Status = 'AssetMissing'; Detail = 'Expected setup.exe is absent.'; Tag = 'v2.0.0' },
        [PSCustomObject]@{ PackageId = 'Vendor.Missing'; Status = 'RepoMissing'; Detail = 'Repository no longer exists.'; Tag = $null },
        [PSCustomObject]@{ PackageId = 'Vendor.Unknown'; Status = 'Inconclusive'; Detail = 'Asset list is truncated.'; Tag = 'v3.0.0' }
    )

    $sync = Update-PackageStateConfigHealth -StateFilePath $stateFile -Results $results -CheckedAt ([datetime]'2026-08-18T00:00:00Z')
    $blocks = Get-PackageStateConfigHealthBlocks -StateFilePath $stateFile
    $validated = Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated'

    Assert-Equal 2 $sync.Blocked 'definitive Config Health results are counted as blocks'
    Assert-Equal 2 $sync.Updated 'new Config Health blocks are persisted'
    Assert-Equal $true $sync.Changed 'new Config Health blocks change state'
    Assert-Equal 'AssetMissing' $blocks['Vendor.Validated']['status'] 'asset failure is blocklisted'
    Assert-Equal 'RepoMissing' $blocks['Vendor.Missing']['status'] 'missing repository is blocklisted'
    Assert-Equal $false $blocks.Contains('Vendor.Unknown') 'inconclusive health result is not blocklisted'
    Assert-Equal 'VALIDATION_PASSED' $validated['state'] 'validation state survives Config Health block'
    Assert-Equal '2.0.0' $validated['openPr']['version'] 'open PR state survives Config Health block'

    $unchanged = Update-PackageStateConfigHealth -StateFilePath $stateFile -Results $results -CheckedAt ([datetime]'2026-08-19T00:00:00Z')
    Assert-Equal $false $unchanged.Changed 'identical Config Health findings do not churn state'

    $recovery = Update-PackageStateConfigHealth -StateFilePath $stateFile -Results @(
        [PSCustomObject]@{ PackageId = 'Vendor.Validated'; Status = 'OK'; Detail = 'Asset now resolves.'; Tag = 'v2.0.1' },
        [PSCustomObject]@{ PackageId = 'Vendor.Missing'; Status = 'Inconclusive'; Detail = 'Asset list is truncated.'; Tag = $null }
    )
    $blocks = Get-PackageStateConfigHealthBlocks -StateFilePath $stateFile
    $validated = Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated'

    Assert-Equal 2 $recovery.Cleared 'non-blocking health results clear prior blocks'
    Assert-Equal $false $blocks.Contains('Vendor.Validated') 'recovered package is unblocked'
    Assert-Equal $false $blocks.Contains('Vendor.Missing') 'inconclusive package is unblocked'
    Assert-Equal 'VALIDATION_PASSED' $validated['state'] 'clearing health state preserves validation state'
    Assert-Equal '2.0.0' $validated['openPr']['version'] 'clearing health state preserves open PR state'
    Assert-Equal '' "$(Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Missing')" 'marker-only entry is removed after recovery'
}
finally {
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$script:failures assertion(s) failed."
    exit 1
}

Write-Host 'All PackageStateConfigHealth tests passed.'
