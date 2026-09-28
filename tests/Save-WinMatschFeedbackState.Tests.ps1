$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repository,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,

        [Parameter(Mandatory = $false)]
        [switch] $AllowFailure
    )

    $output = @(& git -C $Repository @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git -C $Repository $($Arguments -join ' ') failed with exit code ${exitCode}: $text"
    }

    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Condition,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-FeedbackTestRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $remote = Join-Path $Root 'remote.git'
    $seed = Join-Path $Root 'seed'
    $writer = Join-Path $Root 'writer'

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-TestGit -Repository $Root -Arguments @('init', '--bare', $remote) | Out-Null
    Invoke-TestGit -Repository $Root -Arguments @('init', $seed) | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('config', 'user.name', 'Feedback Test') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('config', 'user.email', 'feedback-test@example.invalid') | Out-Null

    $feedbackPath = Join-Path $seed 'data/winmatsch-feedback'
    New-Item -ItemType Directory -Path $feedbackPath -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $feedbackPath 'README.md') -Value 'Committed feedback store.' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $feedbackPath 'stale-1.json') -Value '{"stale":true}' -Encoding utf8
    Invoke-TestGit -Repository $seed -Arguments @('add', 'data/winmatsch-feedback') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('commit', '-m', 'Initial feedback state') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('branch', '-M', 'main') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('remote', 'add', 'origin', $remote) | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    Invoke-TestGit -Repository $Root -Arguments @('clone', '--branch', 'main', $remote, $writer) | Out-Null
    Invoke-TestGit -Repository $writer -Arguments @('config', 'user.name', 'Feedback Test') | Out-Null
    Invoke-TestGit -Repository $writer -Arguments @('config', 'user.email', 'feedback-test@example.invalid') | Out-Null

    return [pscustomobject]@{
        Remote = $remote
        Writer = $writer
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "Save-WinMatschFeedbackState-$([guid]::NewGuid().ToString('N'))"

try {
    Write-Host 'TEST: feedback state replacement commits JSON and ignores lock files'
    $repos = New-FeedbackTestRepositories -Root (Join-Path $testRoot 'replace')
    $artifact = Join-Path $testRoot 'artifact'
    New-Item -ItemType Directory -Path $artifact -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $artifact 'verdict-432850.json') -Value '{"package":"DiRoots.ProSheets"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $artifact 'verdict-432850.json.lock') -Value '' -NoNewline
    Set-Content -LiteralPath (Join-Path $artifact '.artifact-ready') -Value 'true' -NoNewline

    Save-WinMatschFeedbackState -FeedbackSourcePath $artifact -RepoPath $repos.Writer

    $verification = Join-Path $testRoot 'verification'
    Invoke-TestGit -Repository $testRoot -Arguments @('clone', '--branch', 'main', $repos.Remote, $verification) | Out-Null
    $feedbackPath = Join-Path $verification 'data/winmatsch-feedback'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $feedbackPath 'verdict-432850.json') -PathType Leaf) -Message 'New feedback JSON was not committed.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $feedbackPath 'verdict-432850.json.lock'))) -Message 'Feedback lock file was committed.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $feedbackPath 'stale-1.json'))) -Message 'Stale feedback JSON was not removed.'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $feedbackPath 'README.md') -PathType Leaf) -Message 'Feedback README should be preserved.'

    $lastMessage = (Invoke-TestGit -Repository $verification -Arguments @('log', '-1', '--pretty=%s')).Output
    Assert-True -Condition ($lastMessage -ceq 'Update winmatsch feedback state [skip ci]') -Message "Unexpected feedback commit message: $lastMessage"

    Write-Host 'TEST: feedback state replacement is refused without the artifact-ready marker'
    $missingMarkerRepos = New-FeedbackTestRepositories -Root (Join-Path $testRoot 'missing-marker')
    $missingMarkerArtifact = Join-Path $testRoot 'missing-marker-artifact'
    New-Item -ItemType Directory -Path $missingMarkerArtifact -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $missingMarkerArtifact 'verdict-999999.json') -Value '{"package":"Should.NotPersist"}' -Encoding utf8

    Save-WinMatschFeedbackState -FeedbackSourcePath $missingMarkerArtifact -RepoPath $missingMarkerRepos.Writer

    $missingMarkerVerification = Join-Path $testRoot 'missing-marker-verification'
    Invoke-TestGit -Repository $testRoot -Arguments @('clone', '--branch', 'main', $missingMarkerRepos.Remote, $missingMarkerVerification) | Out-Null
    $missingMarkerFeedbackPath = Join-Path $missingMarkerVerification 'data/winmatsch-feedback'
    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $missingMarkerFeedbackPath 'stale-1.json') -PathType Leaf) -Message 'Existing feedback JSON was removed despite missing artifact-ready marker.'
    Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $missingMarkerFeedbackPath 'verdict-999999.json'))) -Message 'Unready feedback artifact was committed.'
    $missingMarkerLastMessage = (Invoke-TestGit -Repository $missingMarkerVerification -Arguments @('log', '-1', '--pretty=%s')).Output
    Assert-True -Condition ($missingMarkerLastMessage -ceq 'Initial feedback state') -Message "A missing-marker artifact should not create a commit: $missingMarkerLastMessage"

    Write-Host 'TEST: retry exhaustion fails loudly and leaves a clean repository'
    $retryRepos = New-FeedbackTestRepositories -Root (Join-Path $testRoot 'retry')
    $retryArtifact = Join-Path $testRoot 'retry-artifact'
    New-Item -ItemType Directory -Path $retryArtifact -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $retryArtifact 'retry-1.json') -Value '{"retry":true}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $retryArtifact '.artifact-ready') -Value 'true' -NoNewline

    $counterPath = Join-Path $testRoot 'push-attempts.txt'
    $counterShellPath = $counterPath.Replace('\', '/')
    $hookPath = Join-Path $retryRepos.Remote 'hooks/pre-receive'
    @"
#!/bin/sh
echo attempt >> "$counterShellPath"
echo "non-fast-forward race injected by test" >&2
exit 1
"@ | Set-Content -LiteralPath $hookPath -Encoding utf8NoBOM
    if (-not $IsWindows) {
        $mode = [IO.File]::GetUnixFileMode($hookPath)
        [IO.File]::SetUnixFileMode(
            $hookPath,
            $mode -bor [IO.UnixFileMode]::UserExecute -bor
                [IO.UnixFileMode]::GroupExecute -bor
                [IO.UnixFileMode]::OtherExecute)
    }

    $caught = $null
    try {
        Save-WinMatschFeedbackState -FeedbackSourcePath $retryArtifact -RepoPath $retryRepos.Writer -MaxPushAttempts 2
    }
    catch {
        $caught = $_
    }

    Assert-True -Condition ($null -ne $caught) -Message 'Retry exhaustion should throw.'
    Assert-True -Condition ($caught.Exception.Message -match 'after 2 attempts') -Message 'Retry exhaustion should report the bounded attempt count.'
    Assert-True -Condition (@((Get-Content -LiteralPath $counterPath)).Count -eq 2) -Message 'Push should be attempted exactly twice.'
    Assert-True -Condition ((Invoke-TestGit -Repository $retryRepos.Writer -Arguments @('status', '--porcelain')).Output -eq '') -Message 'Repository should be clean after retry exhaustion.'

    Write-Host 'All Save-WinMatschFeedbackState regression tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
