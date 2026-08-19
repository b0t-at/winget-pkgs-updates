$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Test-ExistingPRs' {
    BeforeEach {
        $global:ExistingPrSearchRequests = [System.Collections.Generic.List[object]]::new()
        $global:ExistingPrSearchSleeps = [System.Collections.Generic.List[int]]::new()
        $global:OriginalUpstreamReadToken = $env:WINGET_UPSTREAM_READ_TOKEN
        $global:OriginalUpstreamReadFallbackToken = $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN
        $global:OriginalGitHubToken = $env:GITHUB_TOKEN
        $global:OriginalWingetPat = $env:WINGET_PAT
        $env:WINGET_UPSTREAM_READ_TOKEN = ''
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = ''
        $env:GITHUB_TOKEN = 'fork-write-token'
        $env:WINGET_PAT = 'fork-write-token'

        InModuleScope WingetMaintainerModule {
            Mock Start-Sleep {
                param($Seconds)
                $global:ExistingPrSearchSleeps.Add($Seconds)
            }
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
        Remove-Variable -Name ExistingPrSearchSleeps -Scope Global -ErrorAction SilentlyContinue
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
        if ($query -notmatch 'repo:microsoft/winget-pkgs' -or $query -notmatch 'in:title "Test\.Package" "1\.0\.0"' -or
            $query -match '\(is:open OR is:merged\)' -or $query -match 'is:merged') {
            throw "The public upstream PR search used an unexpected query: $query"
        }
    }

    It 'extracts GitHub response details without masking errors that have no response' {
        $details = InModuleScope WingetMaintainerModule {
            $httpError = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('GitHub request failed'),
                'GitHubRequestFailed',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )
            $httpError.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                '{"message":"Validation Failed"}'
            )
            $networkError = [System.Management.Automation.ErrorRecord]::new(
                [System.Net.Http.HttpRequestException]::new('Network unavailable'),
                'NetworkUnavailable',
                [System.Management.Automation.ErrorCategory]::ConnectionError,
                $null
            )

            [pscustomobject]@{
                ResponseBody = Get-WingetPkgsGitHubApiFailureResponseBody -ErrorRecord $httpError
                NetworkBody  = Get-WingetPkgsGitHubApiFailureResponseBody -ErrorRecord $networkError
            }
        }

        if ($details.ResponseBody -cne '{"message":"Validation Failed"}') {
            throw "GitHub response details were not preserved: $($details.ResponseBody)"
        }
        if ($null -ne $details.NetworkBody) {
            throw 'A network failure without an HTTP response unexpectedly produced a response body.'
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
        if ($global:ExistingPrSearchRequests.Count -ne 18) {
            throw "Expected both search stages to run 4 primary retries, 4 fallback retries, and one anonymous attempt each, got $($global:ExistingPrSearchRequests.Count) request(s)."
        }
        foreach ($stageOffset in @(0, 9)) {
            foreach ($index in 0..3) {
                if ($global:ExistingPrSearchRequests[$stageOffset + $index].Headers.Authorization -notlike '*primary-read-token') {
                    throw "Attempt $($stageOffset + $index + 1) did not use the primary read token."
                }
            }
            foreach ($index in 4..7) {
                if ($global:ExistingPrSearchRequests[$stageOffset + $index].Headers.Authorization -notlike '*fallback-read-token') {
                    throw "Attempt $($stageOffset + $index + 1) did not use the fallback read token."
                }
            }
            if ($global:ExistingPrSearchRequests[$stageOffset + 8].Headers.ContainsKey('Authorization')) {
                throw 'The final anonymous attempt sent a credential.'
            }
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

    It 'retries a transient GitHub Search 422 before continuing the duplicate check' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'primary-read-token'

        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                if ($global:ExistingPrSearchRequests.Count -lt 3) {
                    $unprocessableResponse = [System.Net.Http.HttpResponseMessage]::new(
                        [System.Net.HttpStatusCode]::UnprocessableEntity
                    )
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                        'GitHub Search could not process the query',
                        $unprocessableResponse
                    )
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
            throw 'The successful retry unexpectedly reported a duplicate.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 4) {
            throw "Expected three title-search attempts after transient HTTP 422 responses plus one manifest-path search, got $($global:ExistingPrSearchRequests.Count)."
        }
        if ($global:ExistingPrSearchSleeps.Count -ne 2 -or
            $global:ExistingPrSearchSleeps[0] -ne 1 -or
            $global:ExistingPrSearchSleeps[1] -ne 2) {
            throw "Expected retry delays of one and two seconds, got $($global:ExistingPrSearchSleeps -join ', ')."
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
                            title        = 'Update version: Test.PackagePro version 1.0.0'
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
        if ($global:ExistingPrSearchRequests.Count -ne 2) {
            throw "Duplicate detection performed $($global:ExistingPrSearchRequests.Count) requests instead of two (title search plus manifest-path search)."
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

    It 'detects community and custom title forms with bounded package and version tokens' {
        $titleMatches = InModuleScope WingetMaintainerModule {
            [pscustomobject]@{
                Community = Test-WingetPkgsExistingPrTitle `
                    -Title 'Community update: Test.Package v1.0.0' `
                    -PackageIdentifier 'Test.Package' `
                    -Version '1.0.0'
                Custom = Test-WingetPkgsExistingPrTitle `
                    -Title 'Bump Test.Package from 0.9.0 to 1.0.0' `
                    -PackageIdentifier 'Test.Package' `
                    -Version '1.0.0'
            }
        }

        if (-not $titleMatches.Community -or -not $titleMatches.Custom) {
            throw "Bounded package/version matching did not recognize custom title forms: $($titleMatches | ConvertTo-Json -Compress)"
        }
    }

    It 'ignores substring and tokenized title search candidates' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                if ($Uri -match '/pulls/\d+/files') {
                    return @(
                        [pscustomobject]@{ filename = 'manifests/t/Test/PackagePro/1.0.0/Test.PackagePro.installer.yaml' },
                        [pscustomobject]@{ filename = 'manifests/t/Test/Package/1.0.0.1/Test.Package.installer.yaml' }
                    )
                }
                return [pscustomobject]@{
                    total_count = 2
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.PackagePro version 1.0.0'
                            state        = 'open'
                            number       = 103
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/103'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        },
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0.1'
                            state        = 'open'
                            number       = 104
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

    It 'paginates the explicit test-fork search until it finds a matching open PR' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                $pageMatch = [regex]::Match(([uri] $Uri).Query, '(?:\?|&)page=(\d+)(?:&|$)')
                if (-not $pageMatch.Success) {
                    throw "The paginated request did not include a page number: $Uri"
                }
                $page = [int] $pageMatch.Groups[1].Value
                if ($page -eq 1) {
                    return [pscustomobject]@{
                        total_count = 101
                        items = @(
                            foreach ($index in 1..100) {
                                [pscustomobject]@{
                                    title        = "Update version: Test.Package version 2.0.$index"
                                    state        = 'open'
                                    html_url     = "https://github.com/damn-good-b0t/winget-pkgs/pull/$index"
                                    pull_request = [pscustomobject]@{ merged_at = $null }
                                }
                            }
                        )
                    }
                }

                return [pscustomobject]@{
                    total_count = 101
                    items = @(
                        [pscustomobject]@{
                            title        = 'Update version: Test.Package version 1.0.0'
                            state        = 'open'
                            html_url     = 'https://github.com/damn-good-b0t/winget-pkgs/pull/101'
                            pull_request = [pscustomobject]@{ merged_at = $null }
                        }
                    )
                }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'damn-good-b0t/winget-pkgs' `
            -OnlyOpen

        if ($result -ne $true) {
            throw 'The second page matching test-fork pull request was not found.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 2) {
            throw "Expected two paginated test-fork requests, got $($global:ExistingPrSearchRequests.Count)."
        }
        $firstUri = [uri] $global:ExistingPrSearchRequests[0].Uri
        $secondUri = [uri] $global:ExistingPrSearchRequests[1].Uri
        if ($firstUri.Query -notmatch 'page=1' -or $secondUri.Query -notmatch 'page=2' -or
            $global:ExistingPrSearchRequests[0].Uri -notmatch 'repo%3Adamn-good-b0t%2Fwinget-pkgs') {
            throw 'The test-fork search did not request the expected paginated repository scope.'
        }
    }

    It 'fails closed when GitHub Search reports incomplete results despite a complete page' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                return [pscustomobject]@{
                    incomplete_results = $true
                    total_count        = 1
                    items              = @(
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

        {
            Test-ExistingPRs `
                -PackageIdentifier 'Test.Package' `
                -Version '1.0.0' `
                -Repository 'microsoft/winget-pkgs'
        } | Should -Throw '*incomplete_results=true*'
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
        if ($global:ExistingPrSearchRequests.Count -ne 2) {
            throw "OnlyOpen performed $($global:ExistingPrSearchRequests.Count) search requests instead of two (title search plus manifest-path search)."
        }

        foreach ($request in $global:ExistingPrSearchRequests) {
            $query = [uri]::UnescapeDataString(([uri] $request.Uri).Query)
            if ($query -notmatch 'is:open' -or $query -match 'is:merged') {
                throw "OnlyOpen used an unexpected query: $query"
            }
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

    It 'detects an open PR by manifest path when the title omits the package identifier' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                if ($Uri -match '/pulls/555/files') {
                    return @(
                        [pscustomobject]@{ filename = 'manifests/t/Test/Package/1.0.0/Test.Package.installer.yaml' }
                    )
                }
                if ($Uri -match 'Test\.Package') {
                    # Title search: the human PR title omits the package identifier.
                    return [pscustomobject]@{ total_count = 0; items = @() }
                }
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Submitting Test Package 1.0.0'
                            state        = 'open'
                            number       = 555
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/555'
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
            throw 'An open PR touching the manifest path was not detected.'
        }

        $fileRequests = @($global:ExistingPrSearchRequests | Where-Object { $_.Uri -match '/pulls/555/files' })
        if ($fileRequests.Count -ne 1) {
            throw "Expected exactly one PR files read, got $($fileRequests.Count)."
        }
        $versionSearches = @($global:ExistingPrSearchRequests | Where-Object {
            $_.Uri -match 'search/issues' -and $_.Uri -notmatch 'Test\.Package'
        })
        if ($versionSearches.Count -ne 1) {
            throw "Expected exactly one manifest-path candidate search, got $($versionSearches.Count)."
        }
        $query = [uri]::UnescapeDataString(([uri] $versionSearches[0].Uri).Query)
        if ($query -notmatch 'is:open' -or $query -notmatch 'in:title "1\.0\.0"') {
            throw "The manifest-path candidate search used an unexpected query: $query"
        }
    }

    It 'does not treat a manifest-path candidate for a different version directory as a duplicate' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                if ($Uri -match '/pulls/556/files') {
                    return @(
                        [pscustomobject]@{ filename = 'manifests/t/Test/Package/1.0.0.1/Test.Package.installer.yaml' }
                    )
                }
                if ($Uri -match 'Test\.Package') {
                    return [pscustomobject]@{ total_count = 0; items = @() }
                }
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'Submitting Test Package 1.0.0'
                            state        = 'open'
                            number       = 556
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/556'
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
            throw 'A PR touching a different version directory was treated as a duplicate.'
        }
    }

    It 'skips manifest-path file reads for candidates that name another package' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                if ($Uri -match '/pulls/') {
                    throw 'The manifest-path check must not read files of PRs that name another package.'
                }
                if ($Uri -match 'Test\.Package') {
                    return [pscustomobject]@{ total_count = 0; items = @() }
                }
                return [pscustomobject]@{
                    total_count = 1
                    items = @(
                        [pscustomobject]@{
                            title        = 'New version: Other.Package version 1.0.0'
                            state        = 'open'
                            number       = 700
                            html_url     = 'https://github.com/microsoft/winget-pkgs/pull/700'
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
            throw 'A candidate naming another package changed the duplicate decision.'
        }
        if (@($global:ExistingPrSearchRequests | Where-Object { $_.Uri -match '/pulls/' }).Count -ne 0) {
            throw 'A candidate naming another package triggered a PR files read.'
        }
    }

    It 'builds manifest path prefixes and classifies other-package titles correctly' {
        $helperResults = InModuleScope WingetMaintainerModule {
            [pscustomobject]@{
                SimplePrefix   = Get-WingetPkgsManifestVersionPathPrefix -PackageIdentifier 'GodotLauncher.Launcher' -Version '1.11.1'
                MultiDotPrefix = Get-WingetPkgsManifestVersionPathPrefix -PackageIdentifier 'A.B.C' -Version '2.0'
                OtherPackage   = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'New version: heymaikol.NetworkDoctor 1.11.1' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                OwnPackage     = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Update GodotLauncher.Launcher to 1.11.1' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                VersionToken   = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Submitting Godot Launcher v1.11.1' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                FileNameToken  = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Add GodotLauncher setup.exe 1.11.1' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                DomainToken    = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Submitting Godot Launcher 1.11.1 from godotlauncher.org' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                UrlToken       = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Add Godot Launcher 1.11.1 (see https://downloads.example.gallery/godot.launcher.portable)' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                OtherIdToken   = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'New version: Contoso.OtherApp 2.0' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
                PureVersions   = Test-WingetPkgsTitleNamesOtherPackage `
                    -Title 'Bump Godot Launcher from 1.10.2 to 1.11.1' `
                    -PackageIdentifier 'GodotLauncher.Launcher' `
                    -Version '1.11.1'
            }
        }

        if ($helperResults.SimplePrefix -cne 'manifests/g/GodotLauncher/Launcher/1.11.1/') {
            throw "Unexpected manifest path prefix: $($helperResults.SimplePrefix)"
        }
        if ($helperResults.MultiDotPrefix -cne 'manifests/a/A/B/C/2.0/') {
            throw "Unexpected multi-dot manifest path prefix: $($helperResults.MultiDotPrefix)"
        }
        if (-not $helperResults.OtherPackage) {
            throw 'A title naming another package identifier was not classified as such.'
        }
        if ($helperResults.OwnPackage) {
            throw 'A title naming the requested package identifier was misclassified as another package.'
        }
        if ($helperResults.VersionToken) {
            throw 'A version-like dotted token was misclassified as another package identifier.'
        }
        if ($helperResults.FileNameToken) {
            throw 'A file-name token (setup.exe) was misclassified as another package identifier.'
        }
        if ($helperResults.DomainToken) {
            throw 'A domain-like token was misclassified as another package identifier.'
        }
        if ($helperResults.UrlToken) {
            throw 'A URL-embedded token was misclassified as another package identifier.'
        }
        if (-not $helperResults.OtherIdToken) {
            throw 'A title naming a genuinely different package identifier was not classified as such.'
        }
        if ($helperResults.PureVersions) {
            throw 'Pure version tokens were misclassified as another package identifier.'
        }
    }
}
