$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru

function Write-FeedbackItem {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [int] $PullRequestNumber,

        [Parameter(Mandatory = $true)]
        [string] $RecordedAt
    )

    @{
        pullRequestNumber = $PullRequestNumber
        recordedAt        = $RecordedAt
        reason            = 'InstallationFailure'
    } | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding utf8
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "WinMatschFeedbackPrune-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $now = [datetimeoffset]'2026-09-28T08:00:00Z'

    Write-FeedbackItem -Path (Join-Path $testRoot 'merged-100.json') -PullRequestNumber 100 -RecordedAt '2026-09-25T00:00:00Z'
    Write-FeedbackItem -Path (Join-Path $testRoot 'expired-101.json') -PullRequestNumber 101 -RecordedAt '2026-08-01T00:00:00Z'
    Write-FeedbackItem -Path (Join-Path $testRoot 'open-102.json') -PullRequestNumber 102 -RecordedAt '2026-09-25T00:00:00Z'
    Write-FeedbackItem -Path (Join-Path $testRoot 'lookup-failed-103.json') -PullRequestNumber 103 -RecordedAt '2026-09-25T00:00:00Z'
    Set-Content -LiteralPath (Join-Path $testRoot 'merged-100.json.lock') -Value '' -NoNewline

    Write-Host 'TEST: stale WinMatsch feedback is pruned by merged PRs and age, with lookup failures kept'
    $result = & $module {
        param($FeedbackDirectory, $Now)

        function gh {
            param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

            $path = $Arguments | Where-Object { $_ -match '^repos/' } | Select-Object -First 1
            if (-not $path) { throw "Unexpected gh arguments: $($Arguments -join ' ')" }

            $pullRequestNumber = [int]($path -replace '^repos/microsoft/winget-pkgs/pulls/', '')
            switch ($pullRequestNumber) {
                100 {
                    $global:LASTEXITCODE = 0
                    return '{"merged_at":"2026-09-26T00:00:00Z"}'
                }
                102 {
                    $global:LASTEXITCODE = 0
                    return '{"merged_at":null}'
                }
                103 {
                    $global:LASTEXITCODE = 1
                    return 'not found'
                }
                default {
                    throw "Unexpected PR lookup: $pullRequestNumber"
                }
            }
        }

        Remove-StaleWinMatschFeedback -FeedbackDirectory $FeedbackDirectory -RetentionDays 30 -Now $Now
    } $testRoot $now

    if (Test-Path -LiteralPath (Join-Path $testRoot 'merged-100.json')) {
        throw 'Merged PR feedback was not pruned.'
    }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'expired-101.json')) {
        throw 'Expired feedback was not pruned.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'open-102.json'))) {
        throw 'Open PR feedback should have been kept.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'lookup-failed-103.json'))) {
        throw 'Lookup failures must keep feedback fail-safe.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testRoot 'merged-100.json.lock'))) {
        throw 'Pruning JSON feedback must not manage lock files.'
    }

    $byFile = @{}
    foreach ($entry in $result) { $byFile[$entry.File] = $entry }
    if ($byFile['merged-100.json'].Reason -cne 'Merged') {
        throw "Merged feedback result was not reported: $($result | ConvertTo-Json -Compress)"
    }
    if ($byFile['expired-101.json'].Reason -cne 'Expired') {
        throw "Expired feedback result was not reported: $($result | ConvertTo-Json -Compress)"
    }
    if ($byFile['lookup-failed-103.json'].Reason -cne 'LookupFailed') {
        throw "Lookup failure result was not reported: $($result | ConvertTo-Json -Compress)"
    }

    Write-Host 'All Remove-StaleWinMatschFeedback regression tests passed.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
