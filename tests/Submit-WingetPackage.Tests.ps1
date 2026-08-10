$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Submit-WingetPackage branch-moved retry' {
    BeforeEach {
        $global:SubmitWingetPackageTestManifestPath = Join-Path ([IO.Path]::GetTempPath()) "winget-submit-tests-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:SubmitWingetPackageTestManifestPath -Force | Out-Null
        $global:NewTestSubmissionAttempt = {
            param(
                [int] $ExitCode,
                [string] $ErrorCode,
                [string] $ErrorMessage,
                [string] $PrUrl
            )

            if ($ErrorCode) {
                $result = [pscustomobject]@{
                    error = [pscustomobject]@{
                        code    = $ErrorCode
                        message = $ErrorMessage
                    }
                }
            }
            else {
                $result = [pscustomobject]@{
                    pullRequest = [pscustomobject]@{
                        url    = $PrUrl
                        number = '12345'
                    }
                }
            }

            return [pscustomobject]@{
                ExitCode  = $ExitCode
                Output    = if ($ErrorCode) { "$ErrorCode : $ErrorMessage" } else { "Created $PrUrl" }
                Result    = $result
                ErrorCode = $ErrorCode
                Error     = if ($ErrorCode) { "$ErrorCode : $ErrorMessage" } else { $null }
            }
        }

        InModuleScope WingetMaintainerModule {
            $script:submissionAttempts = 0
            Mock Install-WinMatsch {}
            Mock Test-ExistingPRs { $false }
            Mock Get-WingetPkgsPrUrl { $null }
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $global:SubmitWingetPackageTestManifestPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name SubmitWingetPackageTestManifestPath -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name NewTestSubmissionAttempt -Scope Global -ErrorAction SilentlyContinue
    }

        It 'revalidates and submits once after a safe GH2020 branch movement' {
            InModuleScope WingetMaintainerModule {
                Mock Invoke-WinMatschSubmitAttempt {
                    $script:submissionAttempts++
                    if ($script:submissionAttempts -eq 1) {
                        return & $global:NewTestSubmissionAttempt -ExitCode 5 -ErrorCode 'GH2020' -ErrorMessage 'The validated branch moved immediately before pull request creation.'
                    }

                    return & $global:NewTestSubmissionAttempt -ExitCode 0 -PrUrl 'https://github.com/microsoft/winget-pkgs/pull/12345'
                }

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token' `
                    -MaxBranchMovedRetries 1

                if ($result.Success -ne $true) {
                    throw "Expected a successful retry, got: $($result.Error)"
                }
                if ($result.PrUrl -cne 'https://github.com/microsoft/winget-pkgs/pull/12345') {
                    throw "The retry returned an unexpected PR URL: $($result.PrUrl)"
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 2 -Exactly -Scope It
                Assert-MockCalled Test-ExistingPRs -Times 3 -Exactly -Scope It
            }
        }

        It 'fails closed when the bounded GH2020 retry is exhausted' {
            InModuleScope WingetMaintainerModule {
                Mock Invoke-WinMatschSubmitAttempt {
                    & $global:NewTestSubmissionAttempt -ExitCode 5 -ErrorCode 'GH2020' -ErrorMessage 'The validated branch moved immediately before pull request creation.'
                }

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token' `
                    -MaxBranchMovedRetries 1

                if ($result.Success -ne $false) {
                    throw 'Retry exhaustion unexpectedly reported success.'
                }
                if ($result.Error -notmatch 'after 2 attempt\(s\)') {
                    throw "Retry exhaustion did not report the bounded attempt count: $($result.Error)"
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 2 -Exactly -Scope It
                Assert-MockCalled Test-ExistingPRs -Times 3 -Exactly -Scope It
            }
        }

        It 'does not submit again when another worker created the matching PR' {
            InModuleScope WingetMaintainerModule {
                $script:existingChecks = 0
                Mock Test-ExistingPRs {
                    $script:existingChecks++
                    return $script:existingChecks -eq 3
                }
                Mock Get-WingetPkgsPrUrl { 'https://github.com/microsoft/winget-pkgs/pull/54321' }
                Mock Invoke-WinMatschSubmitAttempt {
                    & $global:NewTestSubmissionAttempt -ExitCode 5 -ErrorCode 'GH2020' -ErrorMessage 'The validated branch moved immediately before pull request creation.'
                }

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token' `
                    -MaxBranchMovedRetries 1

                if ($result.Success -ne $true) {
                    throw "The existing PR result was not successful: $($result.Error)"
                }
                if ($result.PrUrl -cne 'https://github.com/microsoft/winget-pkgs/pull/54321') {
                    throw "The existing PR URL was not returned: $($result.PrUrl)"
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 1 -Exactly -Scope It
                Assert-MockCalled Test-ExistingPRs -Times 3 -Exactly -Scope It
            }
        }

        It 'skips every submission attempt when the explicit target already has an open PR' {
            InModuleScope WingetMaintainerModule {
                Mock Test-ExistingPRs { $true }
                Mock Get-WingetPkgsPrUrl { 'https://github.com/damn-good-b0t/winget-pkgs/pull/99' }
                Mock Install-WinMatsch {}
                Mock Invoke-WinMatschSubmitAttempt {}

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token' `
                    -Repository 'damn-good-b0t/winget-pkgs'

                if ($result.Success -ne $true -or $result.PrUrl -cne 'https://github.com/damn-good-b0t/winget-pkgs/pull/99') {
                    throw "The explicit-target duplicate was not returned: $($result | ConvertTo-Json -Compress)"
                }
                Assert-MockCalled Test-ExistingPRs -Times 1 -Exactly -Scope It -ParameterFilter {
                    $OnlyOpen -and $Repository -ceq 'damn-good-b0t/winget-pkgs'
                }
                Assert-MockCalled Install-WinMatsch -Times 0 -Exactly -Scope It
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 0 -Exactly -Scope It
            }
        }

        It 'fails closed instead of retrying an uncertain GH2020 remote outcome' {
            InModuleScope WingetMaintainerModule {
                Mock Invoke-WinMatschSubmitAttempt {
                    & $global:NewTestSubmissionAttempt `
                        -ExitCode 5 `
                        -ErrorCode 'GH2020' `
                        -ErrorMessage 'The validated branch moved. Remote outcome uncertain: true.'
                }

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token' `
                    -MaxBranchMovedRetries 3

                if ($result.Success -ne $false) {
                    throw 'An uncertain remote outcome unexpectedly retried or reported success.'
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 1 -Exactly -Scope It
                Assert-MockCalled Test-ExistingPRs -Times 2 -Exactly -Scope It
            }
        }
    }
