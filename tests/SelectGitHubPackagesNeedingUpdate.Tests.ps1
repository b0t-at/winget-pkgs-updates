# Tests for Select-GitHubPackagesNeedingUpdate (batched GraphQL update precheck).
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

function Get-ReasonFor {
    param($Result, [string] $PackageId)

    foreach ($entry in @($Result.Include)) {
        if ($entry.Package.id -eq $PackageId) { return "Include:$($entry.Reason)" }
    }
    foreach ($entry in @($Result.Skipped)) {
        if ($entry.Package.id -eq $PackageId) { return "Skipped:$($entry.Reason)" }
    }
    return 'Missing'
}

# 1) Decision matrix over a mixed package list with a fake GraphQL backend.
$result = & $module {
    $script:queries = [System.Collections.Generic.List[string]]::new()

    $packages = @(
        @{ id = 'Vendor.Published'; repo = 'vendor/published'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Outdated'; repo = 'vendor/outdated'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Missing'; repo = 'vendor/missing'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.NoRelease'; repo = 'vendor/norelease'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Tagged'; repo = 'vendor/tagged'; url = 'https://example.com/{VERSION}.exe'; tagPattern = '^v1\..*' },
        @{ id = 'Vendor.ArpSource'; repo = 'vendor/arpsource'; url = 'https://example.com/{VERSION}.exe'; versionSource = 'ARP' },
        @{ id = 'Vendor.TagSource'; repo = 'vendor/tagsource'; url = 'https://example.com/{VERSION}.exe'; versionSource = 'Tag' },
        @{ id = 'Vendor.ArpUrl'; repo = 'vendor/arpurl'; url = 'https://example.com/{ARPVERSION}.exe' },
        @{ id = 'Vendor.Override'; repo = 'vendor/override'; url = 'https://example.com/{VERSION}.exe'; overridePack = 'zip>msi' },
        @{ id = 'Vendor.BadRepo'; repo = 'https://github.com/vendor/badrepo'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.AliasMatch'; repo = 'vendor/aliasmatch'; url = 'https://example.com/{VERSION}.exe' }
    )

    $invoker = {
        param([string] $Query)
        $script:queries.Add($Query)

        if ($Query -match 'u\d+: repository') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(u\d+): repository\(owner: "[^"]+", name: "([^"]+)"\)')) {
                $data[$alias.Groups[1].Value] = switch ($alias.Groups[2].Value) {
                    'tagged' {
                        @{ releases = @{ nodes = @(
                            @{ tagName = 'v2.0.0'; name = 'v2'; isDraft = $false; isPrerelease = $false; publishedAt = '2026-05-01T00:00:00Z' },
                            @{ tagName = 'v1.9.0'; name = 'v1.9 pre'; isDraft = $false; isPrerelease = $true; publishedAt = '2026-04-20T00:00:00Z' },
                            @{ tagName = 'v1.4.0'; name = 'v1.4'; isDraft = $false; isPrerelease = $false; publishedAt = '2026-03-01T00:00:00Z' },
                            @{ tagName = 'v1.5.0'; name = 'v1.5'; isDraft = $false; isPrerelease = $false; publishedAt = '2026-04-01T00:00:00Z' }
                        ) } }
                    }
                    'arpurl' {
                        @{ latestRelease = @{ tagName = 'v3.2.1'; releaseAssets = @{ nodes = @(@{ downloadUrl = 'https://example.com/3.2.1.exe' }) } } }
                    }
                    default { $null }
                }
            }
            return @{ data = $data }
        }

        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(owner: "[^"]+", name: "([^"]+)"\)')) {
                $tag = switch ($alias.Groups[2].Value) {
                    'published'  { 'v1.2.3' }
                    'outdated'   { 'v2.0.0' }
                    'missing'    { 'v1.0.0' }
                    'norelease'  { $null }
                    'tagsource'  { 'RELEASE_5.0' }
                    'aliasmatch' { 'v1.2' }
                    default      { 'v9.9.9' }
                }
                $data[$alias.Groups[1].Value] = if ($null -eq $tag) { @{ latestRelease = $null } } else { @{ latestRelease = @{ tagName = $tag } } }
            }
            return @{ data = $data }
        }

        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(expression: "master:manifests/[a-z0-9]/Vendor/([^"]+)"\)')) {
            $entries = switch ($alias.Groups[2].Value) {
                'Published'  { @(@{ name = '1.2.3'; type = 'tree' }, @{ name = '.validation'; type = 'blob' }) }
                'Outdated'   { @(@{ name = '1.2.3'; type = 'tree' }) }
                'Missing'    { $null }
                'NoRelease'  { @(@{ name = '1.0.0'; type = 'tree' }) }
                'TagSource'  { @(@{ name = '5.0'; type = 'tree' }) }
                'AliasMatch' { @(@{ name = '1.2.0'; type = 'tree' }) }
                'Tagged'     { @(@{ name = '1.5.0'; type = 'tree' }) }
                'ArpUrl'     { @(@{ name = '1.0.0'; type = 'tree' }) }
                default      { @() }
            }
            $repoData[$alias.Groups[1].Value] = if ($null -eq $entries) { $null } else { @{ entries = $entries } }
        }
        return @{ data = @{ repository = $repoData } }
    }

    $selection = Select-GitHubPackagesNeedingUpdate -Packages $packages -GraphQlInvoker $invoker -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Selection  = $selection
        QueryCount = $script:queries.Count
        Queries    = @($script:queries)
    }
}

$selection = $result.Selection
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.Published') 'published latest release is skipped'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $selection 'Vendor.Outdated') 'new release is included'
Assert-Equal 'Skipped:PackageMissing' (Get-ReasonFor $selection 'Vendor.Missing') 'package missing from winget-pkgs is skipped'
Assert-Equal 'Include:NoReleaseFound' (Get-ReasonFor $selection 'Vendor.NoRelease') 'repo without latest release is included'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.Tagged') 'tagPattern package resolved from the release list is skipped when published'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.ArpSource') 'non-Tag versionSource is always included'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.TagSource') 'versionSource Tag with published RELEASE_ tag is skipped'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $selection 'Vendor.ArpUrl') 'ARPVERSION url resolved from assets is included as a new version'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.Override') 'overridePack package is always included'
Assert-Equal 'Include:InvalidRepoFormat' (Get-ReasonFor $selection 'Vendor.BadRepo') 'invalid repo format is included'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.AliasMatch') 'numeric alias match counts as published'
Assert-Equal 3 $result.QueryCount 'one release query, one resolvable query and one manifest query for small lists'
Assert-Equal 5 ($selection.Include.Count + $selection.Skipped.Count - 6) 'all eleven packages are accounted for'

# 2) Included entries carry the original package objects unmodified.
$originalUrl = @($selection.Include | Where-Object { $_.Package.id -eq 'Vendor.Outdated' })[0].Package.url
Assert-Equal 'https://example.com/{VERSION}.exe' $originalUrl 'include entries keep the original package object'

# 3) Batching splits queries and deduplicates repositories.
$batched = & $module {
    $script:queries = [System.Collections.Generic.List[string]]::new()

    $packages = @(
        @{ id = 'Vendor.A'; repo = 'vendor/shared'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.B'; repo = 'vendor/shared'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.C'; repo = 'vendor/other'; url = 'https://example.com/{VERSION}.exe' }
    )

    $invoker = {
        param([string] $Query)
        $script:queries.Add($Query)

        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(')) {
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = 'v1.0.0' } }
            }
            return @{ data = $data }
        }

        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(')) {
            $repoData[$alias.Groups[1].Value] = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) }
        }
        return @{ data = @{ repository = $repoData } }
    }

    $selection = Select-GitHubPackagesNeedingUpdate -Packages $packages -GraphQlInvoker $invoker -BatchSize 2
    [PSCustomObject]@{
        Selection    = $selection
        QueryCount   = $script:queries.Count
        ReleaseQuery = @($script:queries | Where-Object { $_ -notmatch 'winget-pkgs' })[0]
    }
}
Assert-Equal 3 $batched.Selection.Skipped.Count 'shared repo result applies to every package'
Assert-Equal 3 $batched.QueryCount 'two unique repos fit one release query, three packages need two manifest queries'
Assert-Equal 2 ([regex]::Matches($batched.ReleaseQuery, 'repository\(').Count) 'duplicate repositories are queried once'

# 4) Empty package list returns empty results without any GraphQL call.
$empty = & $module {
    $script:queries = [System.Collections.Generic.List[string]]::new()
    $selection = Select-GitHubPackagesNeedingUpdate -Packages @() -GraphQlInvoker { param($Query) $script:queries.Add($Query) }
    [PSCustomObject]@{ IncludeCount = $selection.Include.Count; SkippedCount = $selection.Skipped.Count; QueryCount = $script:queries.Count }
}
Assert-Equal 0 $empty.IncludeCount 'empty input produces empty include list'
Assert-Equal 0 $empty.SkippedCount 'empty input produces empty skipped list'
Assert-Equal 0 $empty.QueryCount 'empty input makes no GraphQL calls'

# 5) A failed winget-pkgs read falls back to the winget source index: indexed
#    versions still produce skip/include decisions, unindexed packages fail open.
$indexFallback = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(owner: "[^"]+", name: "([^"]+)"\)')) {
                $tag = switch ($alias.Groups[2].Value) {
                    'outdated' { 'v2.0.0' }
                    default    { 'v1.0.0' }
                }
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = $tag } }
            }
            return @{ data = $data }
        }
        return @{ data = @{ repository = $null } }
    }
    $sourceIndex = {
        @(
            [PSCustomObject]@{ PackageIdentifier = 'Vendor.Published'; WingetVersion = '1.0.0' },
            [PSCustomObject]@{ PackageIdentifier = 'Vendor.Outdated'; WingetVersion = '1.0.0' }
        )
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Published'; repo = 'vendor/published'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Outdated'; repo = 'vendor/outdated'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Unindexed'; repo = 'vendor/unindexed'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -SourceIndexProvider $sourceIndex -WarningAction SilentlyContinue
}
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $indexFallback 'Vendor.Published') 'index fallback skips versions the index already lists'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $indexFallback 'Vendor.Outdated') 'index fallback includes versions newer than the index'
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $indexFallback 'Vendor.Unindexed') 'packages missing from the index fail open'

# 5b) When the source index is also unavailable, failed batches fail open.
$indexUnavailable = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v1.0.0' } } } }
        }
        throw 'winget-pkgs read boom'
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(@{ id = 'Vendor.A'; repo = 'vendor/a'; url = 'https://example.com/{VERSION}.exe' }) -GraphQlInvoker $invoker -SourceIndexProvider { throw 'index download failed' } -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $indexUnavailable 'Vendor.A') 'failed batch without a usable index fails open'

# 5c) A failed release batch only fails open its own packages; other batches
#     still produce normal skip decisions.
$partialPass1 = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            if ($Query -match '"bad"') { throw 'release query boom' }
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(')) {
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = 'v1.0.0' } }
            }
            return @{ data = $data }
        }
        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(')) {
            $repoData[$alias.Groups[1].Value] = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) }
        }
        return @{ data = @{ repository = $repoData } }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Bad'; repo = 'vendor/bad'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Good'; repo = 'vendor/good'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -BatchSize 1 -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $partialPass1 'Vendor.Bad') 'failed release batch includes its packages'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $partialPass1 'Vendor.Good') 'other release batches still skip published packages'

# 5d) A failed release-metadata batch includes its resolvable packages.
$resolvableFailure = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -match 'u\d+: repository') { throw 'metadata query boom' }
        if ($Query -notmatch 'winget-pkgs') { return @{ data = @{} } }
        return @{ data = @{ repository = @{} } }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(@{ id = 'Vendor.Tagged'; repo = 'vendor/tagged'; url = 'https://example.com/{VERSION}.exe'; tagPattern = '^v1\..*' }) -GraphQlInvoker $invoker -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $resolvableFailure 'Vendor.Tagged') 'failed release-metadata batch includes its packages'

# 6) GraphQL rate limits (HTTP 200 + RATE_LIMITED error) are retried by the default invoker.
$rateLimit = & $module {
    $script:restCalls = 0
    $script:sleeps = [System.Collections.Generic.List[int]]::new()
    $env:WINGET_UPSTREAM_READ_TOKEN = 'test-token'

    function script:Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType)
        $script:restCalls++
        if ($script:restCalls -eq 1) {
            return @{ data = $null; errors = @(@{ type = 'RATE_LIMITED'; message = 'API rate limit exceeded' }) }
        }
        return @{ data = @{ ok = $true } }
    }
    function script:Start-Sleep {
        param($Seconds)
        $script:sleeps.Add([int]$Seconds)
    }

    $response = Invoke-WingetPrecheckGraphQlRequest -Query 'query { viewer { login } }'

    Remove-Item function:Invoke-RestMethod
    Remove-Item function:Start-Sleep
    Remove-Item env:WINGET_UPSTREAM_READ_TOKEN

    [PSCustomObject]@{
        Calls  = $script:restCalls
        Ok     = $response.data.ok
        Sleeps = ($script:sleeps -join ',')
    }
}
Assert-Equal 2 $rateLimit.Calls 'RATE_LIMITED response is retried'
Assert-Equal $true $rateLimit.Ok 'successful retry returns the GraphQL payload'
Assert-Equal '5' $rateLimit.Sleeps 'retry uses backoff delay'

# 6b) Transient server errors (HTTP 5xx) are retried by the default invoker.
$transient = & $module {
    $script:restCalls = 0
    $env:WINGET_UPSTREAM_READ_TOKEN = 'test-token'

    function script:Invoke-RestMethod {
        param($Method, $Uri, $Headers, $Body, $ContentType)
        $script:restCalls++
        if ($script:restCalls -eq 1) {
            $exception = [System.Exception]::new('Response status code does not indicate success: 502 (Bad Gateway).')
            $exception.Data['StatusCode'] = 502
            throw $exception
        }
        return @{ data = @{ ok = $true } }
    }
    function script:Start-Sleep { param($Seconds) }

    $response = Invoke-WingetPrecheckGraphQlRequest -Query 'query { viewer { login } }' -WarningAction SilentlyContinue

    Remove-Item function:Invoke-RestMethod
    Remove-Item function:Start-Sleep
    Remove-Item env:WINGET_UPSTREAM_READ_TOKEN

    [PSCustomObject]@{ Calls = $script:restCalls; Ok = $response.data.ok }
}
Assert-Equal 2 $transient.Calls 'HTTP 502 response is retried by the default invoker'
Assert-Equal $true $transient.Ok 'successful 502 retry returns the GraphQL payload'

# 7) Open-PR cache: fresh marker skips, stale/mismatched markers trigger a live
#    check, tester results are recorded, and tester failures fail open.
$openPr = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(')) {
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = 'v2.0.0' } }
            }
            return @{ data = $data }
        }
        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(')) {
            $repoData[$alias.Groups[1].Value] = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) }
        }
        return @{ data = @{ repository = $repoData } }
    }

    $newPackage = { param([string] $Id) @{ id = $Id; repo = "vendor/$($Id.ToLowerInvariant())"; url = 'https://example.com/{VERSION}.exe' } }
    $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpr-state-$([guid]::NewGuid()).json"

    # Seed: fresh marker for Vendor.Fresh, expired marker for Vendor.Expired,
    # version-mismatched marker for Vendor.Mismatch.
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Fresh' -Version '2.0.0'
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Expired' -Version '2.0.0' -CheckedAt ((Get-Date).ToUniversalTime().AddHours(-48))
    Set-PackageStateOpenPr -StateFilePath $stateFile -PackageIdentifier 'Vendor.Mismatch' -Version '1.5.0'

    $script:testerCalls = [System.Collections.Generic.List[string]]::new()
    $tester = {
        param([string] $PackageIdentifier, [string] $Version)
        $script:testerCalls.Add("$PackageIdentifier@$Version")
        switch ($PackageIdentifier) {
            'Vendor.Expired'  { return $true }   # PR still open -> refresh marker
            'Vendor.Mismatch' { return $false }  # stale marker -> clear
            'Vendor.PrFound'  { return $true }   # new marker recorded
            'Vendor.Error'    { throw 'search unavailable' }
            default           { return $false }
        }
    }

    $packages = @(
        (& $newPackage 'Vendor.Fresh'),
        (& $newPackage 'Vendor.Expired'),
        (& $newPackage 'Vendor.Mismatch'),
        (& $newPackage 'Vendor.PrFound'),
        (& $newPackage 'Vendor.Error'),
        (& $newPackage 'Vendor.NoPr')
    )

    $selection = Select-GitHubPackagesNeedingUpdate -Packages $packages -GraphQlInvoker $invoker -StateFilePath $stateFile -OpenPrTester $tester -WarningAction SilentlyContinue

    $state = Get-PackageState -StateFilePath $stateFile
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Selection        = $selection
        TesterCalls      = @($script:testerCalls)
        FreshMarker      = $state.ContainsKey('Vendor.Fresh')
        ExpiredVersion   = $state['Vendor.Expired']['openPr']['version']
        MismatchCleared  = -not $state.ContainsKey('Vendor.Mismatch')
        PrFoundVersion   = $state['Vendor.PrFound']['openPr']['version']
        ErrorHasMarker   = $state.ContainsKey('Vendor.Error')
        NoPrHasMarker    = $state.ContainsKey('Vendor.NoPr')
    }
}
Assert-Equal 'Skipped:OpenPrExists' (Get-ReasonFor $openPr.Selection 'Vendor.Fresh') 'fresh cached open-PR marker skips the package'
Assert-Equal 'Skipped:OpenPrExists' (Get-ReasonFor $openPr.Selection 'Vendor.Expired') 'expired marker with still-open PR is re-checked and skipped'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $openPr.Selection 'Vendor.Mismatch') 'mismatched marker with no open PR is included'
Assert-Equal 'Skipped:OpenPrExists' (Get-ReasonFor $openPr.Selection 'Vendor.PrFound') 'live check finding an open PR skips the package'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $openPr.Selection 'Vendor.Error') 'tester failure fails open and includes the package'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $openPr.Selection 'Vendor.NoPr') 'no cached marker and no open PR includes the package'
Assert-Equal $false ($openPr.TesterCalls -contains 'Vendor.Fresh@2.0.0') 'fresh marker avoids a live PR search'
Assert-Equal 5 $openPr.TesterCalls.Count 'every non-fresh candidate performs one live PR search'
Assert-Equal $true $openPr.FreshMarker 'fresh marker is left in place'
Assert-Equal '2.0.0' $openPr.ExpiredVersion 'refreshed marker keeps the pending version'
Assert-Equal $true $openPr.MismatchCleared 'stale marker is cleared when no open PR exists'
Assert-Equal '2.0.0' $openPr.PrFoundVersion 'newly found open PR is recorded in the state file'
Assert-Equal $false $openPr.ErrorHasMarker 'tester failure records no marker'
Assert-Equal $false $openPr.NoPrHasMarker 'absent PR records no marker'

# 8) Without a state file path the tester is never consulted.
$openPrDisabled = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v2.0.0' } } } }
        }
        return @{ data = @{ repository = @{ p0 = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) } } } }
    }
    $script:testerCalls = 0
    $selection = Select-GitHubPackagesNeedingUpdate -Packages @(@{ id = 'Vendor.A'; repo = 'vendor/a'; url = 'https://example.com/{VERSION}.exe' }) -GraphQlInvoker $invoker -OpenPrTester { $script:testerCalls++; $true }
    [PSCustomObject]@{ Reason = $selection.Include[0].Reason; TesterCalls = $script:testerCalls }
}
Assert-Equal 'NewVersion' $openPrDisabled.Reason 'open-PR check is disabled without a state file path'
Assert-Equal 0 $openPrDisabled.TesterCalls 'tester is not consulted without a state file path'

# 9) MaxOpenPrChecks caps live searches; capped candidates are included.
$openPrCapped = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(')) {
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = 'v2.0.0' } }
            }
            return @{ data = $data }
        }
        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(')) {
            $repoData[$alias.Groups[1].Value] = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) }
        }
        return @{ data = @{ repository = $repoData } }
    }

    $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpr-cap-$([guid]::NewGuid()).json"
    $script:testerCalls = 0
    $packages = @(1..3 | ForEach-Object { @{ id = "Vendor.P$_"; repo = "vendor/p$_"; url = 'https://example.com/{VERSION}.exe' } })

    $selection = Select-GitHubPackagesNeedingUpdate -Packages $packages -GraphQlInvoker $invoker -StateFilePath $stateFile -OpenPrTester { $script:testerCalls++; $true } -MaxOpenPrChecks 1
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        TesterCalls  = $script:testerCalls
        SkippedCount = $selection.Skipped.Count
        IncludeCount = $selection.Include.Count
    }
}
Assert-Equal 1 $openPrCapped.TesterCalls 'live PR searches stop at MaxOpenPrChecks'
Assert-Equal 1 $openPrCapped.SkippedCount 'checked candidate with open PR is skipped'
Assert-Equal 2 $openPrCapped.IncludeCount 'capped candidates are included unchecked'

# 10) Definitive Config Health blocks bypass GraphQL and prevent a package from
#     entering the generation matrix.
$healthBlocked = & $module {
    $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "config-health-state-$([guid]::NewGuid()).json"
    @{
        'Vendor.AssetMissing' = @{
            configHealth = @{
                status    = 'AssetMissing'
                detail    = 'Expected setup.exe is absent.'
                checkedAt = '2026-08-18T00:00:00Z'
            }
        }
        'Vendor.RepoMissing' = @{
            configHealth = @{
                status    = 'RepoMissing'
                detail    = 'Repository no longer exists.'
                checkedAt = '2026-08-18T00:00:00Z'
            }
        }
    } | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8

    $script:queries = [System.Collections.Generic.List[string]]::new()
    $invoker = {
        param([string] $Query)
        $script:queries.Add($Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v2.0.0' } } } }
        }
        return @{ data = @{ repository = @{ p0 = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) } } } }
    }

    try {
        $selection = Select-GitHubPackagesNeedingUpdate -Packages @(
            @{ id = 'Vendor.AssetMissing'; repo = 'vendor/assetmissing'; url = 'https://example.com/{VERSION}.exe' },
            @{ id = 'Vendor.RepoMissing'; repo = 'vendor/repomissing'; url = 'https://example.com/{VERSION}.exe' },
            @{ id = 'Vendor.Healthy'; repo = 'vendor/healthy'; url = 'https://example.com/{VERSION}.exe' }
        ) -GraphQlInvoker $invoker -StateFilePath $stateFile -OpenPrTester { $false }
    }
    finally {
        Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue
    }

    [PSCustomObject]@{
        Selection = $selection
        Queries  = @($script:queries)
    }
}
Assert-Equal 'Skipped:ConfigHealthBlocked' (Get-ReasonFor $healthBlocked.Selection 'Vendor.AssetMissing') 'missing asset block skips package'
Assert-Equal 'Skipped:ConfigHealthBlocked' (Get-ReasonFor $healthBlocked.Selection 'Vendor.RepoMissing') 'missing repository block skips package'
Assert-Equal 'Include:NewVersion' (Get-ReasonFor $healthBlocked.Selection 'Vendor.Healthy') 'healthy package remains eligible'
Assert-Equal $false (($healthBlocked.Queries -join ' ') -match 'assetmissing|repomissing') 'blocked packages are omitted from GraphQL queries'

# 11) Resolvable version sources (tagPattern / ReleaseName / {ARPVERSION}) are
#     resolved in the precheck; every resolution failure falls back to include.
$resolved = & $module {
    $script:queries = [System.Collections.Generic.List[string]]::new()

    $packages = @(
        @{ id = 'Vendor.NameSource'; repo = 'vendor/namesource'; url = 'https://example.com/{VERSION}.exe'; versionSource = 'ReleaseName' },
        @{ id = 'Vendor.NameNew'; repo = 'vendor/namenew'; url = 'https://example.com/{VERSION}.exe'; versionSource = 'ReleaseName' },
        @{ id = 'Vendor.NameEmpty'; repo = 'vendor/nameempty'; url = 'https://example.com/{VERSION}.exe'; versionSource = 'ReleaseName' },
        @{ id = 'Vendor.NoTagMatch'; repo = 'vendor/notagmatch'; url = 'https://example.com/{VERSION}.exe'; tagPattern = '^release-' },
        @{ id = 'Vendor.NoAssetMatch'; repo = 'vendor/noassetmatch'; url = 'https://example.com/{ARPVERSION}.msi' },
        @{ id = 'Vendor.AssetCap'; repo = 'vendor/assetcap'; url = 'https://example.com/{ARPVERSION}.msi' },
        @{ id = 'Vendor.TagArpCombo'; repo = 'vendor/tagarp'; url = 'https://example.com/{ARPVERSION}.msi'; tagPattern = '^v' },
        @{ id = 'Vendor.TagWithArp'; repo = 'vendor/tagwitharp'; url = 'https://github.com/x/y/releases/download/{TAG}/setup-{ARPVERSION}-x64.msi' }
    )

    $invoker = {
        param([string] $Query)
        $script:queries.Add($Query)

        if ($Query -match 'u\d+: repository') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(u\d+): repository\(owner: "[^"]+", name: "([^"]+)"\)')) {
                $data[$alias.Groups[1].Value] = switch ($alias.Groups[2].Value) {
                    'namesource'   { @{ latestRelease = @{ tagName = 'namesource-2026'; name = ' 7.7.7 ' } } }
                    'namenew'      { @{ latestRelease = @{ tagName = 'weekly-build'; name = '8.8.8' } } }
                    'nameempty'    { @{ latestRelease = @{ tagName = 'v1'; name = '   ' } } }
                    'notagmatch'   { @{ releases = @{ nodes = @(@{ tagName = 'v1.0'; name = 'v1'; isDraft = $false; isPrerelease = $false; publishedAt = '2026-01-01T00:00:00Z' }) } } }
                    'noassetmatch' { @{ latestRelease = @{ tagName = 'v2.0'; releaseAssets = @{ nodes = @(@{ downloadUrl = 'https://example.com/other.zip' }) } } } }
                    'assetcap'     { @{ latestRelease = @{ tagName = 'v4.0'; releaseAssets = @{ nodes = @(1..100 | ForEach-Object { @{ downloadUrl = "https://example.com/$_.msi" } }) } } } }
                    'tagwitharp'   { @{ latestRelease = @{ tagName = 'v9.0'; releaseAssets = @{ nodes = @(@{ downloadUrl = 'https://github.com/x/y/releases/download/v9.0/setup-9.0.1234-x64.msi' }) } } } }
                    default        { $null }
                }
            }
            return @{ data = $data }
        }

        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(expression: "master:manifests/[a-z0-9]/Vendor/([^"]+)"\)')) {
            $entries = switch ($alias.Groups[2].Value) {
                'NameSource' { @(@{ name = '7.7.7'; type = 'tree' }) }
                'TagWithArp' { @(@{ name = '9.0.1234'; type = 'tree' }) }
                default      { @() }
            }
            $repoData[$alias.Groups[1].Value] = @{ entries = $entries }
        }
        return @{ data = @{ repository = $repoData } }
    }

    $stateFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpr-resolved-$([guid]::NewGuid()).json"
    $tester = { param([string] $PackageIdentifier, [string] $Version) $PackageIdentifier -eq 'Vendor.NameNew' -and $Version -eq '8.8.8' }

    $selection = Select-GitHubPackagesNeedingUpdate -Packages $packages -GraphQlInvoker $invoker -StateFilePath $stateFile -OpenPrTester $tester -WarningAction SilentlyContinue
    Remove-Item -Path $stateFile -Force -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Selection         = $selection
        ResolvableQueries = @($script:queries | Where-Object { $_ -match 'u\d+: repository' })
        NameSourceVersion = @($selection.Skipped | Where-Object { $_.Package.id -eq 'Vendor.NameSource' })[0].Version
    }
}
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $resolved.Selection 'Vendor.NameSource') 'published release name version is skipped'
Assert-Equal '7.7.7' $resolved.NameSourceVersion 'release name version is trimmed'
Assert-Equal 'Skipped:OpenPrExists' (Get-ReasonFor $resolved.Selection 'Vendor.NameNew') 'resolved new version participates in the open-PR check'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $resolved.Selection 'Vendor.NameEmpty') 'blank release name fails open'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $resolved.Selection 'Vendor.NoTagMatch') 'tagPattern without a matching stable release fails open'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $resolved.Selection 'Vendor.NoAssetMatch') 'ARPVERSION url without a matching asset fails open'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $resolved.Selection 'Vendor.AssetCap') 'a full asset page fails open against truncation'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $resolved.Selection 'Vendor.TagArpCombo') 'tagPattern plus ARPVERSION combination is not resolved'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $resolved.Selection 'Vendor.TagWithArp') 'published ARPVERSION asset version is skipped'
Assert-Equal $false ($resolved.ResolvableQueries -join ' ' -match 'tagarp') 'unsupported combination is never queried'

# 12) GraphQL partial errors (HTTP 200 + errors array) never masquerade as
#     positive evidence: an errored pass-2 alias is a failed lookup (not
#     PackageMissing), sibling aliases keep their real results, and an
#     error-free null object remains a legitimate missing-package skip.
$partialErrors = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            $data = @{}
            foreach ($alias in [regex]::Matches($Query, '(r\d+): repository\(')) {
                $data[$alias.Groups[1].Value] = @{ latestRelease = @{ tagName = 'v2.0.0' } }
            }
            return @{ data = $data }
        }
        # Pass 2: p0 errors out with a null object, p1 resolves normally,
        # p2 is null WITHOUT an error entry (manifest folder genuinely absent).
        return @{
            errors = @(@{ path = @('p0'); message = 'timeout reading tree' })
            data   = @{ repository = @{
                p0 = $null
                p1 = @{ entries = @(@{ name = '2.0.0'; type = 'tree' }) }
                p2 = $null
            } }
        }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Errored'; repo = 'vendor/errored'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Sibling'; repo = 'vendor/sibling'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Absent'; repo = 'vendor/absent'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -SourceIndexProvider { throw 'index unavailable' } -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $partialErrors 'Vendor.Errored') 'pass-2 per-alias error fails open instead of PackageMissing'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $partialErrors 'Vendor.Sibling') 'error-free sibling alias in the same batch keeps its real result'
Assert-Equal 'Skipped:PackageMissing' (Get-ReasonFor $partialErrors 'Vendor.Absent') 'null object without an error entry remains a missing-package skip'

# 12b) A per-alias pass-2 error resolves through the winget source-index
#      fallback when the index knows the package.
$partialErrorIndexed = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v1.0.0' } } } }
        }
        return @{
            errors = @(@{ path = @('p0'); message = 'timeout reading tree' })
            data   = @{ repository = @{ p0 = $null } }
        }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Errored'; repo = 'vendor/errored'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -SourceIndexProvider {
        @([PSCustomObject]@{ PackageIdentifier = 'Vendor.Errored'; WingetVersion = '1.0.0' })
    } -WarningAction SilentlyContinue
}
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $partialErrorIndexed 'Vendor.Errored') 'per-alias pass-2 error resolves via the source-index fallback'

# 12c) Errors with null data fail the whole batch open.
$nullData = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v1.0.0' } } } }
        }
        return @{ errors = @(@{ message = 'total failure' }); data = $null }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.A'; repo = 'vendor/a'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -SourceIndexProvider { throw 'index unavailable' } -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $nullData 'Vendor.A') 'errors with null data fail the whole batch open'

# 12d) A pass-1 per-alias error becomes a failed repository lookup instead of
#      "repo without releases"; the error-free sibling keeps its skip decision.
$pass1Partial = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            # r0 errors out, r1 resolves; aliases follow the sorted unique
            # repository list (vendor/errored before vendor/good).
            return @{
                errors = @(@{ path = @('r0'); message = 'server error' })
                data   = @{ r0 = $null; r1 = @{ latestRelease = @{ tagName = 'v1.0.0' } } }
            }
        }
        $repoData = @{}
        foreach ($alias in [regex]::Matches($Query, '(p\d+): object\(')) {
            $repoData[$alias.Groups[1].Value] = @{ entries = @(@{ name = '1.0.0'; type = 'tree' }) }
        }
        return @{ data = @{ repository = $repoData } }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Errored'; repo = 'vendor/errored'; url = 'https://example.com/{VERSION}.exe' },
        @{ id = 'Vendor.Good'; repo = 'vendor/good'; url = 'https://example.com/{VERSION}.exe' }
    ) -GraphQlInvoker $invoker -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $pass1Partial 'Vendor.Errored') 'pass-1 per-alias error becomes a failed repo lookup'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $pass1Partial 'Vendor.Good') 'pass-1 sibling alias without an error keeps its result'

# 12e) A pass-1b per-alias error includes the package as batch-failed instead
#      of mislabeling it an unresolvable version source.
$pass1bPartial = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -match 'u\d+: repository') {
            return @{
                errors = @(@{ path = @('u0'); message = 'server error' })
                data   = @{ u0 = $null }
            }
        }
        if ($Query -notmatch 'winget-pkgs') { return @{ data = @{} } }
        return @{ data = @{ repository = @{} } }
    }
    Select-GitHubPackagesNeedingUpdate -Packages @(
        @{ id = 'Vendor.Tagged'; repo = 'vendor/tagged'; url = 'https://example.com/{VERSION}.exe'; tagPattern = '^v1\..*' }
    ) -GraphQlInvoker $invoker -WarningAction SilentlyContinue
}
Assert-Equal 'Include:PrecheckBatchFailed' (Get-ReasonFor $pass1bPartial 'Vendor.Tagged') 'pass-1b per-alias error includes the package as batch-failed'


if ($script:failures -gt 0) {
    Write-Host "$script:failures assertion(s) failed."
    exit 1
}

Write-Host 'All Select-GitHubPackagesNeedingUpdate tests passed.'
