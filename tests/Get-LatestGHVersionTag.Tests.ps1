# Tests for Get-LatestGHVersionTag (stream-aware GitHub release tag resolution)
# and the shared stream-configuration validation helpers.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru -WarningAction SilentlyContinue

$script:failures = 0

function Assert-Equal {
    param($Expected, $Actual, [string] $Name)

    if ("$Expected" -ne "$Actual") {
        $script:failures++
        Write-Host "FAIL: $Name (expected '$Expected', got '$Actual')"
    } else {
        Write-Host "PASS: $Name"
    }
}

# All scenarios run inside the module scope with a stubbed gh CLI. The stub
# serves whatever $script:ghReleases holds and records every invocation.
$result = & $module {
    $script:ghCalls = [System.Collections.Generic.List[object]]::new()
    $script:ghReleases = @()
    $script:ghApiLatest = $null

    function script:gh {
        $script:ghCalls.Add(@($args | ForEach-Object { "$_" }))
        $global:LASTEXITCODE = 0
        if ("$($args[0])" -eq 'release') {
            return (ConvertTo-Json -InputObject @($script:ghReleases) -Depth 5)
        }
        if ("$($args[0])" -eq 'api') {
            return (ConvertTo-Json -InputObject $script:ghApiLatest -Depth 5)
        }
        return '[]'
    }

    function script:New-TestRelease {
        param([string] $Tag, [string] $PublishedAt, [bool] $IsLatest = $false, [bool] $IsPrerelease = $false)
        @{ name = $Tag; tagName = $Tag; publishedAt = $PublishedAt; isLatest = $IsLatest; isPrerelease = $IsPrerelease }
    }

    function script:Invoke-Guarded {
        param([scriptblock] $Action)
        try {
            return [PSCustomObject]@{ Value = (& $Action); Error = $null }
        }
        catch {
            return [PSCustomObject]@{ Value = $null; Error = $_.Exception.Message }
        }
    }

    $outcome = [ordered]@{}

    # 1) A stream deeper than the old 30-release window still resolves, and the
    #    gh call uses the shared 100-release lookback window.
    $releases = for ($i = 0; $i -lt 45; $i++) {
        New-TestRelease -Tag "v43.$i.0" -PublishedAt ((Get-Date '2026-06-01T00:00:00Z').AddDays($i).ToString('yyyy-MM-ddTHH:mm:ssZ')) -IsLatest ($i -eq 44)
    }
    $releases += @(
        New-TestRelease -Tag 'v39.8.9' -PublishedAt '2026-01-01T00:00:00Z'
        New-TestRelease -Tag 'v39.8.10' -PublishedAt '2026-02-01T00:00:00Z'
        New-TestRelease -Tag 'v39.9.0-beta.1' -PublishedAt '2026-03-01T00:00:00Z' -IsPrerelease $true
    )
    $script:ghReleases = $releases
    $script:ghCalls.Clear()
    $deep = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'electron/electron' -TagPattern '^v39\.' -PackageId 'OpenJS.Electron.39' 6>$null }
    $outcome.DeepStreamTag = $deep.Value
    $outcome.DeepStreamArgs = ($script:ghCalls[0] -join ' ')

    # 2) Fail closed: numeric-stream package ID without tagPattern throws before
    #    any gh call is made.
    $script:ghCalls.Clear()
    $numericGuard = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'electron/electron' -PackageId 'OpenJS.Electron.39' 6>$null }
    $outcome.NumericGuardError = $numericGuard.Error
    $outcome.NumericGuardGhCalls = $script:ghCalls.Count

    # 3) Fail closed: channel-suffix package ID without tagPattern and without
    #    the prerelease opt-in throws.
    $channelGuard = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'vendor/tool' -PackageId 'Vendor.Tool.Beta' 6>$null }
    $outcome.ChannelGuardError = $channelGuard.Error

    # 4) Prerelease-only channel: -AllowPrerelease plus tagPattern resolves the
    #    beta tag; without the switch the same pattern finds nothing and throws.
    $script:ghReleases = @(
        New-TestRelease -Tag 'v1.7.4' -PublishedAt '2026-08-17T00:00:00Z' -IsLatest $true
        New-TestRelease -Tag 'v1.7.2-Beta+0d7412c' -PublishedAt '2026-07-07T00:00:00Z' -IsPrerelease $true
        New-TestRelease -Tag 'v1.7.1-Beta+aaaa111' -PublishedAt '2026-06-01T00:00:00Z' -IsPrerelease $true
    )
    $beta = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'PLFJY/ContextMenuMgr' -TagPattern '-Beta' -PackageId 'Vendor.Tool.Beta' -AllowPrerelease 6>$null }
    $outcome.BetaTag = $beta.Value
    $betaBlocked = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'PLFJY/ContextMenuMgr' -TagPattern '-Beta' -PackageId 'Vendor.Tool.Beta' 6>$null }
    $outcome.BetaBlockedError = $betaBlocked.Error

    # 5) Prerelease channel without tagPattern: newest prerelease-flagged
    #    release wins, never the stable isLatest release.
    $script:ghReleases = @(
        New-TestRelease -Tag '2.7.12' -PublishedAt '2026-08-18T00:00:00Z' -IsLatest $true
        New-TestRelease -Tag '2.9.4' -PublishedAt '2026-07-13T00:00:00Z' -IsPrerelease $true
        New-TestRelease -Tag '2.9.3' -PublishedAt '2026-06-29T00:00:00Z' -IsPrerelease $true
    )
    $channel = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'microsoft/WSL' -PackageId 'Microsoft.WSL.PreRelease' -AllowPrerelease 6>$null }
    $outcome.ChannelTag = $channel.Value

    # 6) Default selection: isLatest wins and prereleases stay excluded without
    #    the opt-in, even when a prerelease is newer.
    $script:ghReleases = @(
        New-TestRelease -Tag 'v2.0.0' -PublishedAt '2026-05-01T00:00:00Z' -IsLatest $true
        New-TestRelease -Tag 'v2.1.0-rc1' -PublishedAt '2026-06-01T00:00:00Z' -IsPrerelease $true
    )
    $stable = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'vendor/app' -PackageId 'Vendor.App' 6>$null }
    $outcome.StableTag = $stable.Value

    # 7) REST fallback: when the release list carries no isLatest entry, the
    #    releases/latest endpoint supplies the tag (stable path only).
    $script:ghReleases = @(
        New-TestRelease -Tag 'v0.9.0' -PublishedAt '2026-01-01T00:00:00Z'
    )
    $script:ghApiLatest = @{ tag_name = 'v1.0.0' }
    $fallback = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'vendor/app' 6>$null }
    $outcome.FallbackTag = $fallback.Value

    # 8) TagPattern without any match throws an actionable error naming the window.
    $script:ghReleases = @(
        New-TestRelease -Tag 'v2.0.0' -PublishedAt '2026-05-01T00:00:00Z' -IsLatest $true
    )
    $noMatch = Invoke-Guarded { Get-LatestGHVersionTag -Repo 'vendor/app' -TagPattern '^v39\.' 6>$null }
    $outcome.NoMatchError = $noMatch.Error

    Remove-Item function:gh
    Remove-Item function:New-TestRelease
    Remove-Item function:Invoke-Guarded

    [PSCustomObject]$outcome
}

Assert-Equal 'v39.8.10' $result.DeepStreamTag 'a stream beyond the old 30-release window resolves via the newest matching stable tag'
Assert-Equal $true ($result.DeepStreamArgs -match '--limit 100') 'gh release list is called with the shared 100-release lookback window'
Assert-Equal $true ($result.NumericGuardError -match 'tagPattern') 'numeric-stream ID without tagPattern throws an actionable error'
Assert-Equal 0 $result.NumericGuardGhCalls 'the numeric-stream guard fails closed before any gh call'
Assert-Equal $true ($result.ChannelGuardError -match 'pre-release') 'channel-suffix ID without tagPattern or pre-release opt-in throws'
Assert-Equal 'v1.7.2-Beta+0d7412c' $result.BetaTag 'prerelease-only channel resolves the newest beta tag with -AllowPrerelease + tagPattern'
Assert-Equal $true ($result.BetaBlockedError -match 'No release tag found') 'the same pattern without -AllowPrerelease finds no release and throws'
Assert-Equal '2.9.4' $result.ChannelTag '-AllowPrerelease without tagPattern picks the newest prerelease, not the stable isLatest'
Assert-Equal 'v2.0.0' $result.StableTag 'default selection keeps isLatest and excludes prereleases'
Assert-Equal 'v1.0.0' $result.FallbackTag 'missing isLatest entry falls back to the releases/latest endpoint'
Assert-Equal $true ($result.NoMatchError -match 'newest 100 releases') 'unmatched tagPattern throws an error naming the scanned window'

# 9) Shared stream-kind classification used by the guard and config validation.
$kinds = & $module {
    [PSCustomObject]@{
        Numeric    = Get-WingetPackageIdStreamKind -PackageId 'OpenJS.Electron.39'
        Beta       = Get-WingetPackageIdStreamKind -PackageId 'PLFJY.ContextMenuMgrPlus.Beta'
        UpperBeta  = Get-WingetPackageIdStreamKind -PackageId 'OpenDumpViewer.OpenDumpViewer.BETA'
        Nightly    = Get-WingetPackageIdStreamKind -PackageId 'yt-dlp.yt-dlp.nightly'
        PreRelease = Get-WingetPackageIdStreamKind -PackageId 'Microsoft.WSL.PreRelease'
        Hyphenated = Get-WingetPackageIdStreamKind -PackageId 'SomeVendor.SomeApp.Pre-release'
        Plain      = Get-WingetPackageIdStreamKind -PackageId 'Vendor.App'
        VersionMid = Get-WingetPackageIdStreamKind -PackageId 'Vendor.App2.Tool'
    }
}
Assert-Equal 'NumericStream' $kinds.Numeric 'trailing .<digits> classifies as NumericStream'
Assert-Equal 'ChannelSuffix' $kinds.Beta '.Beta classifies as ChannelSuffix'
Assert-Equal 'ChannelSuffix' $kinds.UpperBeta '.BETA classifies case-insensitively'
Assert-Equal 'ChannelSuffix' $kinds.Nightly '.nightly classifies case-insensitively'
Assert-Equal 'ChannelSuffix' $kinds.PreRelease '.PreRelease classifies as ChannelSuffix'
Assert-Equal 'ChannelSuffix' $kinds.Hyphenated '.Pre-release (hyphenated) classifies as ChannelSuffix'
Assert-Equal 'None' $kinds.Plain 'plain IDs are not stream-versioned'
Assert-Equal 'None' $kinds.VersionMid 'digits inside a middle segment do not count'

# 10) Config validation flags stream-versioned entries without a stream pin.
$violations = & $module {
    $entries = @(
        @{ id = 'Vendor.App.42'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.App.Beta'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Pinned.42'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe'; tagPattern = '^v42\.' },
        @{ id = 'Vendor.Channel.Beta'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe'; 'pre-release' = 'true' },
        @{ id = 'Vendor.Numeric.42'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe'; 'pre-release' = 'true' },
        @{ id = 'Vendor.Exempt.Beta'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Plain'; repo = 'vendor/app'; url = 'https://example.com/{VERSION}.exe' }
    )
    @(Get-WingetStreamConfigViolation -Packages $entries -ExemptPackageIds @('Vendor.Exempt.Beta'))
}
Assert-Equal 3 $violations.Count 'exactly the unpinned stream entries are flagged'
Assert-Equal $true (@($violations | Where-Object { $_.PackageId -eq 'Vendor.App.42' }).Count -eq 1) 'numeric stream without tagPattern is flagged'
Assert-Equal $true (@($violations | Where-Object { $_.PackageId -eq 'Vendor.App.Beta' }).Count -eq 1) 'channel suffix without tagPattern or pre-release is flagged'
Assert-Equal $true (@($violations | Where-Object { $_.PackageId -eq 'Vendor.Numeric.42' }).Count -eq 1) 'pre-release opt-in does not satisfy a numeric stream'
Assert-Equal $true (@($violations | ForEach-Object { $_.Message }) -join ' ' -match 'tagPattern') 'violation messages tell the operator what to fix'

# 11) pre-release value normalization used across the pipeline.
$optIn = & $module {
    [PSCustomObject]@{
        LowerTrue  = Test-WingetPreReleaseOptIn -Value 'true'
        MixedTrue  = Test-WingetPreReleaseOptIn -Value 'True'
        BoolTrue   = Test-WingetPreReleaseOptIn -Value $true
        One        = Test-WingetPreReleaseOptIn -Value '1'
        FalseText  = Test-WingetPreReleaseOptIn -Value 'false'
        Empty      = Test-WingetPreReleaseOptIn -Value ''
        Null       = Test-WingetPreReleaseOptIn -Value $null
    }
}
Assert-Equal $true $optIn.LowerTrue 'string true opts in'
Assert-Equal $true $optIn.MixedTrue 'casing does not matter'
Assert-Equal $true $optIn.BoolTrue 'boolean true opts in'
Assert-Equal $true $optIn.One 'string 1 opts in'
Assert-Equal $false $optIn.FalseText 'string false stays opted out'
Assert-Equal $false $optIn.Empty 'empty string stays opted out'
Assert-Equal $false $optIn.Null 'null stays opted out'

# 12) Precheck integration: pre-release entries are always included (fail-open)
#     without spending GraphQL calls on stable-only resolution.
$precheck = & $module {
    $script:queries = [System.Collections.Generic.List[string]]::new()
    $selection = Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Channel.Beta'; repo = 'vendor/channel'; url = 'https://example.com/{VERSION}.exe'; 'pre-release' = 'true'; tagPattern = '-beta$' }
    ) -GraphQlInvoker { param([string] $Query) $script:queries.Add($Query); @{ data = @{} } }
    [PSCustomObject]@{
        Reason     = @($selection.Include)[0].Reason
        QueryCount = $script:queries.Count
    }
}
Assert-Equal 'PrereleaseChannel' $precheck.Reason 'pre-release entries bypass stable-only precheck resolution'
Assert-Equal 0 $precheck.QueryCount 'pre-release entries cost no precheck GraphQL queries'

# 13) Asset checker integration: prerelease-channel entries resolve their assets
#     against the matching prerelease instead of reporting NoMatchingRelease.
$assets = & $module {
    $invoker = {
        param([string] $Query)
        @{ data = @{ t0 = @{ releases = @{ nodes = @(
            @{ tagName = 'v4.5.0'; name = 'v4.5.0'; isDraft = $false; isPrerelease = $false; publishedAt = '2026-08-10T14:23:55Z'; releaseAssets = @{ totalCount = 1; nodes = @(@{ downloadUrl = 'https://github.com/vendor/app/releases/download/v4.5.0/App_v4.5.0_installer_x64.exe' }) } },
            @{ tagName = 'v4.5.0-beta'; name = 'v4.5.0-beta'; isDraft = $false; isPrerelease = $true; publishedAt = '2026-08-10T14:06:25Z'; releaseAssets = @{ totalCount = 1; nodes = @(@{ downloadUrl = 'https://github.com/vendor/app/releases/download/v4.5.0-beta/App_v4.5.0-beta_installer_x64.exe' }) } }
        ) } } } }
    }
    $results = Test-MonitoredPackageAssets -Packages @(
        @{ id = 'Vendor.App.BETA'; repo = 'vendor/app'; url = 'https://github.com/vendor/app/releases/download/{TAG}/App_v{ARPVERSION}-beta_installer_x64.exe'; tagPattern = '-beta$'; 'pre-release' = 'true' }
    ) -GraphQlInvoker $invoker
    @($results)[0]
}
Assert-Equal 'OK' $assets.Status 'asset check resolves the prerelease release for opted-in entries'
Assert-Equal 'v4.5.0-beta' $assets.Tag 'asset check picks the prerelease tag, not the stable release'

if ($script:failures -gt 0) {
    Write-Host "$script:failures assertion(s) failed."
    exit 1
}

Write-Host 'All Get-LatestGHVersionTag tests passed.'
