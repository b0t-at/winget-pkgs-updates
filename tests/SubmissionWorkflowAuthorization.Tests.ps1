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
$generatedWorkflowPaths = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github/workflows') -Filter 'update-github-packages-*.yml' |
        Sort-Object -Property Name |
        ForEach-Object { ".github/workflows/$($_.Name)" }
)
if ($generatedWorkflowPaths.Count -lt 1) {
    throw 'No generated update-github-packages workflows were found.'
}
$workflowPaths = $generatedWorkflowPaths + @(
    '.github/workflows/update-script-packages.yml',
    '.github/workflows-templates/github-releases.yml'
)
$dispatchTargetWorkflows = @()

$probeActionPath = Join-Path $repositoryRoot '.github/actions/probe-winget-upstream-read/action.yml'
$probeAction = Get-Content -LiteralPath $probeActionPath -Raw
Assert-Match `
    -Actual $probeAction `
    -Pattern '(?m)^        WINGET_UPSTREAM_READ_PROBE_TOKEN: \$\{\{\s*inputs\.github-token\s*\}\}\s*$' `
    -Message 'The upstream read probe must receive its token under a distinct environment name.' | Out-Null
Assert-Match `
    -Actual $probeAction `
    -Pattern "(?s)-Method Get .*?-Uri 'https://api\.github\.com/repos/microsoft/winget-pkgs'" `
    -Message 'The upstream read probe must perform the isolated public repository GET.' | Out-Null
if ($probeAction -match '(?im)-Method\s+(Post|Put|Patch|Delete)\b') {
    throw 'The upstream read probe must not perform writes.'
}

$validateAndSubmitActionPath = Join-Path $repositoryRoot '.github/actions/validate-and-submit/action.yml'
$validateAndSubmitAction = Get-Content -LiteralPath $validateAndSubmitActionPath -Raw
$compositeContentValidationMatch = Assert-Match `
    -Actual $validateAndSubmitAction `
    -Pattern '(?ms)^    - name: Validate manifest content\r?\n(?<step>.*?)(?=^    - |\z)' `
    -Message 'The validate-and-submit action does not contain its content-validation step.'
$compositeContentValidationStep = $compositeContentValidationMatch.Groups['step'].Value
Assert-Match `
    -Actual $compositeContentValidationStep `
    -Pattern '(?m)^        WINGET_PKGS_GITHUB_TOKEN: \$\{\{\s*inputs\.github-token\s*\}\}\s*$' `
    -Message 'The validate-and-submit action must use its supplied PAT for content validation.' | Out-Null
Assert-Match `
    -Actual $compositeContentValidationStep `
    -Pattern '(?m)^        GITHUB_TOKEN: \$\{\{\s*github\.token\s*\}\}\s*$' `
    -Message 'The validate-and-submit action must retain the workflow token as the content-validation fallback.' | Out-Null

foreach ($workflowRelativePath in $workflowPaths) {
    $workflowPath = Join-Path $repositoryRoot $workflowRelativePath
    $workflowName = Split-Path -Leaf $workflowPath
    $workflow = Get-Content -LiteralPath $workflowPath -Raw

    Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)^      - name: Normalize manifest line endings\r?\n.*?Normalize-WingetManifestLineEndings -ManifestPath "\$env:STEPS_GENERATE_OUTPUTS_MANIFEST_PATH".*?^      - name: Upload manifest artifact\r?\n' `
        -Message "$workflowName must normalize generated manifests before uploading the manifest artifact." | Out-Null

    $saveStateStepMatch = Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)^      - name: Save package state\r?\n(?<step>.*?)(?=^      - |^  [a-zA-Z]|\z)' `
        -Message "$workflowName does not contain a Save package state step."
    $saveStateStep = $saveStateStepMatch.Groups['step'].Value
    Assert-Match `
        -Actual $saveStateStep `
        -Pattern '(?m)^          GH_TOKEN: \$\{\{\s*github\.token\s*\}\}\s*$' `
        -Message "$workflowName does not provide the workflow token to the package-state writer." | Out-Null
    Assert-Match `
        -Actual $saveStateStep `
        -Pattern '(?m)^          gh auth setup-git\s*$' `
        -Message "$workflowName does not configure an explicit Git credential helper before saving package state." | Out-Null

    $contentValidationStepMatch = Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)^      - name: Run content validation\r?\n(?<step>.*?)(?=^      - |\z)' `
        -Message "$workflowName does not contain a content-validation step."
    $contentValidationStep = $contentValidationStepMatch.Groups['step'].Value
    Assert-Match `
        -Actual $contentValidationStep `
        -Pattern '(?m)^          WINGET_PKGS_GITHUB_TOKEN: \$\{\{\s*secrets\.WINGET_PAT\s*\}\}\s*$' `
        -Message "$workflowName must prefer WINGET_PAT for published-manifest validation." | Out-Null
    Assert-Match `
        -Actual $contentValidationStep `
        -Pattern '(?m)^          GITHUB_TOKEN: \$\{\{\s*github\.token\s*\}\}\s*$' `
        -Message "$workflowName must retain the workflow token as the content-validation fallback." | Out-Null

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
        -Pattern '(?s)\$result = Submit-WingetPackage.*?-With "ForkBranch".*?-SubmissionTarget "\$env:WINGET_PKGS_SUBMISSION_TARGET".*?-Repository "\$env:WINGET_PKGS_SUBMISSION_REPOSITORY"' `
        -Message "$workflowName must use the no-sync ForkBranch submission mode." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^          WINGET_PKGS_FORK_REPO: \$\{\{\s*vars\.WINGET_PKGS_FORK_REPO\s*\}\}\s*$' `
        -Message "$workflowName does not provide the configured user-owned fork." | Out-Null
    Assert-Match `
        -Actual $submitJob `
        -Pattern '(?m)^          WINGET_PKGS_SUBMISSION_TARGET: Upstream\s*$' `
        -Message "$workflowName must use the upstream pull request target for every trigger." | Out-Null
    $isDispatchTargetWorkflow = $workflow -match 'allow_test_fork_submission'
    if ($isDispatchTargetWorkflow) {
        $dispatchTargetWorkflows += $workflowRelativePath
        Assert-Match `
            -Actual $workflow `
            -Pattern '(?ms)^  workflow_dispatch:\r?\n    inputs:\r?\n.*?^      submission_repository:.*?^          - microsoft/winget-pkgs\r?\n          - damn-good-b0t/winget-pkgs\s*$(?!\r?\n          - )' `
            -Message "$workflowName must expose only the production and designated test-fork targets." | Out-Null
        Assert-Match `
            -Actual $workflow `
            -Pattern '(?ms)^      allow_test_fork_submission:.*?^        type: boolean\s*$' `
            -Message "$workflowName must require an explicit test-fork acknowledgement." | Out-Null
        Assert-Match `
            -Actual $submitJob `
            -Pattern '(?m)^          WINGET_PKGS_SUBMISSION_REPOSITORY: \$\{\{\s*github\.event_name == ''workflow_dispatch'' && inputs\.submission_repository \|\| ''microsoft/winget-pkgs''\s*\}\}\s*$' `
            -Message "$workflowName must keep scheduled and push submissions pinned to production." | Out-Null
        $generateStepMatch = Assert-Match `
            -Actual $workflow `
            -Pattern '(?ms)^      - name: Generate manifest\r?\n(?<step>.*?)(?=^      - |\z)' `
            -Message "$workflowName does not contain the Generate manifest step."
        $generateStep = $generateStepMatch.Groups['step'].Value
        Assert-Match `
            -Actual $generateStep `
            -Pattern '(?m)^          WINGET_PKGS_SUBMISSION_REPOSITORY: \$\{\{\s*github\.event_name == ''workflow_dispatch'' && inputs\.submission_repository \|\| ''microsoft/winget-pkgs''\s*\}\}\s*$' `
            -Message "$workflowName must use the selected target for its generation duplicate checks." | Out-Null
        Assert-Match `
            -Actual $submitJob `
            -Pattern '(?ms)allow_test_fork_submission workflow_dispatch acknowledgement.*?WINGET_PKGS_ALLOW_TEST_FORK_SUBMISSION: \$\{\{\s*github\.event_name == ''workflow_dispatch'' && inputs\.allow_test_fork_submission \|\| ''false''\s*\}\}' `
            -Message "$workflowName must block test-fork submission without acknowledgement." | Out-Null
    }
    else {
        Assert-Match `
            -Actual $submitJob `
            -Pattern '(?m)^          WINGET_PKGS_SUBMISSION_REPOSITORY: microsoft/winget-pkgs\s*$' `
            -Message "$workflowName must explicitly preserve the production upstream repository." | Out-Null
    }
    if ([regex]::IsMatch($submitJob, '(?i)WINGET_PKGS_SUBMISSION_TARGET:\s*Fork')) {
        throw "$workflowName may not create fork-only pull requests."
    }

    $probeSteps = [regex]::Matches(
        $workflow,
        '(?ms)^      - name: Probe upstream read access\r?\n.*?^        uses: \./\.github/actions/probe-winget-upstream-read\r?\n.*?^        with:\r?\n.*?^          github-token: \$\{\{\s*github\.token\s*\}\}\s*$'
    )
    if ($probeSteps.Count -ne 2) {
        throw "$workflowName must probe the Actions token separately before generation and submission."
    }

    # The check-updates precheck job in github-releases workflows adds a third
    # WINGET_PAT read-token assignment on top of generation and submission.
    $expectedPrimaryReadTokenCount = if ($workflow -match '(?m)^  check-updates:') { 3 } else { 2 }
    $primaryReadTokenAssignments = [regex]::Matches(
        $workflow,
        '(?m)^          WINGET_UPSTREAM_READ_TOKEN: \$\{\{\s*secrets\.WINGET_PAT\s*\}\}\s*$'
    )
    if ($primaryReadTokenAssignments.Count -ne $expectedPrimaryReadTokenCount) {
        throw "$workflowName must pass the classic WINGET_PAT as the primary upstream read token in each generation, submission, and (where present) precheck step; expected $expectedPrimaryReadTokenCount assignments but found $($primaryReadTokenAssignments.Count)."
    }

    $generateReadTokenAssignments = [regex]::Matches(
        $workflow,
        '(?m)^          WINGET_UPSTREAM_READ_FALLBACK_TOKEN: \$\{\{\s*steps\.upstream-read-probe\.outputs\.available == ''true'' && github\.token \|\| secrets\.WINGET_PUBLIC_READ_TOKEN\s*\}\}\s*$'
    )
    if ($generateReadTokenAssignments.Count -ne 1) {
        throw "$workflowName must use the generation probe result only as the upstream read fallback token, with the documented optional fallback."
    }

    $submitReadTokenAssignments = [regex]::Matches(
        $workflow,
        '(?m)^          WINGET_UPSTREAM_READ_FALLBACK_TOKEN: \$\{\{\s*steps\.upstream-read-probe-submit\.outputs\.available == ''true'' && github\.token \|\| secrets\.WINGET_PUBLIC_READ_TOKEN\s*\}\}\s*$'
    )
    if ($submitReadTokenAssignments.Count -ne 1) {
        throw "$workflowName must use the submission probe result only as the upstream read fallback token, with the documented optional fallback."
    }

    foreach ($stepName in @('Generate manifest', 'Submit PR')) {
        $stepMatch = Assert-Match `
            -Actual $workflow `
            -Pattern "(?ms)^      - name: $stepName\r?\n(?<step>.*?)(?=^      - |\z)" `
            -Message "$workflowName does not contain the $stepName step."
        $step = $stepMatch.Groups['step'].Value
        if ($step -notmatch '(?m)^          GITHUB_TOKEN: \$\{\{\s*secrets\.WINGET_PAT\s*\}\}\s*$') {
            throw "$workflowName must retain WINGET_PAT for $stepName."
        }
        if ($step -match '(?m)^          GITHUB_TOKEN: \$\{\{\s*github\.token\s*\}\}\s*$') {
            throw "$workflowName must not replace the fork submission token with the Actions token in $stepName."
        }
    }
}

if ($dispatchTargetWorkflows.Count -ne 1) {
    throw "Exactly one workflow may expose the acknowledged test-fork dispatch target, found $($dispatchTargetWorkflows.Count): $($dispatchTargetWorkflows -join ', ')"
}
if ($dispatchTargetWorkflows[0] -cne $generatedWorkflowPaths[-1]) {
    throw "The test-fork dispatch target must be the last generated workflow ($($generatedWorkflowPaths[-1])), but it is $($dispatchTargetWorkflows[0])."
}

Write-Host 'All submission workflow authorization regression tests passed.' -ForegroundColor Green
