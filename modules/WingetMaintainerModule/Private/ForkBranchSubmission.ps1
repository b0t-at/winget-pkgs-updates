function Invoke-WingetPkgsGitHubApi {
    <#
    .SYNOPSIS
        Calls the GitHub REST API without placing a token in a process argument.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [switch] $Unauthenticated,

        [Parameter(Mandatory = $false)]
        [object] $Body
    )
    $headers = @{
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'winget-pkgs-updates'
    }
    if (-not $Unauthenticated) {
        $headers.Authorization = "Bearer $Token"
    }
    $request = @{
        Uri         = "https://api.github.com/$($Path.TrimStart('/'))"
        Method      = $Method
        Headers     = $headers
        ErrorAction = 'Stop'
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }

    return Invoke-RestMethod @request
}

function Get-ForkBranchSubmissionFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    if ($PackageId -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
        throw "Package ID '$PackageId' is not safe for a winget manifest path."
    }
    if ($Version -match '[\\/]' -or $Version -match '^\.+$') {
        throw "Version '$Version' is not safe for a winget manifest path."
    }

    $files = @(Get-ChildItem -LiteralPath $ManifestPath -File -ErrorAction Stop)
    if ($files.Count -eq 0) {
        throw "Manifest path '$ManifestPath' does not contain any files."
    }

    $unexpectedFiles = @($files | Where-Object { $_.Extension -notin @('.yaml', '.yml') })
    if ($unexpectedFiles.Count -gt 0) {
        $unexpectedNames = $unexpectedFiles.Name -join ', '
        throw "Manifest path '$ManifestPath' contains non-manifest files: $unexpectedNames"
    }

    $manifestDirectory = "manifests/$($PackageId[0].ToString().ToLowerInvariant())/$($PackageId.Replace('.', '/'))/$Version"
    return @(
        $files | ForEach-Object {
            [pscustomobject]@{
                Path    = "$manifestDirectory/$($_.Name)"
                Content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
            }
        }
    )
}

function Assert-SafeWingetPkgsForkRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ForkRepository
    )

    $upstreamRepository = 'microsoft/winget-pkgs'
    if ($ForkRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "WINGET_PKGS_FORK_REPO must be an owner/repository name, not '$ForkRepository'."
    }
    if ($ForkRepository -ieq $upstreamRepository) {
        throw 'WINGET_PKGS_FORK_REPO must name a user-owned fork, never microsoft/winget-pkgs.'
    }
}

function Invoke-ForkBranchSubmission {
    <#
    .SYNOPSIS
        Creates a submission branch in a verified user fork without syncing its default branch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [string] $PrTitle,

        [Parameter(Mandatory = $true)]
        [string] $Token,

        [Parameter(Mandatory = $true)]
        [string] $ForkRepository,

        [Parameter(Mandatory = $false)]
        [string] $Resolves
    )

    $upstreamRepository = 'microsoft/winget-pkgs'
    Assert-SafeWingetPkgsForkRepository -ForkRepository $ForkRepository

    $fork = Invoke-WingetPkgsGitHubApi -Method Get -Path "repos/$ForkRepository" -Token $Token
    if (-not $fork.fork -or "$($fork.parent.full_name)" -ine $upstreamRepository) {
        throw "Configured repository '$ForkRepository' is not a fork of $upstreamRepository."
    }

    # The fine-grained fork token cannot necessarily read the public upstream.
    # Keep its use to fork writes and the final cross-repository PR creation.
    $targetRepository = $upstreamRepository
    $upstream = Invoke-WingetPkgsGitHubApi `
        -Method Get `
        -Path "repos/$upstreamRepository" `
        -Token $Token `
        -Unauthenticated
    $targetDefaultBranch = "$($upstream.default_branch)"
    $baseRepository = $targetRepository

    $baseReference = Invoke-WingetPkgsGitHubApi `
        -Method Get `
        -Path "repos/$baseRepository/git/ref/heads/$targetDefaultBranch" `
        -Token $Token `
        -Unauthenticated
    $baseSha = "$($baseReference.object.sha)"
    if ([string]::IsNullOrWhiteSpace($baseSha)) {
        throw "Could not resolve the $baseRepository/$targetDefaultBranch commit SHA."
    }
    $baseCommit = Invoke-WingetPkgsGitHubApi `
        -Method Get `
        -Path "repos/$baseRepository/git/commits/$baseSha" `
        -Token $Token `
        -Unauthenticated
    $baseTreeSha = "$($baseCommit.tree.sha)"
    if ([string]::IsNullOrWhiteSpace($baseTreeSha)) {
        throw "Could not resolve the base tree for $baseRepository/$targetDefaultBranch."
    }

    $treeItems = Get-ForkBranchSubmissionFiles `
        -ManifestPath $ManifestPath `
        -PackageId $PackageId `
        -Version $Version |
        ForEach-Object {
            @{
                path    = $_.Path
                mode    = '100644'
                type    = 'blob'
                content = $_.Content
            }
        }

    # A branch is created directly from the selected base commit; the fork's
    # default branch is read-only throughout this flow.
    $tree = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$ForkRepository/git/trees" `
        -Token $Token `
        -Body @{
            base_tree = $baseTreeSha
            tree      = @($treeItems)
        }
    $commit = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$ForkRepository/git/commits" `
        -Token $Token `
        -Body @{
            message = $PrTitle
            tree    = "$($tree.sha)"
            parents = @($baseSha)
        }

    $branchSuffix = "$PackageId-$Version" -replace '[^A-Za-z0-9._-]', '-'
    $branchName = "winget-autosubmit/$branchSuffix-$([guid]::NewGuid().ToString('N'))"
    Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$ForkRepository/git/refs" `
        -Token $Token `
        -Body @{
            ref = "refs/heads/$branchName"
            sha = "$($commit.sha)"
        } | Out-Null

    # Recheck immediately before the external write. Workflow concurrency handles
    # scheduled workers; this closes the remaining generate-to-submit window.
    if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version -Repository $targetRepository) {
        Invoke-WingetPkgsGitHubApi `
            -Method Delete `
            -Path "repos/$ForkRepository/git/refs/heads/$branchName" `
            -Token $Token | Out-Null

        return [pscustomobject]@{
            Created    = $false
            BranchName = $branchName
            PullRequest = $null
        }
    }

    $forkOwner = $ForkRepository.Split('/')[0]
    $body = if ([string]::IsNullOrWhiteSpace($Resolves)) { $null } else { "Resolves #$Resolves" }
    $pullRequest = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$targetRepository/pulls" `
        -Token $Token `
        -Body @{
            title = $PrTitle
            head  = "${forkOwner}:$branchName"
            base  = $targetDefaultBranch
            body  = $body
        }

    return [pscustomobject]@{
        Created     = $true
        BranchName  = $branchName
        PullRequest = $pullRequest
    }
}
