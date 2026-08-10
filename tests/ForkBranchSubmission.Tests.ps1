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
        $global:ForkBranchPrUrlRepositories = [System.Collections.Generic.List[string]]::new()
        $global:ForkBranchUpstreamReadFailTokens = @()
        $global:OriginalForkRepository = $env:WINGET_PKGS_FORK_REPO
        $global:OriginalUpstreamReadToken = $env:WINGET_UPSTREAM_READ_TOKEN
        $global:OriginalUpstreamReadFallbackToken = $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN
        $env:WINGET_PKGS_FORK_REPO = 'damn-good-b0t/winget-pkgs'
        $env:WINGET_UPSTREAM_READ_TOKEN = ''
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = ''

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
                    Token           = $Token
                    Unauthenticated = [bool] $Unauthenticated
                    Body            = $Body
                })

                if ($Method -eq 'Get' -and
                    $Path -match '^repos/microsoft/winget-pkgs($|/)' -and
                    $global:ForkBranchUpstreamReadFailTokens -ccontains $Token) {
                    $rateLimitedResponse = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
                    throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('API rate limit exceeded', $rateLimitedResponse)
                }

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
                            html_url = "https://github.com/$($Path.Substring(6, $Path.Length - 12))/pull/12345"
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
        $env:WINGET_UPSTREAM_READ_TOKEN = $global:OriginalUpstreamReadToken
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = $global:OriginalUpstreamReadFallbackToken
        Remove-Variable -Name ForkBranchSubmissionManifestPath -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchSubmissionRequests -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchDuplicateRepositories -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchPrUrlRepositories -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name ForkBranchUpstreamReadFailTokens -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalForkRepository -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalUpstreamReadToken -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name OriginalUpstreamReadFallbackToken -Scope Global -ErrorAction SilentlyContinue
    }

    It 'rejects a pull request target in the source fork before querying GitHub' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -SubmissionTarget Fork

        if ($result.Success -ne $false) {
            throw "Expected a source-fork PR target to fail, got: $($result | ConvertTo-Json -Compress)"
        }
        if ($result.Error -notmatch 'restricted to the Upstream target') {
            throw "The fork-only rejection was not explained clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'A source-fork PR target queried or wrote a GitHub repository.'
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
            throw "Expected a successful cross-repository ForkBranch submission, got: $($result.Error)"
        }
        if ($global:ForkBranchDuplicateRepositories.Count -ne 2 -or
            @($global:ForkBranchDuplicateRepositories | Where-Object { $_ -cne 'microsoft/winget-pkgs' }).Count -ne 0) {
            throw "Fork submission did not perform preflight and final duplicate checks against the upstream target: $($global:ForkBranchDuplicateRepositories -join ', ')"
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
        $branchClaim = $forkWrites |
            Where-Object { $_.Path -eq 'repos/damn-good-b0t/winget-pkgs/git/refs' -and $_.Method -eq 'Post' } |
            Select-Object -Last 1
        if ($null -eq $branchClaim -or $branchClaim.Body.ref -notmatch '^refs/heads/winget-autosubmit/test\.package-1\.0\.0-[a-f0-9]{16}$') {
            throw "ForkBranch did not create the deterministic package/version claim ref: $($branchClaim | ConvertTo-Json -Compress)"
        }
        if ($branchClaim.Body.sha -cne 'commit-sha') {
            throw "ForkBranch did not claim the manifest commit: $($branchClaim.Body.sha)"
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

    It 'creates an explicitly targeted pull request only in the configured test fork' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -Repository 'damn-good-b0t/winget-pkgs'

        if ($result.Success -ne $true -or $result.PrUrl -cne 'https://github.com/damn-good-b0t/winget-pkgs/pull/12345') {
            throw "Expected a successful test-fork submission, got: $($result | ConvertTo-Json -Compress)"
        }
        if (@($global:ForkBranchDuplicateRepositories | Where-Object { $_ -cne 'damn-good-b0t/winget-pkgs' }).Count -ne 0) {
            throw "Test-fork duplicate detection queried another repository: $($global:ForkBranchDuplicateRepositories -join ', ')"
        }

        $testForkPullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Method -eq 'Post' -and $_.Path -eq 'repos/damn-good-b0t/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($null -eq $testForkPullRequest) {
            throw 'The explicit test-fork target did not receive the pull request write.'
        }
        if ($testForkPullRequest.Body.head -match ':') {
            throw "A same-repository test-fork PR must use its local branch name, got: $($testForkPullRequest.Body.head)"
        }
        if ($testForkPullRequest.Body.base -cne 'master') {
            throw "The test-fork PR used an unexpected base branch: $($testForkPullRequest.Body.base)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -match '^repos/microsoft/winget-pkgs($|/)' }).Count -ne 0) {
            throw "The explicit test-fork route touched the production repository: $($global:ForkBranchSubmissionRequests | ConvertTo-Json -Compress)"
        }
    }

    It 'rejects an unconfigured ForkBranch target before querying GitHub' {
        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'test-token' `
            -With ForkBranch `
            -Repository 'untrusted/example'

        if ($result.Success -ne $false) {
            throw 'An unconfigured ForkBranch target unexpectedly succeeded.'
        }
        if ($result.Error -notmatch 'configured fork') {
            throw "The unconfigured target was not identified clearly: $($result.Error)"
        }
        if ($global:ForkBranchSubmissionRequests.Count -ne 0) {
            throw 'An unconfigured ForkBranch target queried or wrote GitHub.'
        }
    }

    It 'uses a dedicated token only for upstream base reads' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'upstream-read-token'

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'fork-write-token' `
            -With ForkBranch

        if ($result.Success -ne $true) {
            throw "Expected a successful ForkBranch submission, got: $($result.Error)"
        }
        $upstreamReads = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/microsoft/winget-pkgs($|/)' -and $_.Method -eq 'Get' }
        )
        if ($upstreamReads.Count -ne 3 -or @($upstreamReads | Where-Object { $_.Unauthenticated -or $_.Token -cne 'upstream-read-token' }).Count -ne 0) {
            throw "Upstream base reads did not exclusively use the dedicated token: $($upstreamReads | ConvertTo-Json -Compress)"
        }

        $forkRequests = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/damn-good-b0t/winget-pkgs($|/)' }
        )
        if (@($forkRequests | Where-Object { $_.Token -cne 'fork-write-token' }).Count -ne 0) {
            throw "A fork operation used the upstream read token: $($forkRequests | ConvertTo-Json -Compress)"
        }
        $pullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Path -eq 'repos/microsoft/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($null -eq $pullRequest -or $pullRequest.Token -cne 'fork-write-token') {
            throw 'The upstream PR creation did not retain the fork submission token.'
        }
    }

    It 'fails over to the fallback read token when the primary upstream read token is rate limited' {
        $env:WINGET_UPSTREAM_READ_TOKEN = 'primary-read-token'
        $env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN = 'fallback-read-token'
        $global:ForkBranchUpstreamReadFailTokens = @('primary-read-token')

        $result = Submit-WingetPackage `
            -ManifestPath $global:ForkBranchSubmissionManifestPath `
            -PackageId 'Test.Package' `
            -Version '1.0.0' `
            -Token 'fork-write-token' `
            -With ForkBranch

        if ($result.Success -ne $true) {
            throw "Expected the submission to succeed via the fallback read token, got: $($result.Error)"
        }
        $upstreamReads = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/microsoft/winget-pkgs($|/)' -and $_.Method -eq 'Get' }
        )
        if ($upstreamReads.Count -ne 6) {
            throw "Expected each of the three upstream reads to retry exactly once with the fallback token: $($upstreamReads | ConvertTo-Json -Compress)"
        }
        foreach ($group in ($upstreamReads | Group-Object Path)) {
            $attempts = @($group.Group)
            if ($attempts.Count -ne 2 -or
                $attempts[0].Token -cne 'primary-read-token' -or
                $attempts[1].Token -cne 'fallback-read-token') {
                throw "Upstream read for $($group.Name) did not fail over from the primary to the fallback token: $($attempts | ConvertTo-Json -Compress)"
            }
        }
        if (@($upstreamReads | Where-Object { $_.Unauthenticated }).Count -ne 0) {
            throw 'A tokened upstream read attempt was marked unauthenticated.'
        }

        $forkRequests = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object { $_.Path -match '^repos/damn-good-b0t/winget-pkgs($|/)' }
        )
        if (@($forkRequests | Where-Object { $_.Token -cne 'fork-write-token' }).Count -ne 0) {
            throw "A fork operation used a read token during failover: $($forkRequests | ConvertTo-Json -Compress)"
        }
        $pullRequest = $global:ForkBranchSubmissionRequests |
            Where-Object { $_.Path -eq 'repos/microsoft/winget-pkgs/pulls' } |
            Select-Object -Last 1
        if ($null -eq $pullRequest -or $pullRequest.Token -cne 'fork-write-token') {
            throw 'The upstream PR creation did not retain the fork submission token during failover.'
        }
    }

    It 'returns the upstream PR when the final duplicate preflight returns Created=false' {
        InModuleScope WingetMaintainerModule {
            Mock Test-ExistingPRs {
                param($PackageIdentifier, $Version, $Repository)

                $global:ForkBranchDuplicateRepositories.Add($Repository)
                return $true
            }
            Mock Get-WingetPkgsPrUrl {
                param($PackageId, $Version, $Repository)

                $global:ForkBranchPrUrlRepositories.Add($Repository)
                return 'https://github.com/microsoft/winget-pkgs/pull/54321'
            }
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
        if ($global:ForkBranchPrUrlRepositories.Count -ne 1 -or $global:ForkBranchPrUrlRepositories[0] -cne 'microsoft/winget-pkgs') {
            throw "Created=false did not resolve the existing pull request against the upstream target: $($global:ForkBranchPrUrlRepositories -join ', ')"
        }
        $branchDeletes = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Method -eq 'Delete' -and
                    $_.Path -match '^repos/damn-good-b0t/winget-pkgs/git/refs/heads/winget-autosubmit/'
                }
        )
        if ($branchDeletes.Count -ne 0) {
            throw "Duplicate handling deleted a deterministic claim that could belong to an existing PR: $($global:ForkBranchSubmissionRequests | ConvertTo-Json -Compress)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -eq 'repos/microsoft/winget-pkgs/pulls' -and $_.Method -eq 'Post' }).Count -ne 0) {
            throw 'Duplicate detection created an upstream pull request.'
        }
    }

    It 'uses one deterministic source ref claim when competing submissions cannot yet search each other PRs' {
        $competingResults = InModuleScope WingetMaintainerModule {
            $script:DeterministicClaimCreated = $false
            Mock Test-ExistingPRs { $false }
            Mock Invoke-WingetPkgsGitHubApi {
                param($Method, $Path, $Token, $Unauthenticated, $Body)

                $global:ForkBranchSubmissionRequests.Add([pscustomobject]@{
                    Method          = $Method
                    Path            = $Path
                    Token           = $Token
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
                        if (-not $script:DeterministicClaimCreated) {
                            $script:DeterministicClaimCreated = $true
                            return [pscustomobject]@{ ref = "$($Body.ref)" }
                        }

                        $conflictResponse = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::UnprocessableEntity)
                        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Reference already exists', $conflictResponse)
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

            $first = Invoke-ForkBranchSubmission `
                -ManifestPath $global:ForkBranchSubmissionManifestPath `
                -PackageId 'Test.Package' `
                -Version '1.0.0' `
                -PrTitle 'Update version: Test.Package version 1.0.0' `
                -Token 'test-token' `
                -ForkRepository 'damn-good-b0t/winget-pkgs'
            $second = Invoke-ForkBranchSubmission `
                -ManifestPath $global:ForkBranchSubmissionManifestPath `
                -PackageId 'Test.Package' `
                -Version '1.0.0' `
                -PrTitle 'Update version: Test.Package version 1.0.0' `
                -Token 'test-token' `
                -ForkRepository 'damn-good-b0t/winget-pkgs'

            return [pscustomobject]@{
                First  = $first
                Second = $second
            }
        }

        $first = $competingResults.First
        $second = $competingResults.Second
        if (-not $first.Created) {
            throw "The claim owner did not create the PR: $($first | ConvertTo-Json -Compress)"
        }
        if ($second.Created -or $second.DuplicateDetected -or $second.Error -notmatch 'already exists') {
            throw "The competing submission was not fail-closed by the existing claim: $($second | ConvertTo-Json -Compress)"
        }

        $claimRequests = @(
            $global:ForkBranchSubmissionRequests |
                Where-Object {
                    $_.Method -eq 'Post' -and
                    $_.Path -eq 'repos/damn-good-b0t/winget-pkgs/git/refs'
                }
        )
        if ($claimRequests.Count -ne 2 -or $claimRequests[0].Body.ref -cne $claimRequests[1].Body.ref) {
            throw "Competing submissions did not use the same deterministic source ref: $($claimRequests | ConvertTo-Json -Compress)"
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -eq 'repos/damn-good-b0t/winget-pkgs/git/trees' -and $_.Method -eq 'Post' }).Count -ne 2) {
            throw 'Both competing submissions must reach their immutable manifest commits before the deterministic ref claim arbitrates ownership.'
        }
        if (@($global:ForkBranchSubmissionRequests | Where-Object { $_.Path -eq 'repos/microsoft/winget-pkgs/pulls' -and $_.Method -eq 'Post' }).Count -ne 1) {
            throw 'Competing submissions created more than one upstream pull request.'
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
