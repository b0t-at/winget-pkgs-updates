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

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    if (-not [regex]::IsMatch($Actual, $Pattern, [Text.RegularExpressions.RegexOptions]::Multiline)) {
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
    'SVGExplorerExtension.SVGExplorerExtension'
)

foreach ($configurationRelativePath in $configurationPaths) {
    $configurationPath = Join-Path $repositoryRoot $configurationRelativePath
    $configuration = Get-Content -LiteralPath $configurationPath -Raw

    foreach ($packageId in $excludedPackageIds) {
        Assert-NotMatch `
            -Actual $configuration `
            -Pattern "^\s*-\s+id:\s*`"?$([regex]::Escape($packageId))`"?\s*$" `
            -Message "$configurationRelativePath must not monitor $packageId until its upstream release artifacts change."
    }
}

$workflowPaths = @(
    '.github/workflows-templates/github-releases.yml',
    '.github/workflows/update-github-packages-1-q.yml',
    '.github/workflows/update-github-packages-r-z.yml'
)

foreach ($workflowRelativePath in $workflowPaths) {
    $workflowPath = Join-Path $repositoryRoot $workflowRelativePath
    $workflow = Get-Content -LiteralPath $workflowPath -Raw

    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape("name: structural-rewrite__`${{ matrix.id }}__`${{ steps.generate.outputs.version }}")) `
        -Message "$workflowRelativePath must publish an approval marker for each approved structural rewrite."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape("if: steps.generate.outputs.generated == 'true' && fromJSON(toJSON(matrix)).allowStructuralRewrite == true")) `
        -Message "$workflowRelativePath must publish approval markers only for explicitly approved packages."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape("if (`$artifact.name -match '^structural-rewrite__(.+)__(.+)`$')")) `
        -Message "$workflowRelativePath must read structural rewrite approval markers before building its validation matrix."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('allowStructuralRewrite = $structuralRewriteApprovals.ContainsKey($approvalKey)')) `
        -Message "$workflowRelativePath must preserve structural rewrite approval in its dynamic validation matrix."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('MATRIX_ALLOW_STRUCTURAL_REWRITE: ${{ fromJSON(toJSON(matrix)).allowStructuralRewrite }}')) `
        -Message "$workflowRelativePath must pass dynamic approval metadata to content validation."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('-AllowStructuralRewrite:$allowStructuralRewrite')) `
        -Message "$workflowRelativePath must explicitly bind the structural rewrite approval switch."
}

Write-Host 'GitHub release monitoring configuration regression tests passed.' -ForegroundColor Green
