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

# Generated workflow names depend on chunk boundaries of the monitored list,
# so discover them instead of hardcoding.
$generatedWorkflowPaths = @(
    Get-ChildItem -Path (Join-Path $repositoryRoot '.github/workflows') -Filter 'update-github-packages-*.yml' |
        ForEach-Object { ".github/workflows/$($_.Name)" } |
        Sort-Object
)
if ($generatedWorkflowPaths.Count -lt 2) {
    throw "Expected at least two generated update-github-packages-*.yml workflows, found $($generatedWorkflowPaths.Count)."
}

$configurationPaths = @('github-releases-monitored.yml') + $generatedWorkflowPaths

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
            -Pattern "`"?id`"?:\s*`"?$([regex]::Escape($packageId))`"?" `
            -Message "$configurationRelativePath must not monitor $packageId while its documented validation exclusion applies."
    }
}

$workflowPaths = @('.github/workflows-templates/github-releases.yml') + $generatedWorkflowPaths

foreach ($workflowRelativePath in $workflowPaths) {
    $workflowPath = Join-Path $repositoryRoot $workflowRelativePath
    $workflow = Get-Content -LiteralPath $workflowPath -Raw

    Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)generate-manifest:.*?strategy:\r?\n      fail-fast: false\r?\n      max-parallel: 8' `
        -Message "$workflowRelativePath must limit simultaneous manifest generation jobs to avoid GitHub API rate-limit bursts."
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

    # Batched update precheck wiring: a check-updates job selects only packages
    # with unpublished releases and feeds the generate-manifest matrix.
    Assert-Match `
        -Actual $workflow `
        -Pattern '(?m)^  check-updates:' `
        -Message "$workflowRelativePath must define the check-updates precheck job."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('run: ./scripts/Select-PackagesNeedingUpdate.ps1')) `
        -Message "$workflowRelativePath must run the batched update precheck script."
    Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)generate-manifest:.*?needs: check-updates\r?\n    if: needs\.check-updates\.outputs\.any == ''true''' `
        -Message "$workflowRelativePath must gate manifest generation on the precheck result."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('include: ${{ fromJSON(needs.check-updates.outputs.include) }}')) `
        -Message "$workflowRelativePath must build the generation matrix from the precheck output."
    Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)notify-failure:.*?needs:\r?\n      \[\r?\n        check-updates,' `
        -Message "$workflowRelativePath must include check-updates in failure notifications."
}

# Generated workflows must embed the monitored package list as JSON for the
# precheck job (the template only carries the placeholder).
foreach ($generatedRelativePath in $generatedWorkflowPaths) {
    $generatedContent = Get-Content -LiteralPath (Join-Path $repositoryRoot $generatedRelativePath) -Raw
    if ($generatedContent -notmatch '(?ms)MONITORED_PACKAGES: \|\r?\n            \[\r?\n(.*?)\r?\n            \]') {
        throw "$generatedRelativePath must embed the monitored package list as JSON in MONITORED_PACKAGES."
    }
    $packagesJson = ('[' + ($Matches[1] -replace '(?m)^\s+', '') + ']')
    $packages = @($packagesJson | ConvertFrom-Json)
    if ($packages.Count -lt 1) {
        throw "$generatedRelativePath must embed at least one monitored package."
    }
    foreach ($package in $packages | Select-Object -First 5) {
        foreach ($requiredField in @('id', 'repo', 'url')) {
            if ([string]::IsNullOrWhiteSpace([string]$package.$requiredField)) {
                throw "$generatedRelativePath embeds a package without the required '$requiredField' field."
            }
        }
    }
}

# Generated matrix workflows must run on staggered cron minutes so they do not
# hit the GitHub API at the same instant with a shared token.
$generatedCronMinutes = @{}
foreach ($generatedRelativePath in $generatedWorkflowPaths) {
    $generatedContent = Get-Content -LiteralPath (Join-Path $repositoryRoot $generatedRelativePath) -Raw
    if ($generatedContent -notmatch '(?m)cron:\s*"(\d{1,2}) 0/4 \* \* \*"') {
        throw "$generatedRelativePath must define a cron schedule of the form '<minute> 0/4 * * *'."
    }
    $generatedCronMinutes[$generatedRelativePath] = [int]$Matches[1]
}
$distinctCronMinutes = @($generatedCronMinutes.Values | Sort-Object -Unique)
if ($distinctCronMinutes.Count -ne $generatedCronMinutes.Count) {
    throw "Generated GH package workflows must use distinct cron minutes to stagger API load, got: $($generatedCronMinutes.Values -join ', ')."
}

Write-Host 'GitHub release monitoring configuration regression tests passed.' -ForegroundColor Green
