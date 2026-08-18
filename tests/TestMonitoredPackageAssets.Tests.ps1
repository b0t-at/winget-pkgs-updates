$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force

function New-FakeGraphQlInvoker {
    param([hashtable] $RepositoriesByAlias)

    # Replays a canned repository object per alias, ignoring the query text.
    return {
        param([string] $Query)

        $aliases = @([regex]::Matches($Query, '(?m)^\s*(?<Alias>[at]\d+):') | ForEach-Object { $_.Groups['Alias'].Value })
        $data = [ordered]@{}
        foreach ($alias in $aliases) {
            $data[$alias] = $RepositoriesByAlias[$alias]
        }
        [PSCustomObject]@{ data = [PSCustomObject]$data }
    }.GetNewClosure()
}

function New-Release {
    param(
        [string] $Tag,
        [string] $Name = '',
        [string[]] $AssetUrls = @(),
        [bool] $Draft = $false,
        [bool] $Prerelease = $false,
        [string] $PublishedAt = '2026-01-01T00:00:00Z',
        [int] $TotalCount = -1
    )

    [PSCustomObject]@{
        tagName       = $Tag
        name          = $Name
        isDraft       = $Draft
        isPrerelease  = $Prerelease
        publishedAt   = $PublishedAt
        releaseAssets = [PSCustomObject]@{
            totalCount = if ($TotalCount -ge 0) { $TotalCount } else { $AssetUrls.Count }
            nodes      = @($AssetUrls | ForEach-Object { [PSCustomObject]@{ downloadUrl = $_ } })
        }
    }
}

Write-Host 'TEST: matching URL template reports OK (architecture hints are stripped)'
$packages = @([PSCustomObject]@{
        id   = 'Test.Ok'
        repo = 'owner/ok'
        url  = 'https://github.com/owner/ok/releases/download/v{VERSION}/app-{VERSION}-x64.msi|x64'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/ok/releases/download/v1.2.3/app-1.2.3-x64.msi')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $packages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK') {
    throw "Expected OK, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: URL templates with repeated whitespace are accepted'
$whitespacePackages = @([PSCustomObject]@{
        id   = 'Test.Whitespace'
        repo = 'owner/whitespace'
        url  = '  https://github.com/owner/whitespace/releases/download/v{VERSION}/app-{VERSION}-x64.msi|x64   '
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/whitespace/releases/download/v1.2.3/app-1.2.3-x64.msi')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $whitespacePackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK') {
    throw "Expected whitespace-delimited URL template to resolve, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: latest release URLs and query strings normalize to release assets'
$latestPackages = @([PSCustomObject]@{
        id   = 'Test.Latest'
        repo = 'owner/latest'
        url  = 'https://github.com/OWNER/LATEST/releases/latest/download/setup-{VERSION}.exe'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/latest/releases/download/v1.2.3/setup-1.2.3.exe')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $latestPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK') {
    throw "Expected latest/download URL to resolve, got: $($results[0] | ConvertTo-Json -Compress)"
}

$queryPackages = @([PSCustomObject]@{
        id   = 'Test.Query'
        repo = 'owner/query'
        url  = 'https://github.com/owner/query/releases/download/{TAG}/setup-{VERSION}.exe?download=1'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/query/releases/download/v1.2.3/setup-1.2.3.exe')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $queryPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK') {
    throw "Expected query-string URL to resolve, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: external download URLs are left to submission preflight'
$externalPackages = @([PSCustomObject]@{
        id   = 'Test.External'
        repo = 'owner/external'
        url  = 'https://downloads.example.invalid/setup-{VERSION}.exe'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/external/releases/download/v1.2.3/setup-1.2.3.exe')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $externalPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'Skipped') {
    throw "Expected external download URL to be skipped, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: renamed asset reports AssetMissing with the expected URL'
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/ok/releases/download/v1.2.3/renamed.msi')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $packages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'AssetMissing' -or $results[0].Detail -notmatch 'app-1\.2\.3-x64\.msi') {
    throw "Expected AssetMissing naming the URL, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: missing repository and missing release are classified'
$twoPackages = @(
    [PSCustomObject]@{ id = 'Test.NoRepo'; repo = 'owner/gone'; url = 'https://github.com/owner/gone/releases/download/v{VERSION}/x.exe' },
    [PSCustomObject]@{ id = 'Test.NoRelease'; repo = 'owner/quiet'; url = 'https://github.com/owner/quiet/releases/download/v{VERSION}/x.exe' }
)
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = $null
    'a1' = [PSCustomObject]@{ latestRelease = $null }
}
$results = @(Test-MonitoredPackageAssets -Packages $twoPackages -GraphQlInvoker $invoker)
$byId = @{}
foreach ($result in $results) { $byId[$result.PackageId] = $result }
if ($byId['Test.NoRepo'].Status -ne 'RepoMissing' -or $byId['Test.NoRelease'].Status -ne 'NoRelease') {
    throw "Expected RepoMissing and NoRelease, got: $($results | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: tagPattern packages check their own release stream'
$streamPackages = @([PSCustomObject]@{
        id         = 'Test.Stream39'
        repo       = 'owner/multi'
        url        = 'https://github.com/owner/multi/releases/download/{TAG}/app-{VERSION}.zip'
        tagPattern = '^v39\.'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    't0' = [PSCustomObject]@{
        releases = [PSCustomObject]@{
            nodes = @(
                (New-Release -Tag 'v43.0.0' -AssetUrls @('https://github.com/owner/multi/releases/download/v43.0.0/app-43.0.0.zip') -PublishedAt '2026-03-01T00:00:00Z'),
                (New-Release -Tag 'v39.8.0' -AssetUrls @('https://github.com/owner/multi/releases/download/v39.8.0/app-39.8.0.zip') -PublishedAt '2026-02-01T00:00:00Z'),
                (New-Release -Tag 'v39.9.0' -Prerelease $true -AssetUrls @() -PublishedAt '2026-02-15T00:00:00Z')
            )
        }
    }
}
$results = @(Test-MonitoredPackageAssets -Packages $streamPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK' -or $results[0].Tag -ne 'v39.8.0') {
    throw "Expected the v39 stream release to be checked, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: tagPattern without a matching stable release reports NoMatchingRelease'
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    't0' = [PSCustomObject]@{
        releases = [PSCustomObject]@{
            nodes = @((New-Release -Tag 'v43.0.0' -AssetUrls @('https://github.com/owner/multi/releases/download/v43.0.0/app-43.0.0.zip')))
        }
    }
}
$results = @(Test-MonitoredPackageAssets -Packages $streamPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'NoMatchingRelease') {
    throw "Expected NoMatchingRelease, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: {ARPVERSION} templates match via regex against asset URLs'
$arpPackages = @([PSCustomObject]@{
        id   = 'Test.Arp'
        repo = 'owner/arp'
        url  = 'https://github.com/owner/arp/releases/download/{TAG}/setup-{ARPVERSION}.msi'
    })
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'build-77' -AssetUrls @('https://github.com/owner/arp/releases/download/build-77/setup-5.4.3.msi')) }
}
$results = @(Test-MonitoredPackageAssets -Packages $arpPackages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'OK') {
    throw "Expected ARPVERSION regex match, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: truncated asset lists downgrade a miss to Inconclusive'
$invoker = New-FakeGraphQlInvoker -RepositoriesByAlias @{
    'a0' = [PSCustomObject]@{ latestRelease = (New-Release -Tag 'v1.2.3' -AssetUrls @('https://github.com/owner/ok/releases/download/v1.2.3/other.msi') -TotalCount 150) }
}
$results = @(Test-MonitoredPackageAssets -Packages $packages -GraphQlInvoker $invoker)
if ($results[0].Status -ne 'Inconclusive') {
    throw "Expected Inconclusive on truncated assets, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'TEST: entries without repo/url are skipped'
$results = @(Test-MonitoredPackageAssets -Packages @([PSCustomObject]@{ id = 'Test.Script' }) -GraphQlInvoker (New-FakeGraphQlInvoker -RepositoriesByAlias @{}))
if ($results[0].Status -ne 'Skipped') {
    throw "Expected Skipped, got: $($results[0] | ConvertTo-Json -Compress)"
}

Write-Host 'All Test-MonitoredPackageAssets tests passed.'
