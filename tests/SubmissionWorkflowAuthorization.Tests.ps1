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
$workflowNames = @(
    'update-github-packages-1-q.yml',
    'update-github-packages-r-z.yml'
)

foreach ($workflowName in $workflowNames) {
    $workflowPath = Join-Path $repositoryRoot ".github/workflows/$workflowName"
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
        -Pattern '(?s)\$result = Submit-WingetPackage.*?-With "WinGetCreate"' `
        -Message "$workflowName must submit validated manifests with WinGetCreate instead of synchronizing the fork through WinMatsch." | Out-Null
}

Write-Host 'All submission workflow authorization regression tests passed.' -ForegroundColor Green
