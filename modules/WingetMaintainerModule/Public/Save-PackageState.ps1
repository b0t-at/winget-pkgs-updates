function Save-PackageState {
    <#
    .SYNOPSIS
        Merges, commits, and pushes the package state file to the repository.

    .DESCRIPTION
        Computes the local JSON changes relative to the checked-out commit, merges
        them with the latest upstream state at package/field granularity, and pushes
        the resulting commit. Non-fast-forward push races are retried boundedly.
        Concurrent changes to the same scalar value fail rather than dropping data.

    .PARAMETER StateFilePath
        Path to the package-state.json file (relative or absolute).

    .PARAMETER RepoPath
        Path to the repository working directory. Defaults to current directory.

    .PARAMETER MaxPushAttempts
        Maximum number of fetch/merge/commit/push attempts for non-fast-forward races.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $false)]
        [string] $RepoPath = '.',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int] $MaxPushAttempts = 3
    )

    function Invoke-StateGit {
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

    function Clear-InterruptedGitOperation {
        $gitDirectoryResult = Invoke-StateGit -Arguments @('rev-parse', '--git-dir')
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
            $cleanupResult = Invoke-StateGit -Arguments $command -AllowFailure
            if ($cleanupResult.ExitCode -ne 0) {
                throw "Failed to clean interrupted git operation with 'git $($command -join ' ')': $($cleanupResult.Output)"
            }
        }
    }

    function Read-StateJson {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Content,

            [Parameter(Mandatory = $true)]
            [string] $Source
        )

        try {
            $state = $Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw "Package state from $Source is not valid JSON: $_"
        }

        if ($state -isnot [System.Collections.IDictionary]) {
            throw "Package state from $Source must be a JSON object."
        }

        return $state
    }

    function Get-StateAtCommit {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Commit,

            [Parameter(Mandatory = $true)]
            [string] $RelativePath
        )

        $objectName = "${Commit}:$RelativePath"
        $existsResult = Invoke-StateGit -Arguments @('cat-file', '-e', $objectName) -AllowFailure
        if ($existsResult.ExitCode -ne 0) {
            return @{}
        }

        $contentResult = Invoke-StateGit -Arguments @('show', $objectName)
        return Read-StateJson -Content $contentResult.Output -Source $objectName
    }

    function Test-StateValueEqual {
        param(
            [Parameter(Mandatory = $true)]
            [bool] $LeftExists,

            [Parameter(Mandatory = $false)]
            [AllowNull()]
            [object] $Left,

            [Parameter(Mandatory = $true)]
            [bool] $RightExists,

            [Parameter(Mandatory = $false)]
            [AllowNull()]
            [object] $Right
        )

        if ($LeftExists -ne $RightExists) {
            return $false
        }
        if (-not $LeftExists) {
            return $true
        }
        if ($null -eq $Left -or $null -eq $Right) {
            return $null -eq $Left -and $null -eq $Right
        }

        if ($Left -is [System.Collections.IDictionary] -and
            $Right -is [System.Collections.IDictionary]) {
            if ($Left.Count -ne $Right.Count) {
                return $false
            }

            foreach ($key in $Left.Keys) {
                if (-not $Right.Contains($key)) {
                    return $false
                }
                if (-not (Test-StateValueEqual -LeftExists $true -Left $Left[$key] -RightExists $true -Right $Right[$key])) {
                    return $false
                }
            }

            return $true
        }

        $leftIsArray = $Left -is [System.Collections.IEnumerable] -and $Left -isnot [string]
        $rightIsArray = $Right -is [System.Collections.IEnumerable] -and $Right -isnot [string]
        if ($leftIsArray -or $rightIsArray) {
            if (-not ($leftIsArray -and $rightIsArray)) {
                return $false
            }

            $leftItems = @($Left)
            $rightItems = @($Right)
            if ($leftItems.Count -ne $rightItems.Count) {
                return $false
            }

            for ($index = 0; $index -lt $leftItems.Count; $index++) {
                if (-not (Test-StateValueEqual -LeftExists $true -Left $leftItems[$index] -RightExists $true -Right $rightItems[$index])) {
                    return $false
                }
            }

            return $true
        }

        return $Left.GetType() -eq $Right.GetType() -and $Left -ceq $Right
    }

    function Merge-StateObject {
        param(
            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary] $Base,

            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary] $Local,

            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary] $Remote,

            [Parameter(Mandatory = $false)]
            [string] $Path = '$'
        )

        $keys = @($Base.Keys) + @($Local.Keys) + @($Remote.Keys) |
            Sort-Object -Unique
        $result = [ordered]@{}

        foreach ($key in $keys) {
            $baseExists = $Base.Contains($key)
            $localExists = $Local.Contains($key)
            $remoteExists = $Remote.Contains($key)
            $baseValue = if ($baseExists) { $Base[$key] } else { $null }
            $localValue = if ($localExists) { $Local[$key] } else { $null }
            $remoteValue = if ($remoteExists) { $Remote[$key] } else { $null }
            $childPath = "$Path.$key"

            $localMatchesBase = Test-StateValueEqual -LeftExists $localExists -Left $localValue -RightExists $baseExists -Right $baseValue
            $remoteMatchesBase = Test-StateValueEqual -LeftExists $remoteExists -Left $remoteValue -RightExists $baseExists -Right $baseValue
            $localMatchesRemote = Test-StateValueEqual -LeftExists $localExists -Left $localValue -RightExists $remoteExists -Right $remoteValue

            if ($localMatchesBase) {
                if ($remoteExists) {
                    $result[$key] = $remoteValue
                }
                continue
            }

            if ($remoteMatchesBase -or $localMatchesRemote) {
                if ($localExists) {
                    $result[$key] = $localValue
                }
                continue
            }

            if ($baseExists -and $localExists -and $remoteExists -and
                $baseValue -is [System.Collections.IDictionary] -and
                $localValue -is [System.Collections.IDictionary] -and
                $remoteValue -is [System.Collections.IDictionary]) {
                $result[$key] = Merge-StateObject -Base $baseValue -Local $localValue -Remote $remoteValue -Path $childPath
                continue
            }

            throw "Concurrent package state conflict at '$childPath'. Both writers changed the same value."
        }

        return $result
    }

    function Write-StateJson {
        param(
            [Parameter(Mandatory = $true)]
            [System.Collections.IDictionary] $State,

            [Parameter(Mandatory = $true)]
            [string] $Path
        )

        $State | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8 -Force
    }

    Push-Location -Path $RepoPath
    $upstreamRef = $null
    $remoteName = $null
    $remoteBranch = $null

    try {
        Clear-InterruptedGitOperation

        $repositoryRoot = (Invoke-StateGit -Arguments @('rev-parse', '--show-toplevel')).Output.Trim()
        $stateFullPath = if ([IO.Path]::IsPathRooted($StateFilePath)) {
            [IO.Path]::GetFullPath($StateFilePath)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $StateFilePath))
        }
        $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $stateFullPath).Replace('\', '/')
        if ($relativePath -eq '..' -or $relativePath.StartsWith('../')) {
            throw "State file '$stateFullPath' must be inside repository '$repositoryRoot'."
        }
        if (-not (Test-Path -LiteralPath $stateFullPath -PathType Leaf)) {
            throw "Package state file not found: $stateFullPath"
        }

        $changedPaths = @()
        $changedPaths += (Invoke-StateGit -Arguments @('diff', '--name-only')).Output -split "`n"
        $changedPaths += (Invoke-StateGit -Arguments @('diff', '--cached', '--name-only')).Output -split "`n"
        $otherChangedPaths = @($changedPaths |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim() -ne $relativePath } |
                Sort-Object -Unique)
        if ($otherChangedPaths.Count -gt 0) {
            throw "Refusing to reset repository with unrelated tracked changes: $($otherChangedPaths -join ', ')"
        }

        $baseCommit = (Invoke-StateGit -Arguments @('rev-parse', 'HEAD')).Output.Trim()
        $baseState = Get-StateAtCommit -Commit $baseCommit -RelativePath $relativePath
        $localState = Read-StateJson -Content (Get-Content -LiteralPath $stateFullPath -Raw -ErrorAction Stop) -Source $stateFullPath
        if (Test-StateValueEqual -LeftExists $true -Left $localState -RightExists $true -Right $baseState) {
            Write-Host "No changes to package state file — nothing to commit." -ForegroundColor Yellow
            return
        }

        $branch = (Invoke-StateGit -Arguments @('symbolic-ref', '--quiet', '--short', 'HEAD')).Output.Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            throw 'Save-PackageState requires a checked-out branch; detached HEAD is not supported.'
        }

        $upstreamResult = Invoke-StateGit -Arguments @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -AllowFailure
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
            Write-Host "Saving package state (attempt $attempt of $MaxPushAttempts)..."
            Invoke-StateGit -Arguments @(
                'fetch',
                '--no-tags',
                $remoteName,
                "+refs/heads/${remoteBranch}:refs/remotes/${remoteName}/${remoteBranch}"
            ) | Out-Null

            $remoteCommit = (Invoke-StateGit -Arguments @('rev-parse', $upstreamRef)).Output.Trim()
            $remoteState = Get-StateAtCommit -Commit $remoteCommit -RelativePath $relativePath
            $mergedState = Merge-StateObject -Base $baseState -Local $localState -Remote $remoteState

            Invoke-StateGit -Arguments @('reset', '--hard', $remoteCommit) | Out-Null
            Write-StateJson -State $mergedState -Path $stateFullPath

            if (Test-StateValueEqual -LeftExists $true -Left $mergedState -RightExists $true -Right $remoteState) {
                Write-Host "Package state changes are already present upstream — nothing to commit." -ForegroundColor Yellow
                return
            }

            Invoke-StateGit -Arguments @('add', '--', $relativePath) | Out-Null
            Invoke-StateGit -Arguments @('commit', '-m', 'Update package validation state [skip ci]', '--', $relativePath) | Out-Null

            $pushResult = Invoke-StateGit -Arguments @(
                'push',
                $remoteName,
                "HEAD:refs/heads/$remoteBranch"
            ) -AllowFailure
            if ($pushResult.ExitCode -eq 0) {
                Write-Host "Package state file committed and pushed successfully." -ForegroundColor Green
                return
            }

            $isNonFastForward = $pushResult.Output -match '(?i)non-fast-forward|fetch first|failed to push some refs|\[rejected\]'
            if (-not $isNonFastForward) {
                throw "Failed to push package state update: $($pushResult.Output)"
            }
            if ($attempt -eq $MaxPushAttempts) {
                throw "Failed to push package state update after $MaxPushAttempts attempts: $($pushResult.Output)"
            }

            Write-Warning "Package state push raced with another writer; retrying: $($pushResult.Output)"
            Start-Sleep -Seconds ([Math]::Min($attempt, 3))
        }
    }
    catch {
        if ($remoteName -and $remoteBranch -and $upstreamRef) {
            Invoke-StateGit -Arguments @(
                'fetch',
                '--no-tags',
                $remoteName,
                "+refs/heads/${remoteBranch}:refs/remotes/${remoteName}/${remoteBranch}"
            ) -AllowFailure | Out-Null
            Invoke-StateGit -Arguments @('reset', '--hard', $upstreamRef) -AllowFailure | Out-Null
        }

        try {
            Clear-InterruptedGitOperation
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
