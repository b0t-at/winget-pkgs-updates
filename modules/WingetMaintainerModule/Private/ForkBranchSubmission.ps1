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

    try {
        return Invoke-RestMethod @request
    }
    catch {
        $responseBody = Get-WingetPkgsGitHubApiFailureResponseBody -ErrorRecord $_
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            $statusCode = Get-WingetPkgsGitHubApiFailureStatusCode -ErrorRecord $_
            Write-Warning "GitHub API $Method $($Path.TrimStart('/')) returned HTTP $statusCode. Response body: $responseBody"
        }
        throw
    }
}

function Invoke-WingetPkgsUpstreamReadApi {
    <#
    .SYNOPSIS
        Performs a public upstream GET with tiered read credentials.
    .DESCRIPTION
        Attempts WINGET_UPSTREAM_READ_TOKEN first, then
        WINGET_UPSTREAM_READ_FALLBACK_TOKEN, then anonymous access, failing
        over only on authorization or rate-limit statuses (401/403/404/429).
        The fork-scoped submission token is never used here.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $credentialTiers = @(Get-WingetPkgsUpstreamReadCredentialTiers)
    for ($tierIndex = 0; $tierIndex -lt $credentialTiers.Count; $tierIndex++) {
        $tier = $credentialTiers[$tierIndex]
        $isAnonymous = [string]::IsNullOrWhiteSpace($tier.Token)
        # -Token is mandatory; the placeholder is never sent because
        # -Unauthenticated omits the Authorization header entirely.
        $requestToken = if ($isAnonymous) { 'unused-anonymous-read' } else { $tier.Token }
        try {
            return Invoke-WingetPkgsGitHubApi `
                -Method Get `
                -Path $Path `
                -Token $requestToken `
                -Unauthenticated:$isAnonymous
        }
        catch {
            $statusCode = Get-WingetPkgsUpstreamReadFailureStatusCode -ErrorRecord $_
            $isLastTier = $tierIndex -eq ($credentialTiers.Count - 1)
            if ($isLastTier -or -not (Test-WingetPkgsUpstreamReadFailoverStatus -StatusCode $statusCode)) {
                throw
            }
            $nextTier = $credentialTiers[$tierIndex + 1]
            Write-Warning "Upstream read '$Path' with $($tier.Label) failed with HTTP $statusCode; retrying with $($nextTier.Label)."
        }
    }
}

function Get-WingetPkgsSubmissionManifestDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageId,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    Assert-WingetPkgsSubmissionIdentity -PackageId $PackageId -Version $Version
    return "manifests/$($PackageId[0].ToString().ToLowerInvariant())/$($PackageId.Replace('.', '/'))/$Version"
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

    Assert-WingetPkgsSubmissionIdentity -PackageId $PackageId -Version $Version

    $files = @(Get-ChildItem -LiteralPath $ManifestPath -File -ErrorAction Stop)
    if ($files.Count -eq 0) {
        throw "Manifest path '$ManifestPath' does not contain any files."
    }

    $unexpectedFiles = @($files | Where-Object { $_.Extension -notin @('.yaml', '.yml') })
    if ($unexpectedFiles.Count -gt 0) {
        $unexpectedNames = $unexpectedFiles.Name -join ', '
        throw "Manifest path '$ManifestPath' contains non-manifest files: $unexpectedNames"
    }

    $manifestDirectory = Get-WingetPkgsSubmissionManifestDirectory -PackageId $PackageId -Version $Version
    return @(
        $files | ForEach-Object {
            [pscustomobject]@{
                Path    = "$manifestDirectory/$($_.Name)"
                Content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
            }
        }
    )
}

function Assert-WingetPkgsSubmissionIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $packageIdentifierPattern = '^[^\.\s\\/:\*\?"<>\|\x01-\x1f]{1,32}(\.[^\.\s\\/:\*\?"<>\|\x01-\x1f]{1,32}){1,7}$'
    if ($PackageId -notmatch $packageIdentifierPattern) {
        throw "Package ID '$PackageId' is not safe for a winget manifest path."
    }
    if ($Version -match '[\\/]' -or $Version -match '^\.+$') {
        throw "Version '$Version' is not safe for a winget manifest path."
    }
}

function Get-WingetPkgsSubmissionBranchName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    Assert-WingetPkgsSubmissionIdentity -PackageId $PackageId -Version $Version

    $normalizedPackageId = $PackageId.ToLowerInvariant()
    $normalizedVersion = $Version.ToLowerInvariant()
    $identity = $normalizedPackageId + [string][char]0 + $normalizedVersion
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $hasher.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity))
    }
    finally {
        $hasher.Dispose()
    }
    $identityHash = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 16)

    $readableSuffix = "$normalizedPackageId-$normalizedVersion" -replace '[^A-Za-z0-9._+-]', '-'
    if ($readableSuffix.Length -gt 96) {
        $readableSuffix = $readableSuffix.Substring(0, 96)
    }

    return "winget-autosubmit/$readableSuffix-$identityHash"
}


function Invoke-WingetPkgsForkWriteWithObjectStoreRetry {
    <#
    .SYNOPSIS
        Retries fork writes that can briefly fail while upstream git objects
        propagate into the fork's object store.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Post')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Token,

        [Parameter(Mandatory = $true)]
        [object] $Body,

        [Parameter(Mandatory = $true)]
        [int[]] $RetryStatusCodes,

        [Parameter()]
        [string] $RetryResponsePattern,

        [Parameter(Mandatory = $true)]
        [string] $OperationName,

        [Parameter()]
        [AllowEmptyCollection()]
        [int[]] $RetryDelaySeconds = @(15, 45),

        [Parameter()]
        [scriptblock] $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
    )

    $attempts = @($RetryDelaySeconds).Count + 1
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return Invoke-WingetPkgsGitHubApi -Method $Method -Path $Path -Token $Token -Body $Body
        }
        catch {
            $statusCode = Get-WingetPkgsGitHubApiFailureStatusCode -ErrorRecord $_
            $responseBody = Get-WingetPkgsGitHubApiFailureResponseBody -ErrorRecord $_
            $matchesStatus = $statusCode -in $RetryStatusCodes
            $matchesBody = [string]::IsNullOrWhiteSpace($RetryResponsePattern) -or ($responseBody -match $RetryResponsePattern) -or ($_.Exception.Message -match $RetryResponsePattern)
            if (-not $matchesStatus -or -not $matchesBody -or $attempt -ge $attempts) {
                throw
            }

            $delaySeconds = @($RetryDelaySeconds)[$attempt - 1]
            Write-Warning "$OperationName returned transient HTTP $statusCode on attempt $attempt of $attempts; retrying in $delaySeconds second(s)."
            & $Sleep $delaySeconds
        }
    }
}

function Get-WingetPkgsOpenPullRequestForHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $TargetRepository,
        [Parameter(Mandatory = $true)] [string] $ForkOwner,
        [Parameter(Mandatory = $true)] [string] $BranchName,
        [Parameter(Mandatory = $true)] [string] $Token
    )

    $encodedHead = [uri]::EscapeDataString("${ForkOwner}:$BranchName")
    $pullRequests = @(Invoke-WingetPkgsGitHubApi `
            -Method Get `
            -Path "repos/$TargetRepository/pulls?state=open&head=$encodedHead" `
            -Token $Token)
    return @($pullRequests | Select-Object -First 1)
}

function Get-WingetPkgsForkBranchCommitTreeSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ForkRepository,
        [Parameter(Mandatory = $true)] [string] $BranchName,
        [Parameter(Mandatory = $true)] [string] $Token
    )

    $reference = Invoke-WingetPkgsGitHubApi `
        -Method Get `
        -Path "repos/$ForkRepository/git/ref/heads/$BranchName" `
        -Token $Token
    $commitSha = "$($reference.object.sha)"
    if ([string]::IsNullOrWhiteSpace($commitSha)) {
        throw "Could not resolve the existing fork branch '$BranchName' commit SHA."
    }

    $commit = Invoke-WingetPkgsGitHubApi `
        -Method Get `
        -Path "repos/$ForkRepository/git/commits/$commitSha" `
        -Token $Token
    return "$($commit.tree.sha)"
}

function Get-WingetPkgsTreeEntrySha {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [string] $TreeSha,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Token
    )

    $currentTreeSha = $TreeSha
    foreach ($segment in @($Path -split '/' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $tree = Invoke-WingetPkgsGitHubApi `
            -Method Get `
            -Path "repos/$Repository/git/trees/$currentTreeSha" `
            -Token $Token
        $entry = @($tree.tree | Where-Object { $_.type -eq 'tree' -and $_.path -ceq $segment } | Select-Object -First 1)
        if ($entry.Count -eq 0 -or [string]::IsNullOrWhiteSpace("$($entry[0].sha)")) {
            throw "Tree '$currentTreeSha' in '$Repository' does not contain directory '$segment' while resolving '$Path'."
        }
        $currentTreeSha = "$($entry[0].sha)"
    }

    return $currentTreeSha
}

function Test-WingetPkgsSubmissionVersionSubtreeMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [string] $ForkRepository,
        [Parameter(Mandatory = $true)] [string] $ExistingRootTreeSha,
        [Parameter(Mandatory = $true)] [string] $NewRootTreeSha,
        [Parameter(Mandatory = $true)] [string] $ManifestDirectory,
        [Parameter(Mandatory = $true)] [string] $Token
    )

    $existingSubtreeSha = Get-WingetPkgsTreeEntrySha `
        -Repository $ForkRepository `
        -TreeSha $ExistingRootTreeSha `
        -Path $ManifestDirectory `
        -Token $Token
    $newSubtreeSha = Get-WingetPkgsTreeEntrySha `
        -Repository $ForkRepository `
        -TreeSha $NewRootTreeSha `
        -Path $ManifestDirectory `
        -Token $Token

    return $existingSubtreeSha -ceq $newSubtreeSha
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
        [string] $TargetRepository = 'microsoft/winget-pkgs',

        [Parameter(Mandatory = $false)]
        [string] $Resolves,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [int[]] $RetryDelaySeconds = @(15, 45),

        [Parameter(Mandatory = $false)]
        [scriptblock] $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
    )

    $upstreamRepository = 'microsoft/winget-pkgs'
    Assert-SafeWingetPkgsForkRepository -ForkRepository $ForkRepository

    Write-Host "ForkBranch: verifying fork $ForkRepository" -ForegroundColor DarkGray
    $fork = Invoke-WingetPkgsGitHubApi -Method Get -Path "repos/$ForkRepository" -Token $Token
    if (-not $fork.fork -or "$($fork.parent.full_name)" -ine $upstreamRepository) {
        throw "Configured repository '$ForkRepository' is not a fork of $upstreamRepository."
    }

    if ($TargetRepository -ine $upstreamRepository -and $TargetRepository -ine $ForkRepository) {
        throw "ForkBranch target '$TargetRepository' must be microsoft/winget-pkgs or the configured fork '$ForkRepository'."
    }

    # Target base reads use the tiered read credentials
    # (WINGET_UPSTREAM_READ_TOKEN, then WINGET_UPSTREAM_READ_FALLBACK_TOKEN,
    # then anonymous); fork writes and PR creation keep using $Token.
    $targetRepository = $TargetRepository
    Write-Host "ForkBranch: resolving $targetRepository default branch" -ForegroundColor DarkGray
    $target = Invoke-WingetPkgsUpstreamReadApi -Path "repos/$targetRepository"
    $targetDefaultBranch = "$($target.default_branch)"
    $baseRepository = $targetRepository

    Write-Host "ForkBranch: fetching base ref $baseRepository/$targetDefaultBranch" -ForegroundColor DarkGray
    $baseReference = Invoke-WingetPkgsUpstreamReadApi -Path "repos/$baseRepository/git/ref/heads/$targetDefaultBranch"
    $baseSha = "$($baseReference.object.sha)"
    if ([string]::IsNullOrWhiteSpace($baseSha)) {
        throw "Could not resolve the $baseRepository/$targetDefaultBranch commit SHA."
    }
    Write-Host "ForkBranch: base SHA $baseSha" -ForegroundColor DarkGray
    $baseCommit = Invoke-WingetPkgsUpstreamReadApi -Path "repos/$baseRepository/git/commits/$baseSha"
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
    Write-Host "ForkBranch: creating tree with $(@($treeItems).Count) file(s) in $ForkRepository" -ForegroundColor DarkGray

    # The fork default branch remains read-only. The manifest commit is rooted
    # at the selected target base commit before its ref is atomically claimed.
    $tree = Invoke-WingetPkgsForkWriteWithObjectStoreRetry `
        -Method Post `
        -Path "repos/$ForkRepository/git/trees" `
        -Token $Token `
        -Body @{
            base_tree = $baseTreeSha
            tree      = @($treeItems)
        } `
        -RetryStatusCodes @(422) `
        -RetryResponsePattern 'base_tree.*valid tree oid' `
        -OperationName 'ForkBranch tree creation' `
        -RetryDelaySeconds $RetryDelaySeconds `
        -Sleep $Sleep
    Write-Host "ForkBranch: creating commit in $ForkRepository" -ForegroundColor DarkGray
    $commit = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$ForkRepository/git/commits" `
        -Token $Token `
        -Body @{
            message = $PrTitle
            tree    = "$($tree.sha)"
            parents = @($baseSha)
        }

    # Creating this deterministic ref is the atomic package/version claim.
    # A collision is never retried with another name because that could open a
    # second target PR while the first worker's PR is not searchable yet.
    $branchName = Get-WingetPkgsSubmissionBranchName -PackageId $PackageId -Version $Version
    Write-Host "ForkBranch: claiming branch $branchName in $ForkRepository" -ForegroundColor DarkGray
    try {
        Invoke-WingetPkgsForkWriteWithObjectStoreRetry `
            -Method Post `
            -Path "repos/$ForkRepository/git/refs" `
            -Token $Token `
            -Body @{
                ref = "refs/heads/$branchName"
                sha = "$($commit.sha)"
            } `
            -RetryStatusCodes @(404) `
            -OperationName 'ForkBranch ref creation' `
            -RetryDelaySeconds $RetryDelaySeconds `
            -Sleep $Sleep | Out-Null
    }
    catch {
        $statusCode = Get-WingetPkgsGitHubApiFailureStatusCode -ErrorRecord $_
        if ($statusCode -notin @(409, 422)) {
            throw
        }

        Write-Host "ForkBranch: branch claim returned HTTP $statusCode; checking for existing PR" -ForegroundColor DarkGray
        if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version -Repository $targetRepository) {
            return [pscustomobject]@{
                Created             = $false
                DuplicateDetected   = $true
                SubmissionClaimed   = $true
                BranchName          = $branchName
                PullRequest         = $null
                Error               = $null
            }
        }

        $forkOwner = $ForkRepository.Split('/')[0]
        $headPullRequest = Get-WingetPkgsOpenPullRequestForHead `
            -TargetRepository $targetRepository `
            -ForkOwner $forkOwner `
            -BranchName $branchName `
            -Token $Token
        if ($null -ne $headPullRequest) {
            return [pscustomobject]@{
                Created             = $false
                DuplicateDetected   = $true
                SubmissionClaimed   = $true
                BranchName          = $branchName
                PullRequest         = $headPullRequest
                Error               = $null
            }
        }

        $existingTreeSha = Get-WingetPkgsForkBranchCommitTreeSha `
            -ForkRepository $ForkRepository `
            -BranchName $branchName `
            -Token $Token
        $manifestDirectory = Get-WingetPkgsSubmissionManifestDirectory -PackageId $PackageId -Version $Version
        $versionSubtreeMatches = Test-WingetPkgsSubmissionVersionSubtreeMatch `
            -ForkRepository $ForkRepository `
            -ExistingRootTreeSha $existingTreeSha `
            -NewRootTreeSha "$($tree.sha)" `
            -ManifestDirectory $manifestDirectory `
            -Token $Token
        if (-not $versionSubtreeMatches) {
            return [pscustomobject]@{
                Created             = $false
                DuplicateDetected   = $false
                SubmissionClaimed   = $true
                BranchName          = $branchName
                PullRequest         = $null
                Error               = "The deterministic submission branch '$branchName' already exists with different content under '$manifestDirectory' and no matching target PR is searchable. Refusing to create another PR; reconcile the existing branch before retrying."
            }
        }

        Write-Host "ForkBranch: reusing existing branch $branchName because its submitted package-version subtree already matches this submission." -ForegroundColor DarkGray
    }

    # Recheck immediately before the target PR write. The branch claim closes
    # the remaining read-to-write race when GitHub Search has not indexed a PR.
    if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version -Repository $targetRepository) {
        return [pscustomobject]@{
            Created             = $false
            DuplicateDetected   = $true
            SubmissionClaimed   = $true
            BranchName          = $branchName
            PullRequest         = $null
            Error               = $null
        }
    }

    $forkOwner = $ForkRepository.Split('/')[0]
    $headReference = if ($targetRepository -ieq $ForkRepository) { $branchName } else { "${forkOwner}:$branchName" }
    $bodyLines = @("Update $PackageId to version $Version.")
    if (-not [string]::IsNullOrWhiteSpace($Resolves)) {
        $bodyLines += ''
        $bodyLines += "Resolves #$Resolves"
    }
    $body = $bodyLines -join "`n"
    Write-Host "ForkBranch: opening PR in $targetRepository (head: $headReference)" -ForegroundColor DarkGray
    $pullRequest = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$targetRepository/pulls" `
        -Token $Token `
        -Body @{
            title = $PrTitle
            head  = $headReference
            base  = $targetDefaultBranch
            body  = $body
        }

    return [pscustomobject]@{
        Created             = $true
        DuplicateDetected   = $false
        SubmissionClaimed   = $true
        BranchName          = $branchName
        PullRequest         = $pullRequest
        Error               = $null
    }
}
