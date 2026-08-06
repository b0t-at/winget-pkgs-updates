$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-NotMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if ([regex]::IsMatch($Actual, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) {
        throw $Message
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$configurationPaths = @(
    'github-releases-monitored.yml',
    '.github/workflows/update-github-packages-1-q.yml',
    '.github/workflows/update-github-packages-r-z.yml'
)

$excludedPackageIds = @(
    'benaclejames.VRCFaceTracking',
    'SVGExplorerExtension.SVGExplorerExtension',
    'Gruntwork.Terragrunt'
)

foreach ($configurationRelativePath in $configurationPaths) {
    $configurationPath = Join-Path $repositoryRoot $configurationRelativePath
    $configuration = Get-Content -LiteralPath $configurationPath -Raw

    foreach ($packageId in $excludedPackageIds) {
        Assert-NotMatch `
            -Actual $configuration `
            -Pattern "^\s*-\s+id:\s*`"?$([regex]::Escape($packageId))`"?\s*$" `
            -Message "$configurationRelativePath must not monitor $packageId while its documented validation exclusion applies."
    }
}

Write-Host 'GitHub release monitoring configuration regression tests passed.' -ForegroundColor Green
