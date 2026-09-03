$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru -WarningAction SilentlyContinue

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

$now = [datetime]::new(2026, 9, 3, 12, 0, 0, [DateTimeKind]::Utc)

# ---------------------------------------------------------------------------
Write-Host 'TEST: patch bump detection'
$patchCases = @(
    @{ Base = '2.6.5'; New = '2.6.6'; Expected = $true },
    @{ Base = '2.6.5'; New = '2.6.10'; Expected = $true },
    @{ Base = '2.6.5'; New = '2.7.0'; Expected = $false },
    @{ Base = '2.6.5'; New = '3.0.0'; Expected = $false },
    @{ Base = '2.47.3'; New = '2.48'; Expected = $false },
    @{ Base = '2.6.6'; New = '2.6.5'; Expected = $false },
    @{ Base = '2.6.5'; New = '2.6.5'; Expected = $false },
    @{ Base = '1.2'; New = '1.3'; Expected = $false },
    @{ Base = 'v2026.08.20'; New = '2026.08.21'; Expected = $true },
    @{ Base = ''; New = '1.0.1'; Expected = $false }
)
foreach ($case in $patchCases) {
    $actual = & $module { param($b, $n) Test-WingetVersionIsPatchBump -BaseVersion $b -NewVersion $n } $case.Base $case.New
    Assert-True ($actual -eq $case.Expected) "Test-WingetVersionIsPatchBump('$($case.Base)' -> '$($case.New)') returned $actual, expected $($case.Expected)."
}

# ---------------------------------------------------------------------------
Write-Host 'TEST: manual-validation queue PR holds a patch release'
$queuedPr = [PSCustomObject]@{
    number     = 426373
    title      = 'Update version: AnInsomniacy.Aria2Next version 2.6.8'
    labels     = @([PSCustomObject]@{ name = 'Azure-Pipeline-Passed' }, [PSCustomObject]@{ name = 'Validation-Executable-Error' })
    created_at = $now.AddDays(-5).ToString('o')
    html_url   = 'https://github.com/microsoft/winget-pkgs/pull/426373'
}
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'AnInsomniacy.Aria2Next' -NewVersion '2.6.9' -Now $now } @($queuedPr) $now
Assert-True ($null -ne $hold -and $hold.Number -eq 426373) "Expected PR 426373 to hold the patch release, got: $($hold | ConvertTo-Json -Compress)"
Assert-True ($hold.Reason -match 'Validation-Executable-Error') 'Hold reason must name the queue label.'

Write-Host 'TEST: Validation-No-Executables also counts as the queue label'
$noExecPr = [PSCustomObject]@{ number = 1; title = 'Update version: Foo.Bar version 1.0.0'; labels = @('Azure-Pipeline-Passed', 'Validation-No-Executables'); created_at = $now.AddDays(-1).ToString('o') }
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'Foo.Bar' -NewVersion '1.0.1' -Now $now } @($noExecPr) $now
Assert-True ($null -ne $hold) 'Validation-No-Executables did not hold the patch release.'

Write-Host 'TEST: non-patch release supersedes a queued PR'
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'AnInsomniacy.Aria2Next' -NewVersion '2.7.0' -Now $now } @($queuedPr) $now
Assert-True ($null -eq $hold) "Minor release must not be held: $($hold | ConvertTo-Json -Compress)"

Write-Host 'TEST: queued PR older than 14 days no longer holds'
$oldPr = $queuedPr.PSObject.Copy(); $oldPr.created_at = $now.AddDays(-15).ToString('o')
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'AnInsomniacy.Aria2Next' -NewVersion '2.6.9' -Now $now } @($oldPr) $now
Assert-True ($null -eq $hold) "15-day-old PR must not hold: $($hold | ConvertTo-Json -Compress)"

Write-Host 'TEST: PR without Azure-Pipeline-Passed does not hold'
$failedPr = $queuedPr.PSObject.Copy(); $failedPr.labels = @('Validation-Executable-Error')
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'AnInsomniacy.Aria2Next' -NewVersion '2.6.9' -Now $now } @($failedPr) $now
Assert-True ($null -eq $hold) "PR without pipeline pass must not hold: $($hold | ConvertTo-Json -Compress)"

Write-Host 'TEST: PR with only Azure-Pipeline-Passed does not hold'
$passedPr = $queuedPr.PSObject.Copy(); $passedPr.labels = @('Azure-Pipeline-Passed')
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'AnInsomniacy.Aria2Next' -NewVersion '2.6.9' -Now $now } @($passedPr) $now
Assert-True ($null -eq $hold) "Plain pipeline-passed PR must not hold: $($hold | ConvertTo-Json -Compress)"

Write-Host 'TEST: PR without a parsable age never holds'
$agelessPr = [PSCustomObject]@{ number = 2; title = 'Update version: Foo.Bar version 1.0.0'; labels = @('Azure-Pipeline-Passed', 'Validation-Executable-Error') }
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'Foo.Bar' -NewVersion '1.0.1' -Now $now } @($agelessPr) $now
Assert-True ($null -eq $hold) 'PR without created_at must not hold.'

Write-Host 'TEST: other packages and same/newer versions are ignored'
$otherPrs = @(
    [PSCustomObject]@{ number = 3; title = 'Update version: Foo.Baz version 1.0.0'; labels = @('Azure-Pipeline-Passed', 'Validation-Executable-Error'); created_at = $now.ToString('o') },
    [PSCustomObject]@{ number = 4; title = 'Update version: Foo.Bar version 1.0.1'; labels = @('Azure-Pipeline-Passed', 'Validation-Executable-Error'); created_at = $now.ToString('o') },
    [PSCustomObject]@{ number = 5; title = 'Update version: Foo.Bar version 1.0.2'; labels = @('Azure-Pipeline-Passed', 'Validation-Executable-Error'); created_at = $now.ToString('o') }
)
$hold = & $module { param($prs, $now) Select-WingetPatchSupersessionHold -OpenPrs $prs -PackageIdentifier 'Foo.Bar' -NewVersion '1.0.1' -Now $now } $otherPrs $now
Assert-True ($null -eq $hold) "Unrelated PRs must not hold: $($hold | ConvertTo-Json -Compress)"

# ---------------------------------------------------------------------------
Write-Host 'TEST: failure memory blocks a closed unmerged PR with a blocking label'
$closedBlocked = [PSCustomObject]@{
    number       = 426592
    title        = 'Update version: yhay81.sqrail version 0.3.4'
    state        = 'closed'
    labels       = @([PSCustomObject]@{ name = 'URL-Validation-Error' }, [PSCustomObject]@{ name = 'Needs-Author-Feedback' })
    pull_request = [PSCustomObject]@{ merged_at = $null }
    html_url     = 'https://github.com/microsoft/winget-pkgs/pull/426592'
}
$blocked = & $module { param($items) Find-WingetPkgsBlockedBotPr -PackageIdentifier 'yhay81.sqrail' -Version '0.3.4' -BotLogin 'damn-good-b0t' -SearchInvoker { $items } } @($closedBlocked)
Assert-True ($null -ne $blocked -and $blocked.Number -eq 426592) "Expected the closed URL-Validation-Error PR to block, got: $($blocked | ConvertTo-Json -Compress)"
Assert-True (@($blocked.Labels) -contains 'URL-Validation-Error' -and @($blocked.Labels) -notcontains 'Needs-Author-Feedback') 'Only blocking labels must be reported.'

Write-Host 'TEST: merged PR never blocks'
$merged = $closedBlocked.PSObject.Copy(); $merged.pull_request = [PSCustomObject]@{ merged_at = '2026-08-30T00:00:00Z' }
$blocked = & $module { param($items) Find-WingetPkgsBlockedBotPr -PackageIdentifier 'yhay81.sqrail' -Version '0.3.4' -BotLogin 'damn-good-b0t' -SearchInvoker { $items } } @($merged)
Assert-True ($null -eq $blocked) 'Merged PR must not block.'

Write-Host 'TEST: closed PR without blocking labels does not block'
$closedPlain = $closedBlocked.PSObject.Copy(); $closedPlain.labels = @('Needs-Author-Feedback', 'Manifest-Metadata-Consistency')
$blocked = & $module { param($items) Find-WingetPkgsBlockedBotPr -PackageIdentifier 'yhay81.sqrail' -Version '0.3.4' -BotLogin 'damn-good-b0t' -SearchInvoker { $items } } @($closedPlain)
Assert-True ($null -eq $blocked) 'Closed PR without blocking labels must not block.'

Write-Host 'TEST: a different version of the same package does not block'
$blocked = & $module { param($items) Find-WingetPkgsBlockedBotPr -PackageIdentifier 'yhay81.sqrail' -Version '0.3.5' -BotLogin 'damn-good-b0t' -SearchInvoker { $items } } @($closedBlocked)
Assert-True ($null -eq $blocked) 'A new upstream release must not be blocked by the previous version verdict.'

Write-Host 'TEST: every audited blocking label is honoured'
foreach ($label in @('Validation-Defender-Error', 'Binary-Validation-Error', 'Validation-Certificate-Root', 'URL-Validation-Error', 'Validation-Unattended-Failed', 'Validation-Installation-Error', 'Validation-Shell-Execute', 'Blocking-Issue', 'DriverInstall')) {
    $pr = $closedBlocked.PSObject.Copy(); $pr.labels = @($label)
    $blocked = & $module { param($items) Find-WingetPkgsBlockedBotPr -PackageIdentifier 'yhay81.sqrail' -Version '0.3.4' -BotLogin 'damn-good-b0t' -SearchInvoker { $items } } @($pr)
    Assert-True ($null -ne $blocked) "Label $label did not block."
}

# ---------------------------------------------------------------------------
Write-Host 'TEST: bot login resolution'
$originalBotLogin = $env:BOT_LOGIN
$originalForkRepo = $env:WINGET_PKGS_FORK_REPO
try {
    $env:BOT_LOGIN = ''
    $env:WINGET_PKGS_FORK_REPO = 'damn-good-b0t/winget-pkgs'
    Assert-True ((& $module { Get-WingetBotLogin }) -ceq 'damn-good-b0t') 'Fork owner must resolve as bot login.'
    $env:BOT_LOGIN = 'explicit-bot'
    Assert-True ((& $module { Get-WingetBotLogin }) -ceq 'explicit-bot') 'BOT_LOGIN must win over the fork owner.'
    $env:BOT_LOGIN = ''
    $env:WINGET_PKGS_FORK_REPO = ''
    Assert-True ($null -eq (& $module { Get-WingetBotLogin })) 'Unconfigured bot login must resolve to null.'
}
finally {
    $env:BOT_LOGIN = $originalBotLogin
    $env:WINGET_PKGS_FORK_REPO = $originalForkRepo
}

# ---------------------------------------------------------------------------
Write-Host 'TEST: release freshness hold uses the newest requested asset upload'
$release = [PSCustomObject]@{
    published_at = $now.AddHours(-10).ToString('o')
    assets       = @(
        [PSCustomObject]@{ browser_download_url = 'https://github.com/loreste/mako/releases/download/v0.5.12/mako-x86_64-pc-windows-msvc.zip'; created_at = $now.AddHours(-10).ToString('o'); updated_at = $now.AddHours(-1).ToString('o') },
        [PSCustomObject]@{ browser_download_url = 'https://github.com/loreste/mako/releases/download/v0.5.12/mako-linux.tar.gz'; created_at = $now.AddHours(-10).ToString('o'); updated_at = $now.AddHours(-10).ToString('o') }
    )
}
$freshHold = Get-GHReleaseFreshnessHold -Repo 'loreste/mako' -Tag 'v0.5.12' -InstallerUrls @('https://github.com/loreste/mako/releases/download/v0.5.12/mako-x86_64-pc-windows-msvc.zip') -MinAgeHours 4 -ReleaseProvider { $release } -Now $now
Assert-True ($null -ne $freshHold -and [Math]::Round($freshHold.AgeHours) -eq 1) "Re-uploaded Windows asset 1 h ago must hold: $($freshHold | ConvertTo-Json -Compress)"

Write-Host 'TEST: unrelated fresh assets do not hold when the requested asset is old'
$swapped = [PSCustomObject]@{
    published_at = $now.AddHours(-10).ToString('o')
    assets       = @(
        [PSCustomObject]@{ browser_download_url = 'https://github.com/loreste/mako/releases/download/v0.5.12/mako-x86_64-pc-windows-msvc.zip'; updated_at = $now.AddHours(-10).ToString('o') },
        [PSCustomObject]@{ browser_download_url = 'https://github.com/loreste/mako/releases/download/v0.5.12/mako-linux.tar.gz'; updated_at = $now.AddMinutes(-5).ToString('o') }
    )
}
$noHold = Get-GHReleaseFreshnessHold -Repo 'loreste/mako' -Tag 'v0.5.12' -InstallerUrls @('https://github.com/loreste/mako/releases/download/v0.5.12/MAKO-x86_64-pc-windows-msvc.zip') -MinAgeHours 4 -ReleaseProvider { $swapped } -Now $now
Assert-True ($null -eq $noHold) "Old requested asset must not hold because of an unrelated fresh asset: $($noHold | ConvertTo-Json -Compress)"

Write-Host 'TEST: without a matching asset every asset counts'
$allAssetsHold = Get-GHReleaseFreshnessHold -Repo 'loreste/mako' -Tag 'v0.5.12' -InstallerUrls @('https://example.invalid/other.zip') -MinAgeHours 4 -ReleaseProvider { $swapped } -Now $now
Assert-True ($null -ne $allAssetsHold) 'Unmatched installer URLs must fall back to all assets.'

Write-Host 'TEST: fresh publish time alone holds'
$justPublished = [PSCustomObject]@{ published_at = $now.AddMinutes(-30).ToString('o'); assets = @() }
$publishHold = Get-GHReleaseFreshnessHold -Repo 'vendor/app' -Tag 'v1' -MinAgeHours 4 -ReleaseProvider { $justPublished } -Now $now
Assert-True ($null -ne $publishHold) 'A release published 30 minutes ago must hold.'

Write-Host 'TEST: MinAgeHours 0 disables the gate without reading the release'
$disabled = Get-GHReleaseFreshnessHold -Repo 'vendor/app' -Tag 'v1' -MinAgeHours 0 -ReleaseProvider { throw 'must not be called' } -Now $now
Assert-True ($null -eq $disabled) 'MinAgeHours 0 must not hold.'

Write-Host 'TEST: 48-hour publisher delay holds a day-old release'
$dayOld = [PSCustomObject]@{ published_at = $now.AddHours(-30).ToString('o'); assets = @([PSCustomObject]@{ browser_download_url = 'https://example.invalid/a.msi'; updated_at = $now.AddHours(-30).ToString('o') }) }
$delayHold = Get-GHReleaseFreshnessHold -Repo 'rizukirr/apic' -Tag 'v0.5.1' -InstallerUrls @('https://example.invalid/a.msi') -MinAgeHours 48 -ReleaseProvider { $dayOld } -Now $now
Assert-True ($null -ne $delayHold -and $delayHold.MinAgeHours -eq 48) 'A 30-hour-old release must wait for the 48-hour publisher delay.'

Write-Host 'TEST: minimum release age precedence'
$originalMinAge = $env:WINGET_MIN_RELEASE_AGE_HOURS
try {
    $env:WINGET_MIN_RELEASE_AGE_HOURS = ''
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured '' }) -eq 4) 'Default must be 4 hours.'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured '48' }) -eq 48) 'Configured value must win.'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured $null }) -eq 4) 'Null configuration must fall back.'
    $env:WINGET_MIN_RELEASE_AGE_HOURS = '6'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured '' }) -eq 6) 'Environment variable must override the default.'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured '48' }) -eq 48) 'Configured value must override the environment.'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured '-2' }) -eq 0) 'Negative values disable the gate.'
    Assert-True ((& $module { Resolve-WingetMinReleaseAgeHours -Configured 'abc' }) -eq 6) 'Non-numeric configuration falls through.'
}
finally {
    $env:WINGET_MIN_RELEASE_AGE_HOURS = $originalMinAge
}

# ---------------------------------------------------------------------------
Write-Host 'TEST: numeric stream guard accepts the pinned stream and rejects others'
& $module { Assert-WingetNumericStreamVersion -PackageId 'OpenJS.Electron.41' -Version '41.2.0' -Tag 'v41.2.0' }
& $module { Assert-WingetNumericStreamVersion -PackageId 'LookupFoundation.RevitLookup.2021' -Version '2021.5.3' -Tag '2027.0.3' }
& $module { Assert-WingetNumericStreamVersion -PackageId 'Vendor.App' -Version '9.9.9' -Tag 'v9.9.9' }
$streamError = $null
try { & $module { Assert-WingetNumericStreamVersion -PackageId 'OpenJS.Electron.41' -Version '43.4.0' -Tag 'v43.4.0' } } catch { $streamError = $_ }
Assert-True ($null -ne $streamError -and "$streamError" -match '43 stream') "Foreign stream version must throw, got: $streamError"

# ---------------------------------------------------------------------------
Write-Host 'TEST: channel cooldown blocks recently validated Nightly/Beta/Canary packages only'
$stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "channel-cooldown-$([guid]::NewGuid()).json"
try {
    @{
        'mikf.gallery-dl.Nightly'   = @{ version = '2026.09.02'; state = 'VALIDATION_PASSED'; lastUpdated = $now.AddDays(-1).ToString('o') }
        'yt-dlp.yt-dlp.nightly'     = @{ version = '2026.08.30'; state = 'VALIDATION_FAILED'; lastUpdated = $now.AddDays(-4).ToString('o') }
        'Vendicated.Vencord.Canary' = @{ version = '1.0.0'; state = 'VALIDATION_FAILED'; lastUpdated = $now.AddHours(-2).ToString('o') }
        'Vendor.App.Beta'           = @{ version = '1.0.0'; state = 'VALIDATION_PASSED'; lastUpdated = $now.AddDays(-2.5).ToString('o') }
        'Vendor.Stable'             = @{ version = '1.0.0'; state = 'VALIDATION_PASSED'; lastUpdated = $now.ToString('o') }
        'Vendor.NoTimestamp.Nightly' = @{ version = '1.0.0'; state = 'VALIDATION_PASSED' }
    } | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding utf8

    $blocks = Get-PackageStateChannelCooldownBlocks -StateFilePath $stateFile -CooldownDays 3 -Now $now
    Assert-True ($blocks.Contains('mikf.gallery-dl.Nightly')) 'Nightly validated yesterday must be blocked.'
    Assert-True ($blocks.Contains('Vendicated.Vencord.Canary')) 'Canary validated 2 h ago must be blocked.'
    Assert-True ($blocks.Contains('Vendor.App.Beta')) 'Beta validated 2.5 days ago must be blocked.'
    Assert-True (-not $blocks.Contains('yt-dlp.yt-dlp.nightly')) 'Nightly validated 4 days ago must not be blocked.'
    Assert-True (-not $blocks.Contains('Vendor.Stable')) 'Stable packages are never throttled.'
    Assert-True (-not $blocks.Contains('Vendor.NoTimestamp.Nightly')) 'Entries without lastUpdated are not blocked.'
    Assert-True ($blocks['mikf.gallery-dl.Nightly']['lastVersion'] -ceq '2026.09.02') 'Block details must carry the last version.'

    $disabledBlocks = Get-PackageStateChannelCooldownBlocks -StateFilePath $stateFile -CooldownDays 0 -Now $now
    Assert-True ($disabledBlocks.Count -eq 0) 'CooldownDays 0 must disable the throttle.'
}
finally {
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
}

Write-Host 'TEST: channel identifier classification'
foreach ($id in @('mikf.gallery-dl.Nightly', 'yt-dlp.yt-dlp.nightly', 'Vendor.App.Beta', 'Vendor.App.PreRelease', 'Vendor.App.Pre-release', 'Vendor.App.Preview', 'Vendicated.Vencord.Canary')) {
    Assert-True (& $module { param($id) Test-WingetChannelPackageId -PackageId $id } $id) "$id must be a channel identifier."
}
foreach ($id in @('Vendor.App', 'OpenJS.Electron.41', 'Vendor.BetaTools', 'Vendor.Nightly.App')) {
    Assert-True (-not (& $module { param($id) Test-WingetChannelPackageId -PackageId $id } $id)) "$id must not be a channel identifier."
}

Write-Host 'Upstream PR policy tests passed.' -ForegroundColor Green
