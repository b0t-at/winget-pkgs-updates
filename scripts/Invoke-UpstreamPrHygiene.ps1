# Scheduled hygiene sweep over this bot's own open microsoft/winget-pkgs
# pull requests.
#
# Two situations produce noise the moderators should never see:
#   * an older-version PR stays open after a newer version was submitted, and
#   * a PR stays open although its exact version is already published.
# Both are closed here (with a short comment); everything else is only
# reported, grouped by validation labels, so stuck PRs stay visible without
# any risky automation.
#
# Inputs (environment):
#   GH_TOKEN                    Token used by gh for search and closing (the
#                               PRs belong to this token's account).
#   WINGET_PKGS_REPOSITORY      Target repository (default microsoft/winget-pkgs).
#   BOT_LOGIN                   GitHub login whose PRs are swept. Required.
#   DRY_RUN                     'true' plans but never closes.
#   MAX_CLOSES                  Per-run close cap (default 10).
#   GITHUB_STEP_SUMMARY         Markdown summary target (optional).
$ErrorActionPreference = 'Stop'

$module = Import-Module (Join-Path $PSScriptRoot '..' 'modules' 'WingetMaintainerModule' 'WingetMaintainerModule.psd1') -Force -PassThru

$repository = if ([string]::IsNullOrWhiteSpace($env:WINGET_PKGS_REPOSITORY)) { 'microsoft/winget-pkgs' } else { $env:WINGET_PKGS_REPOSITORY.Trim() }
$botLogin = "$env:BOT_LOGIN".Trim()
if ([string]::IsNullOrWhiteSpace($botLogin) -and "$env:WINGET_PKGS_FORK_REPO".Trim() -match '^(?<Owner>[A-Za-z0-9_.-]+)/') {
    # The fork owner is the account whose PAT opens the upstream PRs.
    $botLogin = $Matches['Owner']
}
if ([string]::IsNullOrWhiteSpace($botLogin)) {
    throw 'BOT_LOGIN (or WINGET_PKGS_FORK_REPO) is required so the sweep can never touch anyone else''s pull requests.'
}
$dryRun = "$env:DRY_RUN" -eq 'true'
$maxCloses = 10
if (-not [string]::IsNullOrWhiteSpace($env:MAX_CLOSES) -and [int]::TryParse($env:MAX_CLOSES.Trim(), [ref] $maxCloses)) {
    $maxCloses = [Math]::Max(0, $maxCloses)
}

Write-Host "Sweeping open PRs by $botLogin in $repository (dry run: $dryRun, close cap: $maxCloses)."

$openPrsJson = gh pr list --repo $repository --author $botLogin --state open --limit 200 --json number,title,url,labels
if ($LASTEXITCODE -ne 0) {
    throw "gh pr list failed with exit code $LASTEXITCODE."
}
$openPrs = @($openPrsJson | ConvertFrom-Json)
Write-Host "Found $($openPrs.Count) open PR(s)."

# The published-version resolver runs inside the module scope because the
# GitHub helpers it needs are private module functions.
$actions = @(& $module {
        param($OpenPrs, $Repository)

        # GetNewClosure pins $Repository for the resolver regardless of the
        # dynamic scope it is eventually invoked from.
        $resolver = {
            param([string] $PackageIdentifier)
            try {
                $published = Get-WingetPublishedVersionsFromGitHub -PackageIdentifier $PackageIdentifier -Repository $Repository
                if ($published.PackageExists) { @($published.Versions) } else { @() }
            }
            catch {
                Write-Warning "Published-version lookup failed for ${PackageIdentifier}: $($_.Exception.Message); treating as not published."
                @()
            }
        }.GetNewClosure()

        Select-WingetHygienePrActions -OpenPrs $OpenPrs -PublishedVersionsResolver $resolver
    } $openPrs $repository)

$toClose = @($actions | Where-Object { $_.Action -in @('close-superseded', 'close-published') })
$kept = @($actions | Where-Object { $_.Action -eq 'keep' })

$closed = [System.Collections.Generic.List[object]]::new()
$closeFailures = [System.Collections.Generic.List[string]]::new()

foreach ($action in $toClose) {
    if ($closed.Count -ge $maxCloses) {
        Write-Warning "Close cap of $maxCloses reached; leaving PR #$($action.Number) for the next run."
        continue
    }

    $comment = "Closing this automated update: $($action.Reason). This keeps the review queue free of superseded submissions."
    if ($dryRun) {
        Write-Host "[dry-run] Would close #$($action.Number) ($($action.Title)) - $($action.Reason)"
        $closed.Add($action)
        continue
    }

    gh pr close $action.Number --repo $repository --comment $comment
    if ($LASTEXITCODE -ne 0) {
        $closeFailures.Add("PR #$($action.Number) could not be closed (gh exit code $LASTEXITCODE).")
        continue
    }
    Write-Host "Closed #$($action.Number) ($($action.Title)) - $($action.Reason)"
    $closed.Add($action)
}

$attentionLabels = @('Validation-Executable-Error', 'Validation-Defender-Error', 'URL-Validation-Error', 'Internal-Error-Dynamic-Scan', 'Manifest-Metadata-Consistency', 'Needs-Attention', 'Needs-Author-Feedback', 'Validation-Certificate-Root')
$needsAttention = @($kept | Where-Object { @($_.Labels | Where-Object { $_ -in $attentionLabels }).Count -gt 0 })

$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('## Upstream PR hygiene')
$summary.Add('')
$modeNote = if ($dryRun) { ' (dry run - nothing was closed)' } else { '' }
$summary.Add("Open PRs: **$($openPrs.Count)** | closed this run: **$($closed.Count)**$modeNote | kept: $($kept.Count)")
$summary.Add('')

if ($closed.Count -gt 0) {
    $summary.Add('### Closed as superseded/published')
    $summary.Add('')
    $summary.Add('| PR | Package | Version | Reason |')
    $summary.Add('| --- | --- | --- | --- |')
    foreach ($row in $closed) {
        $summary.Add("| #$($row.Number) | $($row.PackageIdentifier) | $($row.Version) | $($row.Reason.Replace('|', '\|')) |")
    }
    $summary.Add('')
}

if ($needsAttention.Count -gt 0) {
    $summary.Add('### :warning: Open PRs with validation errors (need a human or a retry)')
    $summary.Add('')
    $summary.Add('| PR | Package | Version | Labels |')
    $summary.Add('| --- | --- | --- | --- |')
    foreach ($row in ($needsAttention | Sort-Object -Property Number)) {
        $labelText = (@($row.Labels | Where-Object { $_ -in $attentionLabels }) -join ', ')
        $summary.Add("| #$($row.Number) | $($row.PackageIdentifier) | $($row.Version) | $labelText |")
    }
    $summary.Add('')
}

foreach ($failure in $closeFailures) {
    $summary.Add(":x: $failure")
}

$summaryText = $summary -join "`n"
Write-Host $summaryText
if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $summaryText | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append
}

if ($closeFailures.Count -gt 0) {
    exit 1
}
