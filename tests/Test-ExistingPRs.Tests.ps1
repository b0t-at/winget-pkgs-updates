$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Test-ExistingPRs' {
    BeforeEach {
        $global:ExistingPrSearchRequests = [System.Collections.Generic.List[object]]::new()
        $global:OriginalUpstreamReadToken = $env:WINGET_UPSTREAM_READ_TOKEN
        $global:OriginalGitHubToken = $env:GITHUB_TOKEN
        $global:OriginalWingetPat = $env:WINGET_PAT
        $env:WINGET_UPSTREAM_READ_TOKEN = ''
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
                    items = @(
                        [pscustomobject]@{
                            title    = 'Update version: Test.Package version 1.0.0'
                            html_url = 'https://github.com/microsoft/winget-pkgs/pull/12345'
                        }
                    )
                }
            }
        }
    }

    AfterEach {
        $env:WINGET_UPSTREAM_READ_TOKEN = $global:OriginalUpstreamReadToken
        $env:GITHUB_TOKEN = $global:OriginalGitHubToken
        $env:WINGET_PAT = $global:OriginalWingetPat
        Remove-Variable -Name ExistingPrSearchRequests -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalUpstreamReadToken -Scope Global -ErrorAction SilentlyContinue
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
        if ($query -notmatch 'repo:microsoft/winget-pkgs' -or $query -notmatch '\(is:open OR is:merged\)' -or $query -notmatch 'Test.Package 1.0.0') {
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

    It 'checks open and merged pull requests in one upstream request' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $ErrorAction)

                $global:ExistingPrSearchRequests.Add([pscustomobject]@{
                    Method  = $Method
                    Uri     = $Uri
                    Headers = $Headers
                })
                return [pscustomobject]@{ items = @() }
            }
        }

        $result = Test-ExistingPRs `
            -PackageIdentifier 'Test.Package' `
            -Version '1.0.0' `
            -Repository 'microsoft/winget-pkgs'

        if ($result -ne $false) {
            throw 'An empty upstream PR search unexpectedly found a match.'
        }
        if ($global:ExistingPrSearchRequests.Count -ne 1) {
            throw "Open and merged duplicate detection performed $($global:ExistingPrSearchRequests.Count) requests instead of one."
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
                return [pscustomobject]@{ items = @() }
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
}
