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

function Get-ActiveConfigurationText {
    <#
        Commented-out entries and prose exclusion notes are how a deliberate
        exclusion is recorded, so they must not count as "monitored". Only the
        active lines decide whether a package is actually being processed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (
        Get-Content -LiteralPath $Path |
            Where-Object { $_ -notmatch '^\s*#' }
    ) -join [Environment]::NewLine
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot

# Generated workflow names depend on chunk boundaries of the monitored list,
# so discover them instead of hardcoding.
$generatedWorkflowPaths = @(
    Get-ChildItem -Path (Join-Path $repositoryRoot '.github/workflows') -Filter 'update-github-packages-*.yml' |
        ForEach-Object { ".github/workflows/$($_.Name)" } |
        Sort-Object
)
if ($generatedWorkflowPaths.Count -lt 1) {
    throw "Expected at least one generated update-github-packages-*.yml workflow, found $($generatedWorkflowPaths.Count)."
}

$configurationPaths = @('github-releases-monitored.yml') + $generatedWorkflowPaths

$excludedPackageIds = @(
    'benaclejames.VRCFaceTracking',
    'SVGExplorerExtension.SVGExplorerExtension',
    'Gruntwork.Terragrunt'
)

foreach ($configurationRelativePath in $configurationPaths) {
    $configurationPath = Join-Path $repositoryRoot $configurationRelativePath
    $configuration = Get-ActiveConfigurationText -Path $configurationPath

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
        -Pattern '(?ms)generate-manifest:.*?strategy:\r?\n      fail-fast: false\r?\n      max-parallel: 10' `
        -Message "$workflowRelativePath must limit simultaneous manifest generation jobs to avoid GitHub API rate-limit bursts."
    Assert-Match `
        -Actual $workflow `
        -Pattern '(?ms)^on:\r?\n  workflow_dispatch:\r?\n    inputs:\r?\n      batch_size:.*?default: 30\r?\n        type: number' `
        -Message "$workflowRelativePath must expose the per-run batch size as a workflow input defaulting to 30."
    Assert-Match `
        -Actual $workflow `
        -Pattern ([regex]::Escape('UPDATE_BATCH_SIZE: ${{ inputs.batch_size || 30 }}')) `
        -Message "$workflowRelativePath must pass the batch size input to the precheck and fall back to 30 for scheduled runs."
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

# Generated workflows must point at a sidecar package list. Inlining it into an
# environment variable breaks the Linux 128 KiB per-variable limit and fails the
# precheck step with "Argument list too long".
foreach ($generatedRelativePath in $generatedWorkflowPaths) {
    $generatedContent = Get-Content -LiteralPath (Join-Path $repositoryRoot $generatedRelativePath) -Raw

    if ($generatedContent -match '(?m)^\s+MONITORED_PACKAGES:\s*\|') {
        throw "$generatedRelativePath must not inline the package list into an environment variable."
    }

    if ($generatedContent -notmatch '(?m)^\s+MONITORED_PACKAGES_FILE:\s*(\S+)\s*$') {
        throw "$generatedRelativePath must reference the monitored package list through MONITORED_PACKAGES_FILE."
    }

    $packagesRelativePath = $Matches[1]
    $packagesPath = Join-Path $repositoryRoot $packagesRelativePath
    if (-not (Test-Path -LiteralPath $packagesPath)) {
        throw "$generatedRelativePath references '$packagesRelativePath', which does not exist."
    }

    $packages = @((Get-Content -LiteralPath $packagesPath -Raw) | ConvertFrom-Json)
    if ($packages.Count -lt 1) {
        throw "$packagesRelativePath must list at least one monitored package."
    }

    foreach ($package in $packages | Select-Object -First 5) {
        foreach ($requiredField in @('id', 'repo', 'url')) {
            if ([string]::IsNullOrWhiteSpace([string]$package.$requiredField)) {
                throw "$packagesRelativePath lists a package without the required '$requiredField' field."
            }
        }
    }

    # A single environment variable must stay under the Linux limit; the file
    # indirection is what keeps the workflow itself small.
    $workflowBytes = [System.Text.Encoding]::UTF8.GetByteCount($generatedContent)
    if ($workflowBytes -gt 131072) {
        throw "$generatedRelativePath is $workflowBytes bytes; the package list must live in its sidecar file."
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

# Stream-versioned monitored entries (Vendor.App.39, Vendor.App.Beta, ...) must
# pin their stream explicitly; resolving them from the repo-global latest
# release publishes wrong-stream versions (OpenJS.Electron.39 -> 43.4.0).
# Validated in both the source-of-truth yml and every generated sidecar so a
# config edit cannot re-introduce the failure mode.
$module = Import-Module (Join-Path $repositoryRoot 'modules/WingetMaintainerModule/WingetMaintainerModule.psd1') -Force -PassThru -WarningAction SilentlyContinue

# PLFJY.ContextMenuMgrPlus.Beta is being disabled in a parallel change;
# reconfiguring it here would conflict. Follow-up: re-enable the entry with
# tagPattern '-Beta' + pre-release: "true" once both changes have landed.
$streamGuardExemptPackageIds = @('PLFJY.ContextMenuMgrPlus.Beta')

function Get-ActiveMonitoredEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*-\s*id:\s*(?<q>[''"])(?<id>.+?)\k<q>\s*$') {
            if ($null -ne $current) { $entries.Add($current) }
            $current = @{ id = $Matches['id'] }
            continue
        }
        if ($null -ne $current -and $line -match '^\s*(?<key>[A-Za-z-]+)\s*:\s*(?<q>[''"])(?<value>.*?)\k<q>\s*$') {
            $current[$Matches['key']] = $Matches['value']
        }
    }
    if ($null -ne $current) { $entries.Add($current) }
    return @($entries)
}

$monitoredEntries = Get-ActiveMonitoredEntries -Path (Join-Path $repositoryRoot 'github-releases-monitored.yml')
if ($monitoredEntries.Count -lt 100) {
    throw "Parsing github-releases-monitored.yml yielded only $($monitoredEntries.Count) active entries; the parser or the file is broken."
}

$entrySets = [ordered]@{ 'github-releases-monitored.yml' = $monitoredEntries }
foreach ($generatedRelativePath in $generatedWorkflowPaths) {
    $generatedContent = Get-Content -LiteralPath (Join-Path $repositoryRoot $generatedRelativePath) -Raw
    if ($generatedContent -match '(?m)^\s+MONITORED_PACKAGES_FILE:\s*(\S+)\s*$') {
        $sidecarRelativePath = $Matches[1]
        $entrySets[$sidecarRelativePath] = @((Get-Content -LiteralPath (Join-Path $repositoryRoot $sidecarRelativePath) -Raw) | ConvertFrom-Json)
    }
}

foreach ($entrySet in $entrySets.GetEnumerator()) {
    $violations = @(& $module {
            param($Packages, $ExemptPackageIds)
            Get-WingetStreamConfigViolation -Packages $Packages -ExemptPackageIds $ExemptPackageIds
        } $entrySet.Value $streamGuardExemptPackageIds)
    if ($violations.Count -gt 0) {
        $details = @($violations | ForEach-Object { "  - $($_.Message)" }) -join [Environment]::NewLine
        throw "$($entrySet.Key) contains stream-versioned entries without a stream pin:$([Environment]::NewLine)$details"
    }
}

# The generated sidecars are what the workflows actually process. They are
# produced by scripts/orchestrate_gh-packages.py; when that step is skipped
# after editing github-releases-monitored.yml, retired packages keep being
# submitted (2026-08: ten retired entries stayed live for two weeks because
# the orchestrate workflow was disabled). Run
#   python scripts/orchestrate_gh-packages.py
# after every edit of the monitored list.
$monitoredIds = @($monitoredEntries | ForEach-Object { [string]$_['id'] })
$sidecarIds = @($entrySets.GetEnumerator() |
        Where-Object { $_.Key -ne 'github-releases-monitored.yml' } |
        ForEach-Object { @($_.Value) } |
        ForEach-Object { [string]$_.id })
$staleSidecarIds = @($sidecarIds | Where-Object { $_ -notin $monitoredIds } | Sort-Object -Unique)
$missingSidecarIds = @($monitoredIds | Where-Object { $_ -notin $sidecarIds } | Sort-Object -Unique)
if ($staleSidecarIds.Count -gt 0 -or $missingSidecarIds.Count -gt 0) {
    $details = @()
    if ($staleSidecarIds.Count -gt 0) {
        $details += "  retired in github-releases-monitored.yml but still in a sidecar: $($staleSidecarIds -join ', ')"
    }
    if ($missingSidecarIds.Count -gt 0) {
        $details += "  monitored in github-releases-monitored.yml but missing from every sidecar: $($missingSidecarIds -join ', ')"
    }
    throw "The generated package sidecars are out of sync with github-releases-monitored.yml; run 'python scripts/orchestrate_gh-packages.py' and commit the result.$([Environment]::NewLine)$($details -join [Environment]::NewLine)"
}

# Per-package fields the workflow forwards must survive the yml -> sidecar
# rendering with their configured values.
$monitoredByIdText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'github-releases-monitored.yml') -Raw
$sidecarById = @{}
foreach ($sidecarEntry in ($entrySets.GetEnumerator() | Where-Object { $_.Key -ne 'github-releases-monitored.yml' } | ForEach-Object { @($_.Value) })) {
    $sidecarById[[string]$sidecarEntry.id] = $sidecarEntry
}
foreach ($minAgeMatch in [regex]::Matches($monitoredByIdText, '(?m)^\s*-\s*id:\s*"(?<id>[^"]+)"(?:\r?\n(?!\s*-\s*id:)[^\r\n]*)*?\r?\n\s*minReleaseAgeHours:\s*(?<hours>\d+(?:\.\d+)?)\s*$')) {
    $id = $minAgeMatch.Groups['id'].Value
    $hours = $minAgeMatch.Groups['hours'].Value
    if (-not $sidecarById.ContainsKey($id)) { continue }
    $sidecarProperty = $sidecarById[$id].PSObject.Properties['minReleaseAgeHours']
    $sidecarValue = if ($null -ne $sidecarProperty) { [string]$sidecarProperty.Value } else { '' }
    if ($sidecarValue -ne $hours) {
        throw "Sidecar entry for $id carries minReleaseAgeHours '$sidecarValue' but github-releases-monitored.yml configures '$hours'; regenerate the sidecars."
    }
}

Write-Host 'GitHub release monitoring configuration regression tests passed.' -ForegroundColor Green
