function Save-WinMatschFeedbackState {
    <#
    .SYNOPSIS
        Replaces, commits, and pushes the committed WinMatsch feedback store.

    .DESCRIPTION
        Copies JSON feedback items from an artifact directory into
        data/winmatsch-feedback, removes stale JSON items, and pushes the result
        with bounded non-fast-forward retries. Lock files are intentionally
        ignored and must never be committed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FeedbackSourcePath,

        [Parameter(Mandatory = $false)]
        [string] $RepoPath = '.',

        [Parameter(Mandatory = $false)]
        [string] $StateDirectory = 'data/winmatsch-feedback',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int] $MaxPushAttempts = 3
    )

    function Invoke-FeedbackGit {
        param(
            [Parameter(Mandatory = $true)]
            [string[]] $Arguments,

            [Parameter(Mandatory = $false)]
            [switch] $AllowFailure
        )

        $output = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
        $outputText = ($output | ForEach-Object { $_.ToString() }) -join "`n"

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $outputText"
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = $outputText
        }
    }

    function Clear-InterruptedFeedbackGitOperation {
        $gitDirectoryResult = Invoke-FeedbackGit -Arguments @('rev-parse', '--git-dir')
        $gitDirectory = $gitDirectoryResult.Output.Trim()
        if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
            $gitDirectory = Join-Path (Get-Location).Path $gitDirectory
        }

        $cleanupCommands = @()
        if ((Test-Path (Join-Path $gitDirectory 'rebase-merge')) -or
            (Test-Path (Join-Path $gitDirectory 'rebase-apply'))) {
            $cleanupCommands += , @('rebase', '--abort')
        }
        if (Test-Path (Join-Path $gitDirectory 'MERGE_HEAD')) {
            $cleanupCommands += , @('merge', '--abort')
        }
        if (Test-Path (Join-Path $gitDirectory 'CHERRY_PICK_HEAD')) {
            $cleanupCommands += , @('cherry-pick', '--abort')
        }
        if (Test-Path (Join-Path $gitDirectory 'REVERT_HEAD')) {
            $cleanupCommands += , @('revert', '--abort')
        }

        foreach ($command in $cleanupCommands) {
            $cleanupResult = Invoke-FeedbackGit -Arguments $command -AllowFailure
            if ($cleanupResult.ExitCode -ne 0) {
                throw "Failed to clean interrupted git operation with 'git $($command -join ' ')': $($cleanupResult.Output)"
            }
        }
    }

    function Copy-WinMatschFeedbackJson {
        param(
            [Parameter(Mandatory = $true)]
            [string] $SourcePath,

            [Parameter(Mandatory = $true)]
            [string] $DestinationPath
        )

        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        Get-ChildItem -LiteralPath $DestinationPath -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Get-ChildItem -LiteralPath $DestinationPath -Filter '*.lock' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force

        $jsonFiles = @(Get-ChildItem -LiteralPath $SourcePath -Filter '*.json' -File -ErrorAction SilentlyContinue)
        foreach ($jsonFile in $jsonFiles) {
            Copy-Item -LiteralPath $jsonFile.FullName -Destination (Join-Path $DestinationPath $jsonFile.Name) -Force
        }
    }

    Push-Location -Path $RepoPath
    $upstreamRef = $null
    $remoteName = $null
    $remoteBranch = $null

    try {
        Clear-InterruptedFeedbackGitOperation

        $repositoryRoot = (Invoke-FeedbackGit -Arguments @('rev-parse', '--show-toplevel')).Output.Trim()
        $sourceFullPath = if ([IO.Path]::IsPathRooted($FeedbackSourcePath)) {
            [IO.Path]::GetFullPath($FeedbackSourcePath)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $FeedbackSourcePath))
        }
        if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Container)) {
            throw "WinMatsch feedback artifact directory not found: $sourceFullPath"
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sourceFullPath '.artifact-ready') -PathType Leaf)) {
            Write-Warning "WinMatsch feedback artifact '$sourceFullPath' is missing the .artifact-ready marker; leaving committed feedback state unchanged."
            return
        }

        $stateFullPath = if ([IO.Path]::IsPathRooted($StateDirectory)) {
            [IO.Path]::GetFullPath($StateDirectory)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $repositoryRoot $StateDirectory))
        }
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $stateFullPath).Replace('\', '/')
        if ($relativePath -eq '..' -or $relativePath.StartsWith('../')) {
            throw "WinMatsch feedback directory '$stateFullPath' must be inside repository '$repositoryRoot'."
        }

        $changedPaths = @()
        $changedPaths += (Invoke-FeedbackGit -Arguments @('diff', '--name-only')).Output -split "`n"
        $changedPaths += (Invoke-FeedbackGit -Arguments @('diff', '--cached', '--name-only')).Output -split "`n"
        $otherChangedPaths = @($changedPaths |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    $_.Trim() -ne $relativePath -and
                    -not $_.Trim().StartsWith("$relativePath/", [StringComparison]::Ordinal)
                } |
                Sort-Object -Unique)
        if ($otherChangedPaths.Count -gt 0) {
            throw "Refusing to reset repository with unrelated tracked changes: $($otherChangedPaths -join ', ')"
        }

        $branch = (Invoke-FeedbackGit -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')).Output.Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            throw 'Save-WinMatschFeedbackState requires a checked-out branch; detached HEAD is not supported.'
        }

        $upstreamResult = Invoke-FeedbackGit -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -AllowFailure
        if ($upstreamResult.ExitCode -eq 0) {
            $upstreamRef = $upstreamResult.Output.Trim()
        }
        else {
            $upstreamRef = "origin/$branch"
        }

        $separatorIndex = $upstreamRef.IndexOf('/')
        if ($separatorIndex -le 0 -or $separatorIndex -eq $upstreamRef.Length - 1) {
            throw "Unsupported upstream ref '$upstreamRef'."
        }
        $remoteName = $upstreamRef.Substring(0, $separatorIndex)
        $remoteBranch = $upstreamRef.Substring($separatorIndex + 1)

        for ($attempt = 1; $attempt -le $MaxPushAttempts; $attempt++) {
            Write-Host "Saving WinMatsch feedback state (attempt $attempt of $MaxPushAttempts)..."
            Invoke-FeedbackGit -Arguments @(
                'fetch',
                '--no-tags',
                $remoteName,
                "+refs/heads/${remoteBranch}:refs/remotes/${remoteName}/${remoteBranch}"
            ) | Out-Null

            $remoteCommit = (Invoke-FeedbackGit -Arguments @('rev-parse', $upstreamRef)).Output.Trim()
            Invoke-FeedbackGit -Arguments @('reset', '--hard', $remoteCommit) | Out-Null
            Copy-WinMatschFeedbackJson -SourcePath $sourceFullPath -DestinationPath $stateFullPath

            Invoke-FeedbackGit -Arguments @('add', '--', $relativePath) | Out-Null
            $diffResult = Invoke-FeedbackGit -Arguments @('diff', '--cached', '--quiet', '--', $relativePath) -AllowFailure
            if ($diffResult.ExitCode -eq 0) {
                Write-Host "No changes to WinMatsch feedback state — nothing to commit." -ForegroundColor Yellow
                return
            }
            if ($diffResult.ExitCode -ne 1) {
                throw "git diff --cached --quiet failed with exit code $($diffResult.ExitCode): $($diffResult.Output)"
            }

            Invoke-FeedbackGit -Arguments @('commit', '-m', 'Update winmatsch feedback state [skip ci]', '--', $relativePath) | Out-Null

            $pushResult = Invoke-FeedbackGit -Arguments @(
                'push',
                $remoteName,
                "HEAD:refs/heads/$remoteBranch"
            ) -AllowFailure
            if ($pushResult.ExitCode -eq 0) {
                Write-Host "WinMatsch feedback state committed and pushed successfully." -ForegroundColor Green
                return
            }

            $isNonFastForward = $pushResult.Output -match '(?i)non-fast-forward|fetch first|failed to push some refs|\[rejected\]'
            if (-not $isNonFastForward) {
                throw "Failed to push WinMatsch feedback state update: $($pushResult.Output)"
            }
            if ($attempt -eq $MaxPushAttempts) {
                throw "Failed to push WinMatsch feedback state update after $MaxPushAttempts attempts: $($pushResult.Output)"
            }

            Write-Warning "WinMatsch feedback state push raced with another writer; retrying: $($pushResult.Output)"
            Start-Sleep -Seconds ([Math]::Min($attempt, 3))
        }
    }
    catch {
        if ($remoteName -and $remoteBranch -and $upstreamRef) {
            Invoke-FeedbackGit -Arguments @(
                'fetch',
                '--no-tags',
                $remoteName,
                "+refs/heads/${remoteBranch}:refs/remotes/${remoteName}/${remoteBranch}"
            ) -AllowFailure | Out-Null
            Invoke-FeedbackGit -Arguments @('reset', '--hard', $upstreamRef) -AllowFailure | Out-Null
        }

        try {
            Clear-InterruptedFeedbackGitOperation
        }
        catch {
            Write-Warning $_
        }

        throw
    }
    finally {
        Pop-Location
    }
}
