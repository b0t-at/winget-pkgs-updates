$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

Describe 'Submit-WingetPackage ForkBranch' {
    BeforeEach {
        $global:ForkBranchSubmissionManifestPath = Join-Path ([IO.Path]::GetTempPath()) "winget-fork-submit-tests-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $global:ForkBranchSubmissionManifestPath -Force | Out-Null
        @(
            'PackageIdentifier: Test.Package',
            'PackageVersion: 1.0.0'
        ) | Set-Content -LiteralPath (Join-Path $global:ForkBranchSubmissionManifestPath 'Test.Package.yaml')

        $global:ForkBranchSubmissionRequests = [System.Collections.Generic.List[object]]::new()
        $global:ForkBranchDuplicateRepositories = [System.Collections.Generic.List[string]]::new()
        $global:OriginalForkRepository = $env:WINGET_PKGS_FORK_REPO
        $env:WINGET_PKGS_FORK_REPO = 'damn-good-b0t/winget-pkgs'

        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs {
                param($PackageIdentifier, $Version, $Repository)

                $global:ForkBranchDuplicateRepositories.Add($Repository)
                return $false
            }
            Mock Get-WingetPkgsPrUrl { $null }
            Mock Invoke-WingetPkgsGitHubApi {
                param($Method, $Path, $Token, $Unauthenticated, $Body)

                $global:ForkBranchSubmissionRequests.Add([pscustomobject]@{
                    Method          = $Method
                    Path            = $Path
                    Unauthenticated = [bool] $Unauthenticated
                    Body            = $Body
                })

                switch -Regex ($Path) {
                    '^repos/damn-good-b0t/winget-pkgs$' {
                        return [pscustomobject]@{
                            fork           = $true
                            default_branch = 'master'
                            parent         = [pscustomobject]@{ full_name = 'microsoft/winget-pkgs' }
                        }
                    }
                    '^repos/microsoft/winget-pkgs$' {
                        return [pscustomobject]@{ default_branch = 'master' }
                    }
                    '/git/ref/heads/master$' {
                        return [pscustomobject]@{ object = [pscustomobject]@{ sha = 'base-sha' } }
                    }
                    '/git/commits/base-sha$' {
                        return [pscustomobject]@{ tree = [pscustomobject]@{ sha = 'base-tree-sha' } }
                    }
                    '/git/trees$' {
                        return [pscustomobject]@{ sha = 'tree-sha' }
                    }
                    '/git/commits$' {
                        return [pscustomobject]@{ sha = 'commit-sha' }
                    }
                    '/git/refs$' {
                        return [pscustomobject]@{ ref = 'refs/heads/winget-autosubmit/test' }
                    }
                    '/pulls$' {
                        return [pscustomobject]@{
                            html_url = 'https://github.com/microsoft/winget-pkgs/pull/12345'
                            number   = 12345
                        }
                    }
                    default {
                        throw "Unexpected GitHub API request: $Method $Path"
                    }
                }
            }
        }
    }

    AfterEach {
        Remove-Item -LiteralPath $global:ForkBranchSubmissionManifestPath -Recurse -Force -ErrorAction SilentlyContinue
        $env:WINGET_PKGS_FORK_REPO = $global:OriginalForkRepository
        Remove-Variable -Name ForkBranchSubmissionManifestPath -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchSubmissionRequests -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchDuplicateRepositories -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalForkRepository -Scope Global -ErrorAction SilentlyContinue
    }

    It 'rejects a fork-only ForkBranch target before querying GitHub' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -SubmissionTarget Fork

        if ($result.Success -ne $false) {
            throw "Expected a fork-only ForkBranch submission to fail, got: $($result | ConvertTo-Json -Compress)"
        }
        if ($result.Error -notmatch 'restricted to the Upstream target') {
            throw "The fork-only rejection was not explained clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'A fork-only ForkBranch target queried or wrote a GitHub repository.'
        }
    }

    It 'creates cross-repository PRs from the configured verified fork' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $true) {
            throw "Expected a successful fork-only ForkBranch submission, got: $($result.Error)"
        }
        if ($global:ForkBranchDuplicateRepositories.Count -ne 2 -or @($global:ForkBranchDuplicateRepositories | Where-Object { $_ -cne 'microsoft/winget-pkgs' }).Count -ne 0) {
            throw "Fork submission did not perform duplicate checks against the upstream target: $($global:ForkBranchDuplicateRepositories -join ', ')"
        }
        $upstreamReads = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/microsoft/winget-pkgs($|/)' -and $_.Method -eq 'Get' }
        )
        if ($upstreamReads.Count -ne 3 -or @($upstreamReads | Where-Object { -not $_.Unauthenticated }).Count -ne 0) {
            throw "Upstream base reads must be unauthenticated: $($upstreamReads | ConvertTo-Json -Compress)"
        }

        $forkWrites = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Path -match '^repos/damn-good-b0t/winget-pkgs/' -and
                    $_.Method -in @('Post', 'Patch', 'Delete')
                }
        )
        foreach ($expectedPath in @(
            'repos/damn-good-b0t/winget-pkgs/git/trees',
            'repos/damn-good-b0t/winget-pkgs/git/commits',
            'repos/damn-good-b0t/winget-pkgs/git/refs'
        )) {
            if ($forkWrites.Path -notcontains $expectedPath) {
                throw "Expected fork write was not made: $expectedPath"
            }
        }
        if (@($forkWrites | Where-Object { $_.Path -match 'merge-upstream|refs/heads/master' }).Count -ne 0) {
            throw 'ForkBranch wrote or synchronized the fork default branch.'
        }
        $treeRequest = $forkWrites | Where-Object { $_.Path -eq 'repos/damn-good-b0t/winget-pkgs/git/trees' }
        if ($treeRequest.Body.base_tree -cne 'base-tree-sha') {
            throw "ForkBranch did not base the manifest tree on the resolved base tree: $($treeRequest.Body.base_tree)"
        }

        $pullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Path -eq 'repos/microsoft/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($null -eq $pullRequest -or $pullRequest.Method -ne 'Post') {
            throw 'ForkBranch did not create the expected upstream pull request.'
        }
        if ($pullRequest.Body.base -cne 'master') {
            throw "ForkBranch used an unexpected upstream base branch: $($pullRequest.Body.base)"
        }
        if ($pullRequest.Body.head -notmatch '^damn-good-b0t:winget-autosubmit/') {
            throw "ForkBranch used an unexpected cross-repository PR head: $($pullRequest.Body.head)"
        }
        $upstreamWrites = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/microsoft/winget-pkgs/' -and $_.Method -in @('Post', 'Patch', 'Delete') }
        )
        if ($upstreamWrites.Count -ne 1 -or $upstreamWrites[0].Path -cne 'repos/microsoft/winget-pkgs/pulls') {
            throw "Upstream write surface is not limited to creating the intended pull request: $($upstreamWrites.Path -join ', ')"
        }
    }

    It 'does not create a fork branch when the matching target PR already exists' {
        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs {
                param($PackageIdentifier, $Version, $Repository)

                $global:ForkBranchDuplicateRepositories.Add($Repository)
                return $true
            }
            Mock Get-WingetPkgsPrUrl { 'https://github.com/microsoft/winget-pkgs/pull/54321' }
        }

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $true -or $result.PrUrl -cne 'https://github.com/microsoft/winget-pkgs/pull/54321') {
            throw "Existing submission PR was not returned: $($result | ConvertTo-Json -Compress)"
        }
        if ($global:ForkBranchDuplicateRepositories.Count -ne 1 -or $global:ForkBranchDuplicateRepositories[0] -cne 'microsoft/winget-pkgs') {
            throw "Duplicate detection did not use the upstream target: $($global:ForkBranchDuplicateRepositories -join ', ')"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'Duplicate detection attempted a fork API request.'
        }
    }

    It 'rejects a configured repository that is not a winget-pkgs fork before writing' {
        InModuleScope WingetMaintainerModule {
            Mock Invoke-WingetPkgsGitHubApi {
                param($Method, $Path, $Token, $Unauthenticated, $Body)

                $global:ForkBranchSubmissionRequests.Add([pscustomobject]@{
                    Method          = $Method
                    Path            = $Path
                    Unauthenticated = [bool] $Unauthenticated
                    Body            = $Body
                })
                return [pscustomobject]@{
                    fork           = $false
                    default_branch = 'master'
                    parent         = [pscustomobject]@{ full_name = 'unrelated/repository' }
                }
            }
        }

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $false) {
            throw 'A repository that is not a fork unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'is not a fork of microsoft/winget-pkgs') {
            throw "The invalid fork topology was not identified clearly: $($result.Error)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Method -in @('Post', 'Patch', 'Delete') }).Count -ne 0) {
            throw 'An invalid fork topology attempted a GitHub write.'
        }
    }

    It 'rejects microsoft/winget-pkgs as the configured fork before querying GitHub' {
        $env:WINGET_PKGS_FORK_REPO = 'microsoft/winget-pkgs'

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $false) {
            throw 'The Microsoft repository configuration unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'user-owned fork') {
            throw "The unsafe fork configuration was not identified clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'The Microsoft repository configuration queried or wrote a GitHub repository.'
        }
        if ($global:ForkBranchDuplicateRepositories.Count -ne 0) {
            throw 'The Microsoft repository configuration performed duplicate detection.'
        }
    }

    It 'fails closed when the required safe fork configuration is absent' {
        $env:WINGET_PKGS_FORK_REPO = ''

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $false) {
            throw 'A missing fork configuration unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'WINGET_PKGS_FORK_REPO is required') {
            throw "The missing fork configuration was not identified clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'A missing fork configuration queried or wrote a GitHub repository.'
        }
    }
}
