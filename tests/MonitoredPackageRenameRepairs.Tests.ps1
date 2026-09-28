$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru -WarningAction SilentlyContinue
$packages = @(Get-Content (Join-Path $repositoryRoot '.github/workflows-data/update-github-packages-1-z.packages.json') -Raw | ConvertFrom-Json)
$fixtures = @(Get-Content (Join-Path $PSScriptRoot 'fixtures/MonitoredPackageRenameRepairs.json') -Raw | ConvertFrom-Json)
if ($fixtures.Count -ne 45 -or @($fixtures.id | Sort-Object -Unique).Count -ne 45) {
    throw 'Expected fixtures for all 45 active Config Health recoveries.'
}

$retiredRepairFixtures = @(
    [PSCustomObject]@{ Id = 'Grandpied33.STH'; ReasonPattern = 'moved to STH\.STH' },
    [PSCustomObject]@{ Id = 'PatrickHener.Goshs'; ReasonPattern = 'moved to GoshsLabs\.Goshs' }
)
$monitoredText = Get-Content (Join-Path $repositoryRoot 'github-releases-monitored.yml') -Raw
foreach ($retired in $retiredRepairFixtures) {
    if ($fixtures.id -contains $retired.Id) {
        throw "$($retired.Id) must not stay in active rename-repair fixtures after being retired."
    }
    if (@($packages | Where-Object { $_.id -ceq $retired.Id }).Count -ne 0) {
        throw "$($retired.Id) must not be active in the generated monitored package sidecar."
    }
    if ($monitoredText -notmatch "(?m)^#\s+$([regex]::Escape($retired.Id)) is excluded: .*($($retired.ReasonPattern))") {
        throw "$($retired.Id) must stay documented as an excluded rename repair in github-releases-monitored.yml."
    }
}

foreach ($fixture in $fixtures) {
    $matchingPackages = @($packages | Where-Object { $_.id -ceq $fixture.id })
    if ($matchingPackages.Count -ne 1) {
        throw "Expected exactly one monitored entry for $($fixture.id)."
    }
    $package = $matchingPackages[0]
    if ($package.repo -cne $fixture.repo) {
        throw "$($fixture.id) must use the verified repository '$($fixture.repo)'."
    }
    if ($fixture.assets.Count -eq 0) {
        throw "$($fixture.id) has no verified release-asset fixture."
    }

    $release = [PSCustomObject]@{
        tagName = $fixture.tag
        name = $fixture.releaseName
        isDraft = $false
        isPrerelease = $false
        publishedAt = '2026-09-16T00:00:00Z'
        releaseAssets = [PSCustomObject]@{
            totalCount = $fixture.assets.Count
            nodes = @($fixture.assets | ForEach-Object { [PSCustomObject]@{ downloadUrl = $_ } })
        }
    }
    $repository = [PSCustomObject]@{
        latestRelease = $release
        releases = [PSCustomObject]@{ nodes = @($release) }
    }
    $invoker = {
        param([string] $Query)
        [PSCustomObject]@{ data = [PSCustomObject]@{ a0 = $repository; t0 = $repository } }
    }.GetNewClosure()

    $results = @(Test-MonitoredPackageAssets -Packages @($package) -GraphQlInvoker $invoker)
    if ($results.Count -ne 1 -or $results[0].Status -ne 'OK') {
        throw "$($fixture.id) must resolve all renamed assets: $($results | ConvertTo-Json -Compress)"
    }
    if ($results[0].Detail -match 'external URL') {
        throw "$($fixture.id) must not defer renamed assets to an external URL check."
    }

    $version = & $module {
        param($Package, $Repository)
        Resolve-WingetPrecheckReleaseVersion -Package $Package -Repository $Repository
    } $package $repository
    if ($version -cne $fixture.version) {
        throw "$($fixture.id) resolves version '$version', expected '$($fixture.version)'."
    }

    $resolvedUrls = @($package.url -split '\s+' | ForEach-Object {
        ($_ -split '\|')[0].Replace('{TAG}', $fixture.tag).Replace('{VERSION}', $version).Replace('{ARPVERSION}', $version)
    })
    if ($resolvedUrls.Count -ne $fixture.assets.Count) {
        throw "$($fixture.id) must preserve all $($fixture.assets.Count) configured installer slots."
    }
    for ($i = 0; $i -lt $resolvedUrls.Count; $i++) {
        if ($resolvedUrls[$i] -cne $fixture.assets[$i]) {
            throw "$($fixture.id) resolves an unexpected URL in installer slot ${i}: $($resolvedUrls[$i])"
        }
    }
}

Write-Host "Monitored package rename regression tests passed ($($fixtures.Count) packages)." -ForegroundColor Green
