$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Match {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Actual,

        [Parameter(Mandatory = $true)]
        [string] $Pattern,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $match = [regex]::Match($Actual, $Pattern)
    if (-not $match.Success) {
        throw $Message
    }

    return $match
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workflowPaths = @(
    '.github/workflows/update-github-packages-1-q.yml',
    '.github/workflows/update-github-packages-r-z.yml',
    '.github/workflows/update-script-packages.yml',
    '.github/workflows-templates/github-releases.yml'
)

foreach ($workflowRelativePath in $workflowPaths) {
    $workflowPath = Join-Path $repositoryRoot $workflowRelativePath
    $workflowName = Split-Path -Leaf $workflowPath
    $workflow = Get-Content -LiteralPath $workflowPath -Raw

    $submitMatch = Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)^  submit-pr:\r?\n(?<submitJob>.*?)(?=^  notify-failure:)' `
        -Message "$workflowName does not contain a submit-pr job followed by notify-failure."
    $submitJob = $submitMatch.Groups['submitJob'].Value

    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^      group: winget-pkgs-submit-\$\{\{\s*matrix\.PackageName\s*\}\}\s*$' `
        -Message "$workflowName does not serialize same-package submissions." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^      cancel-in-progress: false\s*$' `
        -Message "$workflowName may cancel an in-progress same-package submission." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?s)\$result = Submit-WingetPackage.*?-With "ForkBranch".*?-SubmissionTarget "\$env:WINGET_PKGS_SUBMISSION_TARGET"' `
        -Message "$workflowName must use the no-sync ForkBranch submission mode." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^          WINGET_PKGS_FORK_REPO: \$\{\{\s*vars\.WINGET_PKGS_FORK_REPO\s*\}\}\s*$' `
        -Message "$workflowName does not provide the configured user-owned fork." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^          WINGET_PKGS_SUBMISSION_TARGET: Upstream\s*$' `
        -Message "$workflowName must use the upstream pull request target for every trigger." | Out-Null
    if ([regex]::IsMatch($submitJob, '(?i)WINGET_PKGS_SUBMISSION_TARGET:\s*Fork')) {
        throw "$workflowName may not create fork-only pull requests."
    }
}

Write-Host 'All submission workflow authorization regression tests passed.' -ForegroundColor Green
