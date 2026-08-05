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
        $global:OriginalForkRepository = $env:WINGET_PKGS_FORK_REPO
        $env:WINGET_PKGS_FORK_REPO = 'test-owner/winget-pkgs'

        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs { $false }
            Mock Get-WingetPkgsPrUrl { $null }
            Mock Invoke-WingetPkgsGitHubApi {
                param($Method, $Path, $Token, $Body)

                $global:ForkBranchSubmissionRequests.Add([pscustomobject]@{
                    Method = $Method
                    Path   = $Path
                    Body   = $Body
                })

                switch -Regex ($Path) {
                    '^repos/test-owner/winget-pkgs$' {
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
        Remove-Variable -Name OriginalForkRepository -Scope Global -ErrorAction SilentlyContinue
    }

    It 'creates an upstream PR from a fork branch without writing the fork default branch' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -SubmissionTarget Upstream

        if ($result.Success -ne $true) {
            throw "Expected a successful upstream ForkBranch submission, got: $($result.Error)"
        }
        if ($result.PrUrl -cne 'https://github.com/microsoft/winget-pkgs/pull/12345') {
            throw "Unexpected upstream PR URL: $($result.PrUrl)"
        }
        if ($result.PrNumber -cne '12345') {
            throw "Unexpected upstream PR number: $($result.PrNumber)"
        }

        $forkWrites = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Path -match '^repos/test-owner/winget-pkgs/' -and
                    $_.Method -in @('Post', 'Patch', 'Delete')
                }
        )
        foreach ($expectedPath in @(
            'repos/test-owner/winget-pkgs/git/trees',
            'repos/test-owner/winget-pkgs/git/commits',
            'repos/test-owner/winget-pkgs/git/refs'
        )) {
            if ($forkWrites.Path -notcontains $expectedPath) {
                throw "Expected fork write was not made: $expectedPath"
            }
        }
        if (@($forkWrites | Where-Object { $_.Path -match 'merge-upstream|refs/heads/master' }).Count -ne 0) {
            throw 'ForkBranch wrote or synchronized the fork default branch.'
        }
        $treeRequest = $forkWrites | Where-Object { $_.Path -eq 'repos/test-owner/winget-pkgs/git/trees' }
        if ($treeRequest.Body.base_tree -cne 'base-tree-sha') {
            throw "ForkBranch did not base the manifest tree on the resolved base tree: $($treeRequest.Body.base_tree)"
        }

        $upstreamWrites = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Path -match '^repos/microsoft/winget-pkgs/' -and
                    $_.Method -in @('Post', 'Patch', 'Delete')
                }
        )
        if ($upstreamWrites.Count -ne 1 -or $upstreamWrites[0].Path -cne 'repos/microsoft/winget-pkgs/pulls') {
            throw "Upstream write surface is not limited to creating the intended PR: $($upstreamWrites.Path -join ', ')"
        }
    }

    It 'keeps Fork test submissions entirely within the verified user fork' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -SubmissionTarget Fork

        if ($result.Success -ne $true) {
            throw "Expected a successful fork-only ForkBranch submission, got: $($result.Error)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -match 'microsoft/winget-pkgs' }).Count -ne 0) {
            throw 'Fork test submission called the Microsoft repository API.'
        }

        $pullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Path -eq 'repos/test-owner/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($pullRequest.Body.base -cne 'master') {
            throw "Fork test submission used an unexpected base branch: $($pullRequest.Body.base)"
        }
        if ($pullRequest.Body.head -notmatch '^test-owner:winget-autosubmit/') {
            throw "Fork test submission used an unexpected PR head: $($pullRequest.Body.head)"
        }
    }

    It 'does not create a fork branch when the matching target PR already exists' {
        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs { $true }
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
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'Duplicate detection attempted a fork API request.'
        }
        InModuleScope WingetMaintainerModule {
            Assert-MockCalled Invoke-WingetPkgsGitHubApi -Times 0 -Exactly -Scope It
        }
    }

    It 'rejects microsoft/winget-pkgs as the configured fork before writing a branch' {
        $env:WINGET_PKGS_FORK_REPO = 'microsoft/winget-pkgs'

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $false) {
            throw 'A microsoft/winget-pkgs fork configuration unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'user-owned fork') {
            throw "The unsafe fork configuration was not identified clearly: $($result.Error)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Method -in @('Post', 'Patch', 'Delete') }).Count -ne 0) {
            throw 'An unsafe fork configuration attempted a GitHub write.'
        }
    }
}
