function Save-PackageState {
    <#
    .SYNOPSIS
        Commits and pushes the package state file to the repository.

    .DESCRIPTION
        Performs git add, commit, and push for the state file. Handles the case where
        nothing has changed (no error if state is unchanged).

    .PARAMETER StateFilePath
        Path to the package-state.json file (relative or absolute).

    .PARAMETER RepoPath
        Path to the repository working directory. Defaults to current directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $false)]
        [string] $RepoPath = '.'
    )

    Push-Location -Path $RepoPath

    try {
        # Get the relative path for git operations
        $relativePath = Resolve-Path -Path $StateFilePath -Relative -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            $relativePath = $StateFilePath
        }

        git add $relativePath

        # Check if there are staged changes for this file
        $status = git diff --cached --name-only
        if ([string]::IsNullOrWhiteSpace($status)) {
            Write-Host "No changes to package state file — nothing to commit." -ForegroundColor Yellow
            return
        }

        git commit -m "Update package validation state [skip ci]"

        # Rebase our commit on top of any commits pushed since checkout (e.g. by
        # orchestrate-gh-packages or a concurrent unrelated push) so that a clean
        # fast-forward push is always possible.  If a genuine conflict occurs on
        # package-state.json itself, the rebase will fail loudly here rather than
        # silently losing data on push.
        $rebaseResult = git pull --rebase 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git pull --rebase failed: $rebaseResult"
            throw "Failed to rebase package state update: $rebaseResult"
        }

        $pushResult = git push 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "git push failed: $pushResult"
            throw "Failed to push package state update: $pushResult"
        }

        Write-Host "Package state file committed and pushed successfully." -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
}
