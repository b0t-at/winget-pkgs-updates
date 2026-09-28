$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Submit-WingetPackage branch-moved retry' {
    BeforeEach {
        $global:SubmitWingetPackageTestManifestPath = Join-Path ([IO.Path]::GetTempPath()) "winget-submit-tests-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:SubmitWingetPackageTestManifestPath -Force | Out-Null
        @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $global:SubmitWingetPackageTestManifestPath 'Test.Package.yaml')
        @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
PackageLocale: en-US
Publisher: Test Publisher
PackageName: Test Package
ShortDescription: Test package
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $global:SubmitWingetPackageTestManifestPath 'Test.Package.locale.en-US.yaml')
        @"
PackageIdentifier: Test.Package
PackageVersion: 1.0.0
Installers:
  - Architecture: x64
    InstallerType: zip
    InstallerUrl: https://downloads.example.invalid/test-package.zip
    InstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111
ManifestType: installer
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $global:SubmitWingetPackageTestManifestPath 'Test.Package.installer.yaml')
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
            # The URL preflight probes the network; tests stub it as alive.
            Mock Test-WingetInstallerUrlsAlive {
                [PSCustomObject]@{ Valid = $true; DeadUrls = @(); Warnings = @(); CheckedCount = 1 }
            }
            Mock Find-WingetDuplicateIdentifierByInstallerHash {
                [PSCustomObject]@{ Duplicate = $false; Reason = $null; MatchingIdentifier = $null; MatchingHash = $null; MatchingUrl = $null; Warnings = @() }
            }
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

        It 'normalizes mixed-ending locale YAML before WinMatsch submission' {
            $localeManifestPath = Join-Path $global:SubmitWingetPackageTestManifestPath 'Test.Package.locale.en-US.yaml'
            $mixedContent = "PackageIdentifier: Test.Package`r`nPackageVersion: 1.0.0`nPackageLocale: en-US`r`nPublisher: Test Publisher`nPackageName: Test Package`r`nShortDescription: Mixed line endings`nManifestType: defaultLocale`r`nManifestVersion: 1.12.0`n"
            [System.IO.File]::WriteAllText(
                $localeManifestPath,
                $mixedContent,
                [System.Text.UTF8Encoding]::new($false)
            )

            InModuleScope WingetMaintainerModule {
                Mock Invoke-WinMatschSubmitAttempt {
                    & $global:NewTestSubmissionAttempt -ExitCode 0 -PrUrl 'https://github.com/microsoft/winget-pkgs/pull/12345'
                }

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token'

                if ($result.Success -ne $true) {
                    throw "Expected the WinMatsch submission to succeed, got: $($result.Error)"
                }
            }

            $normalizedBytes = [System.IO.File]::ReadAllBytes($localeManifestPath)
            $bareLineFeedCount = 0
            for ($index = 0; $index -lt $normalizedBytes.Length; $index++) {
                if ($normalizedBytes[$index] -eq 10 -and ($index -eq 0 -or $normalizedBytes[$index - 1] -ne 13)) {
                    $bareLineFeedCount++
                }
            }
            if ($bareLineFeedCount -ne 0) {
                throw "The submitted locale YAML still contains $bareLineFeedCount bare LF character(s)."
            }

            $normalizedContent = [System.Text.Encoding]::UTF8.GetString($normalizedBytes)
            $expectedContent = "PackageIdentifier: Test.Package`r`nPackageVersion: 1.0.0`r`nPackageLocale: en-US`r`nPublisher: Test Publisher`r`nPackageName: Test Package`r`nShortDescription: Mixed line endings`r`nManifestType: defaultLocale`r`nManifestVersion: 1.12.0`r`n"
            if ($normalizedContent -cne $expectedContent) {
                throw "Locale YAML content changed beyond line endings: $normalizedContent"
            }
            if (-not $normalizedContent.EndsWith("`r`n") -or $normalizedContent.EndsWith("`r`n`r`n")) {
                throw 'The submitted locale YAML does not have exactly one final CRLF.'
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

        It 'blocks submission when generated hashes match another identifier' {
            InModuleScope WingetMaintainerModule {
                Mock Find-WingetDuplicateIdentifierByInstallerHash {
                    [PSCustomObject]@{
                        Duplicate          = $true
                        Reason             = 'DuplicateOfOtherIdentifier'
                        MatchingIdentifier = 'GoshsLabs.Goshs'
                        MatchingHash       = '1111111111111111111111111111111111111111111111111111111111111111'
                        MatchingUrl        = 'https://github.com/microsoft/winget-pkgs/pull/436891'
                        Warnings           = @()
                    }
                }
                Mock Invoke-WinMatschSubmitAttempt {}

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'PatrickHener.Goshs' `
                    -Version '2.1.6' `
                    -Token 'test-token'

                if ($result.Success -ne $false -or $result.Error -notmatch 'DuplicateOfOtherIdentifier' -or $result.Error -notmatch 'GoshsLabs\.Goshs') {
                    throw "The duplicate identifier guard did not stop submission clearly: $($result | ConvertTo-Json -Compress)"
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 0 -Exactly -Scope It
            }
        }

        It 'blocks submission when an installer URL is definitively dead' {
            InModuleScope WingetMaintainerModule {
                Mock Test-WingetInstallerUrlsAlive {
                    [PSCustomObject]@{
                        Valid        = $false
                        DeadUrls     = @('https://downloads.example.invalid/test-package.zip')
                        Warnings     = @()
                        CheckedCount = 1
                    }
                }
                Mock Invoke-WinMatschSubmitAttempt {}

                $result = Submit-WingetPackage `
                    -ManifestPath $global:SubmitWingetPackageTestManifestPath `
                    -PackageId 'Test.Package' `
                    -Version '1.0.0' `
                    -Token 'test-token'

                if ($result.Success -ne $false) {
                    throw 'A dead installer URL unexpectedly reported success.'
                }
                if ($result.Error -notmatch 'Installer URL preflight failed' -or $result.Error -notmatch 'test-package\.zip') {
                    throw "The dead-URL error did not name the URL: $($result.Error)"
                }
                Assert-MockCalled Invoke-WinMatschSubmitAttempt -Times 0 -Exactly -Scope It
            }
        }
    }


Describe 'Duplicate identifier guard real GitHub path' {
    BeforeEach {
        $global:DuplicateGuardManifestPath = Join-Path ([IO.Path]::GetTempPath()) "winget-duplicate-guard-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:DuplicateGuardManifestPath -Force | Out-Null
        @"
PackageIdentifier: PatrickHener.Goshs
PackageVersion: 2.1.6
Installers:
- Architecture: x64
  InstallerUrl: https://example.invalid/goshs.zip
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
ManifestType: installer
ManifestVersion: 1.12.0
"@ | Set-Content -LiteralPath (Join-Path $global:DuplicateGuardManifestPath 'PatrickHener.Goshs.installer.yaml')
    }

    AfterEach {
        Remove-Item -LiteralPath $global:DuplicateGuardManifestPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name DuplicateGuardManifestPath -Scope Global -ErrorAction SilentlyContinue
    }

    It 'uses the default search and manifest reader inside module scope' {
        InModuleScope WingetMaintainerModule {
            $script:DuplicateGuardGhCalls = [System.Collections.Generic.List[object]]::new()
            function gh {
                param([Parameter(ValueFromRemainingArguments = $true)] [object[]] $Arguments)

                $script:DuplicateGuardGhCalls.Add(@($Arguments))
                $global:LASTEXITCODE = 0
                $argumentText = @($Arguments) -join ' '
                if ($argumentText -match 'search/issues') {
                    if ($Arguments -contains '--paginate') {
                        throw 'duplicate guard search must not paginate'
                    }
                    if ($Arguments -notcontains 'per_page=30') {
                        throw "duplicate guard search must cap at 30 results: $argumentText"
                    }
                    $queryArgument = @($Arguments | Where-Object { $_ -like 'q=*' } | Select-Object -First 1)
                    if ($queryArgument.Count -ne 1 -or $queryArgument[0] -notmatch 'in:title' -or $queryArgument[0] -notmatch 'Goshs' -or $queryArgument[0] -notmatch '2\.1\.6') {
                        throw "duplicate guard search query is not constrained to title/segment/version: $argumentText"
                    }
                    return '[{"number":436891,"title":"Update version: GoshsLabs.Goshs version 2.1.6","body":"","html_url":"https://github.com/microsoft/winget-pkgs/pull/436891"}]'
                }
                if ($argumentText -match 'contents/manifests/g/GoshsLabs/Goshs/2\.1\.6/GoshsLabs\.Goshs\.installer\.yaml') {
                    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'))
                }
                throw "Unexpected gh call: $argumentText"
            }
            Mock Invoke-GhCliWithRetry {
                param($ScriptBlock, $OperationName)
                & $ScriptBlock
            }

            $result = Find-WingetDuplicateIdentifierByInstallerHash `
                -PackageIdentifier 'PatrickHener.Goshs' `
                -Version '2.1.6' `
                -ManifestPath $global:DuplicateGuardManifestPath

            if (-not $result.Duplicate -or $result.MatchingIdentifier -cne 'GoshsLabs.Goshs') {
                throw "The default duplicate guard path did not detect the other identifier: $($result | ConvertTo-Json -Compress)"
            }
            if ($script:DuplicateGuardGhCalls.Count -ne 2) {
                throw "Expected search and manifest gh calls, got $($script:DuplicateGuardGhCalls.Count)."
            }
            Assert-MockCalled Invoke-GhCliWithRetry -Times 2 -Exactly -Scope It
        }
    }
}
