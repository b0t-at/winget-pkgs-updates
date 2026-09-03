function Get-WingetBlockingValidationLabels {
    <#
    .SYNOPSIS
        Upstream validation labels that make a resubmission of the same
        package version pointless until something changes.

    .DESCRIPTION
        When microsoft/winget-pkgs closes one of the bot's pull requests with
        one of these labels, resubmitting the identical version only produces
        the identical verdict (Defender/AV hit, dead URL, driver install,
        installer crash, ...). The list mirrors the escalation classes the
        upstream moderators treat as "needs upstream or manifest change".
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @(
        'Validation-Defender-Error',
        'Binary-Validation-Error',
        'Validation-Certificate-Root',
        'URL-Validation-Error',
        'Validation-Unattended-Failed',
        'Validation-Installation-Error',
        'Validation-Shell-Execute',
        'Blocking-Issue',
        'DriverInstall'
    )
}

function Get-WingetManualValidationQueueLabels {
    <#
    .SYNOPSIS
        Label combination that marks a PR as waiting in the moderators'
        manual-validation queue.

    .DESCRIPTION
        A PR that passed the Azure pipeline but whose smoke test could not
        locate the primary executable (portable CLI tools) is resolved by hand.
        That queue is weeks deep; superseding such a PR with every patch
        release resets the package's position and keeps it out of the
        repository indefinitely.
    #>
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        Required = 'Azure-Pipeline-Passed'
        AnyOf    = @('Validation-Executable-Error', 'Validation-No-Executables')
    }
}

function Get-WingetPrLabelNames {
    <#
    .SYNOPSIS
        Normalizes a PR's labels (strings or {name} objects) to a string array.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()] [AllowNull()] $Pr
    )

    if ($null -eq $Pr) { return @() }

    $labelsProperty = $Pr.PSObject.Properties['labels']
    if ($null -eq $labelsProperty -or $null -eq $labelsProperty.Value) { return @() }

    return @($labelsProperty.Value | ForEach-Object {
            if ($null -eq $_) { $null }
            elseif ($_ -is [string]) { $_ }
            else {
                $nameProperty = $_.PSObject.Properties['name']
                if ($null -ne $nameProperty) { [string]$nameProperty.Value } else { $null }
            }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-WingetBotLogin {
    <#
    .SYNOPSIS
        Resolves the GitHub login whose upstream pull requests this pipeline owns.

    .DESCRIPTION
        BOT_LOGIN wins when set; otherwise the owner of WINGET_PKGS_FORK_REPO is
        the account whose PAT opens the upstream PRs. Returns $null when neither
        is configured so callers can skip bot-scoped policy checks (fail-open).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $botLogin = "$env:BOT_LOGIN".Trim()
    if (-not [string]::IsNullOrWhiteSpace($botLogin)) {
        return $botLogin
    }

    if ("$env:WINGET_PKGS_FORK_REPO".Trim() -match '^(?<Owner>[A-Za-z0-9_.-]+)/[A-Za-z0-9_.-]+$') {
        return $Matches['Owner']
    }

    return $null
}

function Test-WingetVersionIsPatchBump {
    <#
    .SYNOPSIS
        Tests whether NewVersion is a patch-level increment over BaseVersion.

    .DESCRIPTION
        Patch means: both versions have at least three numeric segments, the
        first two segments are numerically equal and NewVersion sorts strictly
        higher. Everything else (minor/major bump, fewer segments, unparsable
        input, equal or lower version) is not a patch bump.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $BaseVersion,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $NewVersion
    )

    if ([string]::IsNullOrWhiteSpace($BaseVersion) -or [string]::IsNullOrWhiteSpace($NewVersion)) {
        return $false
    }

    $baseSegments = @([regex]::Matches($BaseVersion, '\d+') | ForEach-Object { $_.Value })
    $newSegments = @([regex]::Matches($NewVersion, '\d+') | ForEach-Object { $_.Value })
    if ($baseSegments.Count -lt 3 -or $newSegments.Count -lt 3) {
        return $false
    }

    for ($i = 0; $i -lt 2; $i++) {
        if ([bigint]::Parse($baseSegments[$i]) -ne [bigint]::Parse($newSegments[$i])) {
            return $false
        }
    }

    # Compare the remaining numeric segments only, so tag prefixes ('v') and
    # separators never influence the ordering.
    $length = [Math]::Max($baseSegments.Count, $newSegments.Count)
    for ($i = 2; $i -lt $length; $i++) {
        $baseValue = if ($i -lt $baseSegments.Count) { [bigint]::Parse($baseSegments[$i]) } else { [bigint]0 }
        $newValue = if ($i -lt $newSegments.Count) { [bigint]::Parse($newSegments[$i]) } else { [bigint]0 }
        if ($newValue -gt $baseValue) { return $true }
        if ($newValue -lt $baseValue) { return $false }
    }

    return $false
}

function Select-WingetPatchSupersessionHold {
    <#
    .SYNOPSIS
        Decides whether a pending patch release must wait for an open PR that
        sits in the manual-validation queue.

    .DESCRIPTION
        Pure decision logic. Given the bot's open upstream PRs (number, title,
        labels, created_at), the package and the version about to be
        submitted, returns the PR that holds the submission when ALL of:
          - the PR title parses to the same package with a strictly older
            version,
          - the new version is only a patch bump over the PR's version,
          - the PR carries Azure-Pipeline-Passed plus
            Validation-Executable-Error or Validation-No-Executables,
          - the PR is younger than MaxAgeDays.
        Returns $null when nothing holds. Older PRs (beyond MaxAgeDays) or
        non-patch releases supersede as before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $OpenPrs,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $NewVersion,
        [Parameter()] [ValidateRange(1, 365)] [int] $MaxAgeDays = 14,
        [Parameter()] [datetime] $Now = [datetime]::UtcNow
    )

    $queueLabels = Get-WingetManualValidationQueueLabels
    $newVersionKey = Get-WingetSortableVersionKey -Version $NewVersion

    foreach ($pr in $OpenPrs) {
        if ($null -eq $pr) { continue }

        $number = 0
        if (-not [int]::TryParse("$($pr.number)", [ref] $number) -or $number -le 0) { continue }

        $parsed = Get-WingetPrTitlePackageVersion -Title "$($pr.title)"
        if ($null -eq $parsed -or $parsed.PackageIdentifier -ine $PackageIdentifier) { continue }

        $prVersionKey = Get-WingetSortableVersionKey -Version $parsed.Version
        if ([string]::IsNullOrWhiteSpace($prVersionKey) -or $prVersionKey -ge $newVersionKey) { continue }
        if (-not (Test-WingetVersionIsPatchBump -BaseVersion $parsed.Version -NewVersion $NewVersion)) { continue }

        $labels = @(Get-WingetPrLabelNames -Pr $pr)
        if ($labels -notcontains $queueLabels.Required) { continue }
        $matchedQueueLabel = @($labels | Where-Object { $_ -in $queueLabels.AnyOf } | Select-Object -First 1)
        if ($matchedQueueLabel.Count -eq 0) { continue }

        $createdAtProperty = $pr.PSObject.Properties['created_at']
        if ($null -eq $createdAtProperty) { $createdAtProperty = $pr.PSObject.Properties['createdAt'] }
        $createdAt = [datetime]::MinValue
        if ($null -eq $createdAtProperty -or
            -not [datetime]::TryParse("$($createdAtProperty.Value)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $createdAt)) {
            # Without a trustworthy age the 14-day escape hatch cannot be
            # evaluated; never hold on uncertain data.
            continue
        }
        $ageDays = ($Now.ToUniversalTime() - $createdAt.ToUniversalTime()).TotalDays
        if ($ageDays -ge $MaxAgeDays) { continue }

        $urlProperty = $pr.PSObject.Properties['html_url']
        if ($null -eq $urlProperty) { $urlProperty = $pr.PSObject.Properties['url'] }

        return [PSCustomObject]@{
            Number     = $number
            Title      = "$($pr.title)"
            Version    = $parsed.Version
            Url        = if ($null -ne $urlProperty) { "$($urlProperty.Value)" } else { '' }
            Labels     = $labels
            AgeDays    = [Math]::Round($ageDays, 1)
            MaxAgeDays = $MaxAgeDays
            Reason     = "open PR #$number ($PackageIdentifier $($parsed.Version)) carries $($queueLabels.Required) + $($matchedQueueLabel[0]) and is only $([Math]::Round($ageDays, 1)) day(s) old; patch release $NewVersion waits for the manual-validation queue (supersedes after $MaxAgeDays days or on a non-patch release)"
        }
    }

    return $null
}

function Find-WingetPkgsBotPrSearchItems {
    <#
    .SYNOPSIS
        Collects the bot's pull requests for a package via GitHub Search.

    .DESCRIPTION
        Uses the same tiered, fail-closed Search paging as the duplicate
        detection (Find-WingetPkgsExistingPrSearchMatch). Returns raw Search
        items (number, title, state, labels, created_at, html_url,
        pull_request.merged_at) whose title names the package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $BotLogin,
        [Parameter(Mandatory = $true)] [ValidateSet('open', 'closed')] [string] $State,
        [Parameter()] [string] $Version
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Repository must be an owner/repository name, not '$Repository'."
    }

    $escapedPackageIdentifier = $PackageIdentifier.Replace('"', '\"')
    $query = "repo:$Repository is:pr is:$State author:$BotLogin in:title `"$escapedPackageIdentifier`""
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $query += " `"$($Version.Replace('"', '\"'))`""
    }

    $items = [System.Collections.Generic.List[object]]::new()
    $collector = {
        param($candidate)

        $titleProperty = $candidate.PSObject.Properties['title']
        if ($null -eq $titleProperty -or [string]::IsNullOrWhiteSpace("$($titleProperty.Value)")) {
            throw 'GitHub bot-PR search returned a candidate without a title.'
        }
        $parsed = Get-WingetPrTitlePackageVersion -Title "$($titleProperty.Value)"
        if ($null -ne $parsed -and $parsed.PackageIdentifier -ieq $PackageIdentifier) {
            $items.Add($candidate)
        }
        return $false
    }

    $null = Find-WingetPkgsExistingPrSearchMatch `
        -Query $query `
        -CandidateEvaluator $collector `
        -OperationName "bot $State-PR search for $PackageIdentifier" `
        -AdditionalQueryParameters '&sort=created&order=desc'

    return @($items)
}

function Find-WingetPkgsBlockedBotPr {
    <#
    .SYNOPSIS
        Finds a closed, unmerged bot PR for the exact package version that
        upstream rejected with a blocking validation label.

    .DESCRIPTION
        Failure memory: if the bot already submitted this version and the
        moderators closed it with a Defender, URL, certificate, installer or
        driver verdict, resubmitting the unchanged version is noise. Returns
        the newest such PR (Number, Url, Labels, Reason) or $null. A merged PR
        or one without blocking labels never blocks. Only the bot's own PRs
        are considered.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $BotLogin,
        [Parameter()] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository = 'microsoft/winget-pkgs',
        # Injectable for tests: returns the closed bot PR search items.
        [Parameter()] [scriptblock] $SearchInvoker
    )

    if ($null -eq $SearchInvoker) {
        $SearchInvoker = {
            Find-WingetPkgsBotPrSearchItems -Repository $Repository -PackageIdentifier $PackageIdentifier -BotLogin $BotLogin -State 'closed' -Version $Version
        }
    }

    $blockingLabels = Get-WingetBlockingValidationLabels
    $candidates = @(& $SearchInvoker)

    $ordered = @($candidates | Sort-Object -Property @{ Expression = { [int]"$($_.number)" } } -Descending)
    foreach ($pr in $ordered) {
        if ($null -eq $pr) { continue }

        $parsed = Get-WingetPrTitlePackageVersion -Title "$($pr.title)"
        if ($null -eq $parsed -or $parsed.PackageIdentifier -ine $PackageIdentifier -or $parsed.Version -ine $Version) { continue }

        $stateProperty = $pr.PSObject.Properties['state']
        if ($null -ne $stateProperty -and "$($stateProperty.Value)".ToLowerInvariant() -ne 'closed') { continue }

        $pullRequestProperty = $pr.PSObject.Properties['pull_request']
        if ($null -ne $pullRequestProperty -and $null -ne $pullRequestProperty.Value) {
            $mergedAtProperty = $pullRequestProperty.Value.PSObject.Properties['merged_at']
            if ($null -ne $mergedAtProperty -and -not [string]::IsNullOrWhiteSpace("$($mergedAtProperty.Value)")) {
                # Merged: the version is published; the version check handles that.
                continue
            }
        }

        $labels = @(Get-WingetPrLabelNames -Pr $pr)
        $matched = @($labels | Where-Object { $_ -in $blockingLabels })
        if ($matched.Count -eq 0) { continue }

        $number = 0
        [void][int]::TryParse("$($pr.number)", [ref] $number)
        $urlProperty = $pr.PSObject.Properties['html_url']

        return [PSCustomObject]@{
            Number = $number
            Title  = "$($pr.title)"
            Url    = if ($null -ne $urlProperty) { "$($urlProperty.Value)" } else { '' }
            Labels = $matched
            Reason = "upstream closed the bot's PR #$number for $PackageIdentifier $Version with $($matched -join ', '); the unchanged version is not resubmitted"
        }
    }

    return $null
}

function Find-WingetPkgsPatchSupersessionHold {
    <#
    .SYNOPSIS
        Searches the bot's open PRs for the package and applies
        Select-WingetPatchSupersessionHold.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $BotLogin,
        [Parameter()] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository = 'microsoft/winget-pkgs',
        [Parameter()] [ValidateRange(1, 365)] [int] $MaxAgeDays = 14,
        # Injectable for tests: returns the open bot PR search items.
        [Parameter()] [scriptblock] $SearchInvoker
    )

    if ($null -eq $SearchInvoker) {
        $SearchInvoker = {
            Find-WingetPkgsBotPrSearchItems -Repository $Repository -PackageIdentifier $PackageIdentifier -BotLogin $BotLogin -State 'open'
        }
    }

    $openPrs = @(& $SearchInvoker)
    return Select-WingetPatchSupersessionHold -OpenPrs $openPrs -PackageIdentifier $PackageIdentifier -NewVersion $Version -MaxAgeDays $MaxAgeDays
}
