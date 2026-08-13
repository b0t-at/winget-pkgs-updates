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
        # Capture and surface the GitHub API response body so callers can log it.
        # PowerShell 7: $_.ErrorDetails.Message contains the parsed response body.
        # PowerShell 5: the response stream must be read from $_.Exception.Response.
        $responseBody = $null
        try {
            if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
                $responseBody = $_.ErrorDetails.Message
            }
            else {
                $response = $_.Exception.Response
                if ($null -ne $response) {
                    $stream = $response.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        $responseBody = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
            }
        }
        catch {
            # Swallow stream-read errors; the original exception is re-thrown below.
        }
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            $statusCode = 0
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
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

function Assert-WingetPkgsSubmissionIdentity {
    [CmdletBinding()]
    param(
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

    $readableSuffix = "$normalizedPackageId-$normalizedVersion" -replace '[^A-Za-z0-9._-]', '-'
    if ($readableSuffix.Length -gt 96) {
        $readableSuffix = $readableSuffix.Substring(0, 96)
    }

    return "winget-autosubmit/$readableSuffix-$identityHash"
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
        [string] $Resolves
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
    $tree = Invoke-WingetPkgsGitHubApi `
        -Method Post `
        -Path "repos/$ForkRepository/git/trees" `
        -Token $Token `
        -Body @{
            base_tree = $baseTreeSha
            tree      = @($treeItems)
        }
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
        Invoke-WingetPkgsGitHubApi `
            -Method Post `
            -Path "repos/$ForkRepository/git/refs" `
            -Token $Token `
            -Body @{
                ref = "refs/heads/$branchName"
                sha = "$($commit.sha)"
            } | Out-Null
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

        return [pscustomobject]@{
            Created             = $false
            DuplicateDetected   = $false
            SubmissionClaimed   = $true
            BranchName          = $branchName
            PullRequest         = $null
            Error               = "The deterministic submission branch '$branchName' already exists, but no matching target PR is searchable. Refusing to create another PR; reconcile the existing branch before retrying."
        }
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
    $body = if ([string]::IsNullOrWhiteSpace($Resolves)) { $null } else { "Resolves #$Resolves" }
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
