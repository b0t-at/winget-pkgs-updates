# Tests for Set-PackageStateOpenPr / Test-PackageStateOpenPrFresh (open-PR cache markers).
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
    } else {
        Write-Host "PASS: $Name"
    }
}

$stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "packagestate-openpr-$([guid]::NewGuid()).json"

try {
    # 1) Setting a marker creates the file and a minimal entry.
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.New' -Version '2.0.0'
    $entry = Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.New'
    Assert-Equal '2.0.0' $entry['openPr']['version'] 'marker is written with the pending version'
    Assert-Equal 1 $entry.Count 'fresh entry carries only the openPr marker'

    # 2) Fresh marker is reported fresh; wrong version and expired markers are not.
    Assert-Equal $true (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.New' -Version '2.0.0') 'just-written marker is fresh'
    Assert-Equal $false (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.New' -Version '3.0.0') 'version mismatch is not fresh'
    Assert-Equal $false (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.Other' -Version '2.0.0') 'unknown package is not fresh'

    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Old' -Version '1.0.0' -CheckedAt ((Get-Date).ToUniversalTime().AddHours(-25))
    Assert-Equal $false (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.Old' -Version '1.0.0') 'marker older than the default TTL is not fresh'
    Assert-Equal $true (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.Old' -Version '1.0.0' -TtlHours 48) 'larger TTL accepts an older marker'

    # 3) Markers coexist with validation state fields and survive re-sets.
    Set-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Version '1.0.0' -ManifestHash 'hash1' -InstallerHashes @('abc') -State 'VALIDATION_PASSED'
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Version '1.1.0'
    $entry = Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated'
    Assert-Equal 'VALIDATION_PASSED' $entry['state'] 'validation fields survive setting a marker'
    Assert-Equal '1.1.0' $entry['openPr']['version'] 'marker is added next to validation fields'

    # 4) Clearing removes the marker but keeps other fields; entries that held
    #    only a marker are removed entirely.
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Clear
    $entry = Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated'
    Assert-Equal $false $entry.ContainsKey('openPr') 'clear removes the marker'
    Assert-Equal 'VALIDATION_PASSED' $entry['state'] 'clear keeps validation fields'

    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.New' -Clear
    Assert-Equal '' "$(Get-PackageState -StateFilePath $stateFile -PackageIdentifier 'Vendor.New')" 'marker-only entry is removed on clear'

    # 5) Clearing a non-existent marker is a silent no-op.
    $before = Get-Content -Path $stateFile -Raw
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Ghost' -Clear
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Validated' -Clear
    Assert-Equal $before (Get-Content -Path $stateFile -Raw) 'clearing absent markers leaves the file untouched'

    # 6) Freshness checks against a missing state file return false.
    Assert-Equal $false (Test-PackageStateOpenPrFresh -StateFilePath (Join-Path ([System.IO.Path]::GetTempPath()) 'does-not-exist.json') -PackageIdentifier 'Vendor.New' -Version '1.0.0') 'missing state file is not fresh'

    # 7) An unparsable checkedAt value is treated as stale.
    $raw = Get-Content -Path $stateFile -Raw | ConvertFrom-Json -AsHashtable
    $raw['Vendor.Broken'] = @{ openPr = @{ version = '1.0.0'; checkedAt = 'not-a-date' } }
    $raw | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8 -Force
    Assert-Equal $false (Test-PackageStateOpenPrFresh -StateFilePath $stateFile -PackageIdentifier 'Vendor.Broken' -Version '1.0.0') 'unparsable checkedAt is not fresh'
}
finally {
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$script:failures assertion(s) failed."
    exit 1
}

Write-Host 'All PackageStateOpenPr tests passed.'
