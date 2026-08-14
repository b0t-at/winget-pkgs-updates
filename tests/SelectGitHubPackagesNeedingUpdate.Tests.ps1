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
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.Tagged') 'tagPattern package is always included'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.ArpSource') 'non-Tag versionSource is always included'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.TagSource') 'versionSource Tag with published RELEASE_ tag is skipped'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.ArpUrl') 'ARPVERSION url is always included'
Assert-Equal 'Include:UnpredictableVersionSource' (Get-ReasonFor $selection 'Vendor.Override') 'overridePack package is always included'
Assert-Equal 'Include:InvalidRepoFormat' (Get-ReasonFor $selection 'Vendor.BadRepo') 'invalid repo format is included'
Assert-Equal 'Skipped:AlreadyPublished' (Get-ReasonFor $selection 'Vendor.AliasMatch') 'numeric alias match counts as published'
Assert-Equal 2 $result.QueryCount 'one release query and one manifest query for small lists'
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

# 5) A failing manifest read (repository null) throws so the caller can fail open.
$threw = & $module {
    $invoker = {
        param([string] $Query)
        if ($Query -notmatch 'winget-pkgs') {
            return @{ data = @{ r0 = @{ latestRelease = @{ tagName = 'v1.0.0' } } } }
        }
        return @{ data = @{ repository = $null } }
    }

    try {
        $null = Select-GitHubPackagesNeedingUpdate -Packages @(@{ id = 'Vendor.A'; repo = 'vendor/a'; url = 'https://example.com/{VERSION}.exe' }) -GraphQlInvoker $invoker
        return $false
    } catch {
        return $_.Exception.Message -match 'winget-pkgs'
    }
}
Assert-Equal $true $threw 'null winget-pkgs repository response throws'

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

if ($script:failures -gt 0) {
    Write-Host "$script:failures assertion(s) failed."
    exit 1
}

Write-Host 'All Select-GitHubPackagesNeedingUpdate tests passed.'
