$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

function New-GeneratedInstallerManifest {
    param(
        [Parameter(Mandatory = $true)] [string] $Root,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [object[]] $Entries
    )

    $firstChar = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    $packagePath = $PackageIdentifier -replace '\.', '/'
    $directory = Join-Path $Root "manifests/$firstChar/$packagePath/$Version"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $lines = @(
        "PackageIdentifier: $PackageIdentifier"
        "PackageVersion: $Version"
        'Installers:'
    )
    foreach ($entry in $Entries) {
        $lines += "- Architecture: $($entry.Architecture)"
        $lines += "  InstallerUrl: $($entry.InstallerUrl)"
    }
    $lines += 'ManifestType: installer'
    Set-Content -Path (Join-Path $directory "$PackageIdentifier.installer.yaml") -Value ($lines -join "`n")
}

function New-PreviousInstallerManifestContent {
    param(
        [Parameter(Mandatory = $true)] [object[]] $Entries
    )

    $lines = @('Installers:')
    foreach ($entry in $Entries) {
        $lines += "- Architecture: $($entry.Architecture)"
        $lines += "  InstallerUrl: $($entry.InstallerUrl)"
    }
    $lines += 'ManifestType: installer'
    return ($lines -join "`n")
}

function Invoke-ArchitectureValidation {
    param(
        [Parameter(Mandatory = $true)] [string] $ManifestOutPath,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $CurrentVersion,
        [Parameter(Mandatory = $true)] [string[]] $RequestedInstallerValues,
        [Parameter()] [string] $PreviousVersion = '',
        [Parameter()] [string] $PreviousManifestContent = ''
    )

    return & $module {
        param($OutPath, $Id, $Current, $Requested, $Previous, $PreviousContent)

        $script:StubPreviousManifestContent = $PreviousContent
        function Invoke-WebRequest {
            param($Uri, [switch]$UseBasicParsing)

            if ([string]::IsNullOrWhiteSpace($script:StubPreviousManifestContent)) {
                throw 'The previous manifest fetch must not run for this test.'
            }
            return [pscustomobject]@{ Content = $script:StubPreviousManifestContent }
        }

        try {
            if ([string]::IsNullOrWhiteSpace($Previous)) {
                Test-GeneratedInstallerArchitecture `
                    -PackageIdentifier $Id `
                    -CurrentVersion $Current `
                    -ManifestOutPath $OutPath `
                    -RequestedInstallerValues $Requested | Out-Null
            }
            else {
                Test-GeneratedInstallerArchitecture `
                    -PackageIdentifier $Id `
                    -CurrentVersion $Current `
                    -ManifestOutPath $OutPath `
                    -RequestedInstallerValues $Requested `
                    -PreviousVersion $Previous | Out-Null
            }
            [pscustomobject]@{ Threw = $false; Message = $null }
        }
        catch {
            [pscustomobject]@{ Threw = $true; Message = "$($_.Exception.Message)" }
        }
    } $ManifestOutPath $PackageIdentifier $CurrentVersion $RequestedInstallerValues $PreviousVersion $PreviousManifestContent
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "winget-arch-tests-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    Write-Host 'TEST: a generated architecture superset of the previous manifest passes (dual-arch winmatsch output)'
    # Verified case Mibuw.miPDFsignCommunity: the published manifest lists the
    # setup exe under x86 only while the generator correctly emits the same
    # URL under x86 and x64.
    $root = Join-Path $testRoot 'superset'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Mibuw.miPDFsignCommunity' -Version '1.0.1' -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.0.1/setup.exe' },
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/1.0.1/setup.exe' }
    )
    $previousContent = New-PreviousInstallerManifestContent -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.0.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Mibuw.miPDFsignCommunity' `
        -CurrentVersion '1.0.1' `
        -RequestedInstallerValues @('https://example.com/download/1.0.1/setup.exe') `
        -PreviousVersion '1.0.0' `
        -PreviousManifestContent $previousContent
    if ($outcome.Threw) {
        throw "A dual-arch superset was rejected as drift: $($outcome.Message)"
    }

    Write-Host 'TEST: a previously published architecture that disappears still throws'
    $root = Join-Path $testRoot 'replaced'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Test.Package' -Version '2.0.0' -Entries @(
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' }
    )
    $previousContent = New-PreviousInstallerManifestContent -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Test.Package' `
        -CurrentVersion '2.0.0' `
        -RequestedInstallerValues @('https://example.com/download/2.0.0/setup.exe') `
        -PreviousVersion '1.9.0' `
        -PreviousManifestContent $previousContent
    if (-not $outcome.Threw) {
        throw 'A replaced architecture (x86 -> x64) was not flagged as drift.'
    }
    if ($outcome.Message -notmatch 'Generated architecture drift detected' -or $outcome.Message -notmatch 'x86') {
        throw "The drift error did not name the missing architecture: $($outcome.Message)"
    }

    Write-Host 'TEST: dropping one of several previously published architectures throws'
    $root = Join-Path $testRoot 'narrowed'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Test.Package' -Version '2.0.0' -Entries @(
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' }
    )
    $previousContent = New-PreviousInstallerManifestContent -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' },
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Test.Package' `
        -CurrentVersion '2.0.0' `
        -RequestedInstallerValues @('https://example.com/download/2.0.0/setup.exe') `
        -PreviousVersion '1.9.0' `
        -PreviousManifestContent $previousContent
    if (-not $outcome.Threw -or $outcome.Message -notmatch 'x86') {
        throw "Narrowing x86+x64 to x64 was not flagged as drift: $($outcome | ConvertTo-Json -Compress)"
    }

    Write-Host 'TEST: matching multi-architecture sets with an extra architecture pass'
    $root = Join-Path $testRoot 'extended'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Test.Package' -Version '2.0.0' -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' },
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' },
        [pscustomobject]@{ Architecture = 'arm64'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' }
    )
    $previousContent = New-PreviousInstallerManifestContent -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' },
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Test.Package' `
        -CurrentVersion '2.0.0' `
        -RequestedInstallerValues @('https://example.com/download/2.0.0/setup.exe') `
        -PreviousVersion '1.9.0' `
        -PreviousManifestContent $previousContent
    if ($outcome.Threw) {
        throw "A preserved multi-architecture set with an addition was rejected: $($outcome.Message)"
    }

    Write-Host 'TEST: URLs absent from the previous manifest are not compared'
    $root = Join-Path $testRoot 'changed-url'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Test.Package' -Version '2.0.0' -Entries @(
        [pscustomobject]@{ Architecture = 'x64'; InstallerUrl = 'https://example.com/download/2.0.0/renamed.exe' }
    )
    $previousContent = New-PreviousInstallerManifestContent -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/1.9.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Test.Package' `
        -CurrentVersion '2.0.0' `
        -RequestedInstallerValues @('https://example.com/download/2.0.0/renamed.exe') `
        -PreviousVersion '1.9.0' `
        -PreviousManifestContent $previousContent
    if ($outcome.Threw) {
        throw "A renamed installer URL was compared against unrelated previous entries: $($outcome.Message)"
    }

    Write-Host 'TEST: explicit architecture hints still fail on a mismatch'
    $root = Join-Path $testRoot 'hinted'
    New-GeneratedInstallerManifest -Root $root -PackageIdentifier 'Test.Package' -Version '2.0.0' -Entries @(
        [pscustomobject]@{ Architecture = 'x86'; InstallerUrl = 'https://example.com/download/2.0.0/setup.exe' }
    )
    $outcome = Invoke-ArchitectureValidation `
        -ManifestOutPath $root `
        -PackageIdentifier 'Test.Package' `
        -CurrentVersion '2.0.0' `
        -RequestedInstallerValues @('https://example.com/download/2.0.0/setup.exe|x64')
    if (-not $outcome.Threw -or $outcome.Message -notmatch 'Generated architecture mismatch') {
        throw "A hinted architecture mismatch was not flagged: $($outcome | ConvertTo-Json -Compress)"
    }

    Write-Host 'All Test-GeneratedInstallerArchitecture tests passed.'
}
finally {
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
