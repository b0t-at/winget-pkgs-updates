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

function Assert-Equal {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $Actual,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $Expected,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
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

function Write-TestState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State
    )

    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-StateEntry {
    param(
        [string] $State = 'VALIDATION_FAILED',
        [string] $Description = ''
    )

    return [ordered]@{
        version         = '1.0.0'
        manifestHash    = 'manifest-hash'
        installerHashes = @('installer-hash')
        state           = $State
        validationCount = 1
        description     = $Description
        lastUpdated     = '2026-08-04T00:00:00.0000000Z'
    }
}

function New-TestRepositories {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root
    )

    $remote = Join-Path $Root 'remote.git'
    $seed = Join-Path $Root 'seed'
    $writerA = Join-Path $Root 'writer-a'
    $writerB = Join-Path $Root 'writer-b'

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-TestGit -Repository $Root -Arguments @('init', '--bare', $remote) | Out-Null
    Invoke-TestGit -Repository $Root -Arguments @('init', $seed) | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('config', 'user.name', 'State Test') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('config', 'user.email', 'state-test@example.invalid') | Out-Null

    $statePath = Join-Path $seed 'data/package-state.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $statePath) -Force | Out-Null
    Write-TestState -Path $statePath -State ([ordered]@{
            'Shared.Package' = New-StateEntry -Description 'base description'
        })
    Invoke-TestGit -Repository $seed -Arguments @('add', 'data/package-state.json') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('commit', '-m', 'Initial state') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('branch', '-M', 'main') | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('remote', 'add', 'origin', $remote) | Out-Null
    Invoke-TestGit -Repository $seed -Arguments @('push', '-u', 'origin', 'main') | Out-Null

    Invoke-TestGit -Repository $Root -Arguments @('clone', '--branch', 'main', $remote, $writerA) | Out-Null
    Invoke-TestGit -Repository $Root -Arguments @('clone', '--branch', 'main', $remote, $writerB) | Out-Null
    foreach ($writer in @($writerA, $writerB)) {
        Invoke-TestGit -Repository $writer -Arguments @('config', 'user.name', 'State Test') | Out-Null
        Invoke-TestGit -Repository $writer -Arguments @('config', 'user.email', 'state-test@example.invalid') | Out-Null
    }

    return [pscustomobject]@{
        Remote  = $remote
        WriterA = $writerA
        WriterB = $writerB
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "Save-PackageState-$([guid]::NewGuid().ToString('N'))"

try {
    Write-Host 'TEST: divergent writers reproduce a rebase conflict and merge without data loss'
    $repos = New-TestRepositories -Root (Join-Path $testRoot 'merge')
    $writerAStatePath = Join-Path $repos.WriterA 'data/package-state.json'
    $writerBStatePath = Join-Path $repos.WriterB 'data/package-state.json'

    $writerAState = Get-Content -LiteralPath $writerAStatePath -Raw | ConvertFrom-Json -AsHashtable
    $writerAState['Shared.Package']['description'] = 'description from writer A'
    $writerAState['WriterA.Package'] = New-StateEntry -Description 'writer A package'
    Write-TestState -Path $writerAStatePath -State $writerAState
    Save-PackageState -StateFilePath $writerAStatePath -RepoPath $repos.WriterA

    $writerBState = Get-Content -LiteralPath $writerBStatePath -Raw | ConvertFrom-Json -AsHashtable
    $writerBState['Shared.Package']['state'] = 'VALIDATION_PASSED'
    $writerBState['WriterB.Package'] = New-StateEntry -State 'VALIDATION_PASSED' -Description 'writer B package'
    Write-TestState -Path $writerBStatePath -State $writerBState

    Invoke-TestGit -Repository $repos.WriterB -Arguments @('add', 'data/package-state.json') | Out-Null
    Invoke-TestGit -Repository $repos.WriterB -Arguments @('commit', '-m', 'Divergent state update') | Out-Null
    $rebaseResult = Invoke-TestGit -Repository $repos.WriterB -Arguments @('pull', '--rebase') -AllowFailure
    Assert-True -Condition ($rebaseResult.ExitCode -ne 0) -Message 'The divergent whole-file update should reproduce the original rebase failure.'
    Assert-True -Condition ($rebaseResult.Output -match 'CONFLICT') -Message 'The reproduced rebase failure should be a content conflict.'
    Invoke-TestGit -Repository $repos.WriterB -Arguments @('rebase', '--abort') | Out-Null
    Invoke-TestGit -Repository $repos.WriterB -Arguments @('reset', '--mixed', 'HEAD~1') | Out-Null

    Save-PackageState -StateFilePath 'data/package-state.json' -RepoPath $repos.WriterB

    $verificationClone = Join-Path $testRoot 'verification'
    Invoke-TestGit -Repository $testRoot -Arguments @('clone', '--branch', 'main', $repos.Remote, $verificationClone) | Out-Null
    $mergedState = Get-Content -LiteralPath (Join-Path $verificationClone 'data/package-state.json') -Raw |
        ConvertFrom-Json -AsHashtable
    Assert-True -Condition $mergedState.ContainsKey('WriterA.Package') -Message 'Writer A package entry was lost.'
    Assert-True -Condition $mergedState.ContainsKey('WriterB.Package') -Message 'Writer B package entry was lost.'
    Assert-Equal -Actual $mergedState['Shared.Package']['description'] -Expected 'description from writer A' -Message 'Writer A field update was lost.'
    Assert-Equal -Actual $mergedState['Shared.Package']['state'] -Expected 'VALIDATION_PASSED' -Message 'Writer B field update was lost.'

    Write-Host 'TEST: retry exhaustion fails loudly and leaves a clean repository'
    $retryRepos = New-TestRepositories -Root (Join-Path $testRoot 'retry')
    $retryStatePath = Join-Path $retryRepos.WriterB 'data/package-state.json'
    $retryState = Get-Content -LiteralPath $retryStatePath -Raw | ConvertFrom-Json -AsHashtable
    $retryState['Retry.Package'] = New-StateEntry -Description 'must not be silently dropped'
    Write-TestState -Path $retryStatePath -State $retryState

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
        Save-PackageState -StateFilePath $retryStatePath -RepoPath $retryRepos.WriterB -MaxPushAttempts 2
    }
    catch {
        $caught = $_
    }

    Assert-True -Condition ($null -ne $caught) -Message 'Retry exhaustion should throw.'
    Assert-True -Condition ($caught.Exception.Message -match 'after 2 attempts') -Message 'Retry exhaustion should report the bounded attempt count.'
    Assert-Equal -Actual @((Get-Content -LiteralPath $counterPath)).Count -Expected 2 -Message 'Push should be attempted exactly twice.'
    Assert-Equal -Actual (Invoke-TestGit -Repository $retryRepos.WriterB -Arguments @('status', '--porcelain')).Output -Expected '' -Message 'Repository should be clean after retry exhaustion.'

    $gitDirectory = (Invoke-TestGit -Repository $retryRepos.WriterB -Arguments @('rev-parse', '--git-dir')).Output
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
        $gitDirectory = Join-Path $retryRepos.WriterB $gitDirectory
    }
    foreach ($operationPath in @('rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD')) {
        Assert-True -Condition (-not (Test-Path (Join-Path $gitDirectory $operationPath))) -Message "Interrupted git operation remains at $operationPath."
    }

    Write-Host 'All Save-PackageState regression tests passed.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
