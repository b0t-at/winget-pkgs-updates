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
        $env:WINGET_PKGS_FORK_REPO = 'Utesgui/winget-pkgs'

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
                    '^repos/Utesgui/winget-pkgs$' {
                        return [pscustomobject]@{
                            fork           = $true
                            default_branch = 'master'
                            parent         = [pscustomobject]@{ full_name = 'microsoft/winget-pkgs' }
                        }
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
                            html_url = 'https://github.com/Utesgui/winget-pkgs/pull/12345'
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

    It 'rejects an upstream ForkBranch target before querying GitHub' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -SubmissionTarget Upstream

        if ($result.Success -ne $false) {
            throw "Expected an upstream ForkBranch submission to fail, got: $($result | ConvertTo-Json -Compress)"
        }
        if ($result.Error -notmatch 'restricted to the Fork target') {
            throw "The upstream rejection was not explained clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'An upstream ForkBranch target queried or wrote a GitHub repository.'
        }
    }

    It 'keeps Fork submissions entirely within the verified Utesgui fork' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $true) {
            throw "Expected a successful fork-only ForkBranch submission, got: $($result.Error)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -match 'microsoft/winget-pkgs' }).Count -ne 0) {
            throw 'Fork submission called the Microsoft repository API.'
        }

        $forkWrites = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Path -match '^repos/Utesgui/winget-pkgs/' -and
                    $_.Method -in @('Post', 'Patch', 'Delete')
                }
        )
        foreach ($expectedPath in @(
            'repos/Utesgui/winget-pkgs/git/trees',
            'repos/Utesgui/winget-pkgs/git/commits',
            'repos/Utesgui/winget-pkgs/git/refs',
            'repos/Utesgui/winget-pkgs/pulls'
        )) {
            if ($forkWrites.Path -notcontains $expectedPath) {
                throw "Expected fork write was not made: $expectedPath"
            }
        }
        if (@($forkWrites | Where-Object { $_.Path -match 'merge-upstream|refs/heads/master' }).Count -ne 0) {
            throw 'ForkBranch wrote or synchronized the fork default branch.'
        }
        $treeRequest = $forkWrites | Where-Object { $_.Path -eq 'repos/Utesgui/winget-pkgs/git/trees' }
        if ($treeRequest.Body.base_tree -cne 'base-tree-sha') {
            throw "ForkBranch did not base the manifest tree on the resolved base tree: $($treeRequest.Body.base_tree)"
        }

        $pullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Path -eq 'repos/Utesgui/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($pullRequest.Body.base -cne 'master') {
            throw "Fork test submission used an unexpected base branch: $($pullRequest.Body.base)"
        }
        if ($pullRequest.Body.head -notmatch '^Utesgui:winget-autosubmit/') {
            throw "Fork test submission used an unexpected PR head: $($pullRequest.Body.head)"
        }
    }

    It 'does not create a fork branch when the matching target PR already exists' {
        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs { $true }
            Mock Get-WingetPkgsPrUrl { 'https://github.com/Utesgui/winget-pkgs/pull/54321' }
        }

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $true -or $result.PrUrl -cne 'https://github.com/Utesgui/winget-pkgs/pull/54321') {
            throw "Existing submission PR was not returned: $($result | ConvertTo-Json -Compress)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'Duplicate detection attempted a fork API request.'
        }
    }

    It 'rejects an unapproved fork configuration before querying GitHub' {
        $env:WINGET_PKGS_FORK_REPO = 'damn-good-b0t/winget-pkgs'

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch

        if ($result.Success -ne $false) {
            throw 'An unapproved fork configuration unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'must be configured as Utesgui/winget-pkgs') {
            throw "The unsafe fork configuration was not identified clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'An unapproved fork configuration queried or wrote a GitHub repository.'
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
