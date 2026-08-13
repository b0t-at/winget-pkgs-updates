$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Submit-WingetPackage final validation hook' {
    BeforeEach {
        $global:FinalValidationManifestPath = Join-Path ([IO.Path]::GetTempPath()) "winget-final-validation-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:FinalValidationManifestPath -Force | Out-Null
        @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
ManifestType: version
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $global:FinalValidationManifestPath 'Test.Package.yaml')
    }

    AfterEach {
        Remove-Item -LiteralPath $global:FinalValidationManifestPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name FinalValidationManifestPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'fails closed when final validation after normalization fails' {
        InModuleScope WingetMaintainerModule {
            Mock Install-WinMatsch {}
            Mock Test-ExistingPRs { $false }
            Mock Get-WingetPkgsPrUrl { $null }
            Mock Test-WingetManifestContent {
                [pscustomobject]@{
                    Valid = $false
                    Errors = @('Injected final validation failure.')
                    Warnings = @()
                }
            } -ParameterFilter {
                $ManifestPath -eq $global:FinalValidationManifestPath -and $SkipPublishedComparison
            }
            Mock Invoke-WinMatschSubmitAttempt {}

            $result = Submit-WingetPackage `
                -ManifestPath $global:FinalValidationManifestPath `
                -PackageId 'Test.Package' `
                -Version '1.0.0' `
                -Token 'test-token'

            if ($result.Success -ne $false) {
                throw "Expected final validation failure, got: $($result | ConvertTo-Json -Compress)"
            }
            if ($result.Error -notmatch 'Injected final validation failure') {
                throw "Final validation failure was not surfaced: $($result.Error)"
            }
            Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 0 -Exactly -Scope It
            Assert-MockCalled Test-WingetManifestContent -Times 1 -Exactly -Scope It -ParameterFilter {
                $ManifestPath -eq $global:FinalValidationManifestPath -and $SkipPublishedComparison
            }
        }
    }
}
