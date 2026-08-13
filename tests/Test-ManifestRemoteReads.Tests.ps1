$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Test-WingetManifestContent remote reads' {
    BeforeEach {
        $global:ManifestReadRequests = [System.Collections.Generic.List[object]]::new()
        $global:OriginalManifestReadToken = $env:WINGET_PKGS_GITHUB_TOKEN
        $global:OriginalManifestGitHubToken = $env:GITHUB_TOKEN
        $global:ManifestReadPublishedInstaller = @'
PackageIdentifier: Test.BatchReads
PackageVersion: 1.0.0
InstallerType: nullsoft
Installers:
- Architecture: x64
  InstallerUrl: https://example.invalid/test-1.0.0.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
ManifestType: installer
ManifestVersion: 1.12.0
'@
        $global:ManifestReadPublishedSingleton = @'
PackageIdentifier: Test.BatchReads
PackageVersion: 1.0.0
PackageLocale: en-US
Publisher: Test
PackageName: Batch Reads
License: MIT
ShortDescription: Test package
InstallerType: nullsoft
Installers:
- Architecture: x64
  InstallerUrl: https://example.invalid/test-1.0.0.exe
  InstallerSha256: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
ManifestType: singleton
ManifestVersion: 1.12.0
'@
        $global:ManifestReadGraphQlInstaller = $global:ManifestReadPublishedInstaller
        $global:ManifestReadGraphQlBase = $null
        $global:ManifestReadFallbackName = 'Test.BatchReads.installer.yaml'
        $global:ManifestReadFallbackContent = $global:ManifestReadPublishedInstaller
        $env:WINGET_PKGS_GITHUB_TOKEN = 'primary-read-token'
        $env:GITHUB_TOKEN = ''
        $global:ManifestReadRoot = Join-Path ([IO.Path]::GetTempPath()) "winget-remote-read-test-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:ManifestReadRoot -Force | Out-Null

        $localInstallerContent = "PackageIdentifier: Test.BatchReads`r`nPackageVersion: 2.0.0`r`nInstallerType: nullsoft`r`nInstallers:`r`n- Architecture: x64`r`n  InstallerUrl: https://example.invalid/test-2.0.0.exe`r`n  InstallerSha256: BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB`r`nManifestType: installer`r`nManifestVersion: 1.12.0`r`n"
        [System.IO.File]::WriteAllBytes((Join-Path $global:ManifestReadRoot 'Test.BatchReads.installer.yaml'), [System.Text.Encoding]::UTF8.GetBytes($localInstallerContent))

        $localVersionContent = "PackageIdentifier: Test.BatchReads`r`nPackageVersion: 2.0.0`r`nDefaultLocale: en-US`r`nManifestType: version`r`nManifestVersion: 1.12.0`r`n"
        [System.IO.File]::WriteAllBytes((Join-Path $global:ManifestReadRoot 'Test.BatchReads.yaml'), [System.Text.Encoding]::UTF8.GetBytes($localVersionContent))

        InModuleScope WingetMaintainerModule {
            Mock Invoke-WebRequest {
                throw 'Published manifests must not be downloaded from raw.githubusercontent.com.'
            }

            Mock Invoke-RestMethod {
                param($Uri, $Headers, $Method, $ContentType, $Body, $ErrorAction)

                $global:ManifestReadRequests.Add([pscustomobject]@{
                        Uri = [string]$Uri
                        Headers = $Headers
                        Method = [string]$Method
                        ContentType = [string]$ContentType
                        Body = [string]$Body
                    })

                if ([string]$Uri -eq 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/Test/BatchReads') {
                    return [pscustomobject]@{
                        type = 'dir'
                        name = '1.0.0'
                        path = 'manifests/t/Test/BatchReads/1.0.0'
                        url = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/Test/BatchReads/1.0.0'
                    }
                }

                if ([string]$Uri -eq 'https://api.github.com/graphql') {
                    return [pscustomobject]@{
                        data = [pscustomobject]@{
                            repository = [pscustomobject]@{
                                installer0 = if ($null -eq $global:ManifestReadGraphQlInstaller) {
                                    $null
                                } else {
                                    [pscustomobject]@{ text = $global:ManifestReadGraphQlInstaller }
                                }
                                base0 = if ($null -eq $global:ManifestReadGraphQlBase) {
                                    $null
                                } else {
                                    [pscustomobject]@{ text = $global:ManifestReadGraphQlBase }
                                }
                            }
                        }
                    }
                }

                if ([string]$Uri -eq 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/Test/BatchReads/1.0.0') {
                    return [pscustomobject]@{
                        type = 'file'
                        name = $global:ManifestReadFallbackName
                        path = "manifests/t/Test/BatchReads/1.0.0/$($global:ManifestReadFallbackName)"
                        url = 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/Test/BatchReads/1.0.0/published'
                        download_url = 'https://raw.githubusercontent.com/microsoft/winget-pkgs/master/forbidden.yaml'
                    }
                }

                if ([string]$Uri -eq 'https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/t/Test/BatchReads/1.0.0/published') {
                    return [pscustomobject]@{
                        encoding = 'base64'
                        content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($global:ManifestReadFallbackContent))
                    }
                }

                throw "Unexpected GitHub request: $Method $Uri"
            }
        }
    }

    AfterEach {
        $env:WINGET_PKGS_GITHUB_TOKEN = $global:OriginalManifestReadToken
        $env:GITHUB_TOKEN = $global:OriginalManifestGitHubToken
        if (Test-Path -LiteralPath $global:ManifestReadRoot) {
            Remove-Item -LiteralPath $global:ManifestReadRoot -Recurse -Force
        }
        Remove-Variable -Name ManifestReadRequests -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalManifestReadToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalManifestGitHubToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadPublishedInstaller -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadPublishedSingleton -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadGraphQlInstaller -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadGraphQlBase -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadFallbackName -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadFallbackContent -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ManifestReadRoot -Scope Global -ErrorAction SilentlyContinue
    }

    It 'batches authenticated published manifests through the GitHub API' {
        $result = InModuleScope WingetMaintainerModule -Parameters @{ ManifestPath = $global:ManifestReadRoot } {
            param($ManifestPath)
            Test-WingetManifestContent -ManifestPath $ManifestPath
        }

        if (-not $result.Valid) {
            throw "Expected remote published comparison to pass: $($result.Errors -join '; ')"
        }
        if ($global:ManifestReadRequests.Count -ne 2) {
            throw "Expected one contents request and one batched GraphQL request, got $($global:ManifestReadRequests.Count)."
        }

        $graphqlRequest = $global:ManifestReadRequests | Where-Object Uri -eq 'https://api.github.com/graphql' | Select-Object -First 1
        if ($null -eq $graphqlRequest -or $graphqlRequest.Method -cne 'Post') {
            throw 'Published manifests were not read through a batched GitHub GraphQL request.'
        }
        if ($graphqlRequest.Headers.Authorization -notlike '*primary-read-token') {
            throw 'The batched manifest request did not use the configured read token.'
        }
        if ($graphqlRequest.Body -notmatch 'Test\.BatchReads\.installer\.yaml' -or
            $graphqlRequest.Body -notmatch 'Test\.BatchReads\.yaml') {
            throw "The GraphQL request did not include both installer and singleton candidates: $($graphqlRequest.Body)"
        }
        if (@($global:ManifestReadRequests | Where-Object Uri -NotLike 'https://api.github.com/*').Count -ne 0) {
            throw 'Published manifest comparison made a request outside the authenticated GitHub API.'
        }
    }

    It 'supports published singleton manifests in the batched request' {
        $global:ManifestReadGraphQlInstaller = $null
        $global:ManifestReadGraphQlBase = $global:ManifestReadPublishedSingleton

        $result = InModuleScope WingetMaintainerModule -Parameters @{ ManifestPath = $global:ManifestReadRoot } {
            param($ManifestPath)
            Test-WingetManifestContent -ManifestPath $ManifestPath
        }

        if (-not $result.Valid) {
            throw "Expected singleton published comparison to pass: $($result.Errors -join '; ')"
        }
        if ($global:ManifestReadRequests.Count -ne 2) {
            throw "Expected singleton comparison to remain batched into two API requests, got $($global:ManifestReadRequests.Count)."
        }
    }

    It 'uses API content instead of raw downloads when no token is available' {
        $env:WINGET_PKGS_GITHUB_TOKEN = ''
        $env:GITHUB_TOKEN = ''

        $result = InModuleScope WingetMaintainerModule -Parameters @{ ManifestPath = $global:ManifestReadRoot } {
            param($ManifestPath)
            Test-WingetManifestContent -ManifestPath $ManifestPath
        }

        if (-not $result.Valid) {
            throw "Expected unauthenticated API fallback comparison to pass: $($result.Errors -join '; ')"
        }
        if ($global:ManifestReadRequests.Count -ne 3) {
            throw "Expected contents listing and API content requests, got $($global:ManifestReadRequests.Count)."
        }
        if (@($global:ManifestReadRequests | Where-Object Uri -Like 'https://raw.githubusercontent.com/*').Count -ne 0) {
            throw 'The unauthenticated fallback used raw.githubusercontent.com.'
        }
        if (@($global:ManifestReadRequests | Where-Object { $_.Headers.ContainsKey('Authorization') }).Count -ne 0) {
            throw 'The unauthenticated fallback unexpectedly sent an Authorization header.'
        }
    }
}
