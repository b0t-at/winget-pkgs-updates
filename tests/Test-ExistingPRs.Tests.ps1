$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Test-ExistingPRs' {
    BeforeEach {
        $global:ExistingPrSearchRequests = [System.Collections.Generic.List[object]]::new()
        $global:OriginalUpstreamReadToken = $env:WINGET_UPSTREAM_READ_TOKEN
        $global:OriginalUpstreamReadFallbackToken = $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN
        $global:OriginalGitHubToken = $env:GITHUB_TOKEN
        $global:OriginalWingetPat = $env:WINGET_PAT
        $env:WINGET_UPSTREAM_READ_TOKEN = ''
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = ''
        $env:GITHUB_TOKEN = 'fork-write-token'
        $env:WINGET_PAT = 'fork-write-token'

        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            state        = 'open'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/12345'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }
    }

    AfterEach {
        $env:WINGET_UPSTREAM_READ_TOKEN = $global:OriginalUpstreamReadToken
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = $global:OriginalUpstreamReadFallbackToken
        $env:GITHUB_TOKEN = $global:OriginalGitHubToken
        $env:WINGET_PAT = $global:OriginalWingetPat
        Remove-Variable -Name ExistingPrSearchRequests -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalUpstreamReadToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalUpstreamReadFallbackToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalGitHubToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalWingetPat -Scope Global -ErrorAction SilentlyContinue
    }

    It 'falls back to an anonymous public upstream search without a dedicated read token' {
        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $true) {
            throw 'A matching upstream pull request was not found.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "Expected the open PR search to stop after one match, got $($global:ExistingPrSearchRequests.Count) request(s)."
        }

        $request = $global:ExistingPrSearchRequests[0]
        if ($request.Method -cne 'Get' -or $request.Uri -notmatch '^https://api\.github\.com/search/issues\?') {
            throw "Unexpected upstream PR search request: $($request | ConvertTo-Json -Compress)"
        }
        if ($request.Headers.ContainsKey('Authorization')) {
            throw 'The anonymous fallback must not send the fork-scoped token.'
        }

        $query = [uri]::UnescapeDataString(([uri] $request.Uri).Query)
        if ($query -notmatch 'repo:microsoft/winget-pkgs' -or $query -notmatch 'Test.Package 1.0.0' -or
            $query -match '\(is:open OR is:merged\)' -or $query -match 'is:merged') {
            throw "The public upstream PR search used an unexpected query: $query"
        }
    }

    It 'uses only the dedicated upstream read token for the public search' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'upstream-read-token'

        Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs' | Out-Null

        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "Expected one upstream duplicate search, got $($global:ExistingPrSearchRequests.Count)."
        }
        $authorization = $global:ExistingPrSearchRequests[0].Headers.Authorization
        if ($authorization -cne 'Bearer upstream-read-token') {
            throw "The upstream duplicate search used an unexpected credential: $authorization"
        }
        if ($authorization -match 'fork-write-token') {
            throw 'The upstream duplicate search consumed a fork-scoped credential.'
        }
    }

    It 'fails over from a rate limited primary read token to the fallback and then anonymous access' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'primary-read-token'
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = 'fallback-read-token'

        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                if ($Headers.ContainsKey('Authorization') -and $Headers.Authorization -notlike '*anonymous*') {
                    $rateLimitedResponse = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('API rate limit exceeded', $rateLimitedResponse)
                }
                return [pscustomobject]@{ total_count = 0; items = @() }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs' `
            -WarningAction SilentlyContinue

        if ($result -ne $false) {
            throw 'The anonymous final tier unexpectedly reported a duplicate.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 3) {
            throw "Expected primary, fallback, and anonymous attempts, got $($global:ExistingPrSearchRequests.Count) request(s)."
        }
        if ($global:ExistingPrSearchRequests[0].Headers.Authorization -notlike '*primary-read-token') {
            throw 'The first attempt did not use the primary read token.'
        }
        if ($global:ExistingPrSearchRequests[1].Headers.Authorization -notlike '*fallback-read-token') {
            throw 'The second attempt did not use the fallback read token.'
        }
        if ($global:ExistingPrSearchRequests[2].Headers.ContainsKey('Authorization')) {
            throw 'The final anonymous attempt sent a credential.'
        }
    }

    It 'does not fail over when the upstream search fails with a non-rate-limit error' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'primary-read-token'
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = 'fallback-read-token'

        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                $serverErrorResponse = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::InternalServerError)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('server error', $serverErrorResponse)
            }
        }

        $failed = $false
        try {
            Test-ExistingPRs `
                -PackageIdentifier 'Test.Package' `
                -Version '1.0.0' `
                -Repository 'microsoft/winget-pkgs' | Out-Null
        }
        catch {
            $failed = $true
        }

        if (-not $failed) {
            throw 'A server error during the upstream search did not surface.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "A non-rate-limit error was retried: $($global:ExistingPrSearchRequests.Count) request(s)."
        }
    }

    It 'detects exact open and merged titles while ignoring closed-unmerged and substring candidates' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{
                    total_count = 4
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            state        = 'open'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/100'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        },
                        [pscustomobject]@{
                            title        = 'Add version: Test.Package version 1.0.0 - Update version: Test.Package version 1.0.0'
                            state        = 'closed'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/101'
                            pull_request = [pscustomobject]@{ merged_at = '2026-08-06T12:00:00Z' }
                        },
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            state        = 'closed'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/102'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        },
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package.Extra version 1.0.0'
                            state        = 'open'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/103'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $true) {
            throw 'An exact matching open upstream pull request was not found.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "Duplicate detection performed $($global:ExistingPrSearchRequests.Count) requests instead of one."
        }

        $query = [uri]::UnescapeDataString(([uri] $global:ExistingPrSearchRequests[0].Uri).Query)
        if ($query -match '\(is:open OR is:merged\)' -or $query -match 'is:merged') {
            throw "Duplicate detection used the invalid GitHub Search state expression: $query"
        }
    }

    It 'ignores an exact closed-unmerged title when no open or merged title exists' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            state        = 'closed'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/102'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $false) {
            throw 'A closed-unmerged upstream PR was treated as a duplicate.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "Duplicate detection performed $($global:ExistingPrSearchRequests.Count) requests instead of one."
        }
    }

    It 'detects the legacy combined add-and-update title when the PR was merged' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Add version: Test.Package version 1.0.0 - Update version: Test.Package version 1.0.0'
                            state        = 'closed'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/101'
                            pull_request = [pscustomobject]@{ merged_at = '2026-08-06T12:00:00Z' }
                        }
                    )
                }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $true) {
            throw 'A merged legacy add-and-update pull request was not detected.'
        }
    }

    It 'ignores substring and tokenized title search candidates' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                return [pscustomobject]@{
                    total_count = 2
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package.Extra version 1.0.0'
                            state        = 'open'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/103'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        },
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0.1'
                            state        = 'open'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/104'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $false) {
            throw 'A substring or tokenized title candidate was treated as an exact duplicate.'
        }
    }

    It 'searches only open pull requests when requested' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{ total_count = 0; items = @() }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs' `
            -OnlyOpen

        if ($result -ne $false) {
            throw 'An empty upstream PR search unexpectedly found a match.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "OnlyOpen performed $($global:ExistingPrSearchRequests.Count) search requests instead of one."
        }

        $query = [uri]::UnescapeDataString(([uri] $global:ExistingPrSearchRequests[0].Uri).Query)
        if ($query -notmatch 'is:open' -or $query -match 'is:merged') {
            throw "OnlyOpen used an unexpected query: $query"
        }
    }

    It 'fails closed when GitHub cannot provide state metadata for a candidate' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/12345'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }

        {
            Test-ExistingPRs `
                -PackageIdentifier 'Test.Package' `
                -Version '1.0.0' `
                -Repository 'microsoft/winget-pkgs'
        } | Should -Throw '*without a title or state*'
    }

    It 'fails closed rather than treating a malformed authenticated response as no duplicate' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'primary-read-token'
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = 'fallback-read-token'

        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{ total_count = 1 }
            }
        }

        {
            Test-ExistingPRs `
                -PackageIdentifier 'Test.Package' `
                -Version '1.0.0' `
                -Repository 'microsoft/winget-pkgs'
        } | Should -Throw '*incomplete response*'

        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw 'A malformed primary response was converted into a fallback no-duplicate decision.'
        }
    }
}
