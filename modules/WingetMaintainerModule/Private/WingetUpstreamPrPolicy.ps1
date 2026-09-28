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

function Get-WingetWaivedValidationLabelNames {
    <#
    .SYNOPSIS
        Returns waiver labels that should hold supersession for a bounded time.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()] [AllowNull()] $Pr
    )

    return @(Get-WingetPrLabelNames -Pr $Pr | Where-Object { $_ -like 'Waived-*' })
}

function Get-WingetPrTimestamp {
    [CmdletBinding()]

    param(
        [Parameter()] [AllowNull()] $Pr,
        [Parameter(Mandatory = $true)] [string[]] $PropertyNames
    )

    if ($null -eq $Pr) { return $null }
    foreach ($propertyName in $PropertyNames) {
        $property = $Pr.PSObject.Properties[$propertyName]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace("$($property.Value)")) { continue }
        $timestamp = [datetime]::MinValue
        if ([datetime]::TryParse(
                "$($property.Value)",
                [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal,
                [ref] $timestamp)) {
            return $timestamp.ToUniversalTime()
        }
    }

    return $null
}

function Get-WingetWaivedValidationHold {
    <#
    .SYNOPSIS
        Returns hold metadata when an open PR has an active Waived-* label.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [AllowNull()] $Pr,
        [Parameter()] [ValidateRange(1, 365)] [int] $MaxAgeDays = 30,
        [Parameter()] [datetime] $Now = [datetime]::UtcNow
    )

    $waivedLabels = @(Get-WingetWaivedValidationLabelNames -Pr $Pr)
    if ($waivedLabels.Count -eq 0) { return $null }

    # Search results do not carry label-event timestamps. Prefer an injected
    # waiver timestamp when available (tests/future callers), otherwise use the
    # PR creation time as the conservative start of the 30-day hold window.
    $anchor = Get-WingetPrTimestamp -Pr $Pr -PropertyNames @('waived_at', 'waivedAt', 'created_at', 'createdAt')
    if ($null -eq $anchor) { return $null }

    $ageDays = ($Now.ToUniversalTime() - $anchor.ToUniversalTime()).TotalDays
    if ($ageDays -ge $MaxAgeDays) { return $null }

    return [PSCustomObject]@{
        Labels     = $waivedLabels
        AgeDays    = [Math]::Round($ageDays, 1)
        MaxAgeDays = $MaxAgeDays
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


function Find-WingetPkgsWaivedValidationHold {
    <#
    .SYNOPSIS
        Searches open bot PRs for a Waived-* validation label that should stop
        superseding the package for up to 30 days.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $BotLogin,
        [Parameter()] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository = 'microsoft/winget-pkgs',
        [Parameter()] [ValidateRange(1, 365)] [int] $MaxAgeDays = 30,
        [Parameter()] [datetime] $Now = [datetime]::UtcNow,
        [Parameter()] [scriptblock] $SearchInvoker
    )

    if ($null -eq $SearchInvoker) {
        $SearchInvoker = {
            Find-WingetPkgsBotPrSearchItems -Repository $Repository -PackageIdentifier $PackageIdentifier -BotLogin $BotLogin -State 'open'
        }
    }

    $newVersionKey = Get-WingetSortableVersionKey -Version $Version
    $openPrs = @(& $SearchInvoker)
    foreach ($pr in $openPrs) {
        if ($null -eq $pr) { continue }
        $number = 0
        if (-not [int]::TryParse("$($pr.number)", [ref] $number) -or $number -le 0) { continue }

        $parsed = Get-WingetPrTitlePackageVersion -Title "$($pr.title)"
        if ($null -eq $parsed -or $parsed.PackageIdentifier -ine $PackageIdentifier) { continue }

        $prVersionKey = Get-WingetSortableVersionKey -Version $parsed.Version
        if ([string]::IsNullOrWhiteSpace($prVersionKey) -or $prVersionKey -ge $newVersionKey) { continue }

        $waived = Get-WingetWaivedValidationHold -Pr $pr -MaxAgeDays $MaxAgeDays -Now $Now
        if ($null -eq $waived) { continue }

        $urlProperty = $pr.PSObject.Properties['html_url']
        if ($null -eq $urlProperty) { $urlProperty = $pr.PSObject.Properties['url'] }

        return [PSCustomObject]@{
            Number     = $number
            Title      = "$($pr.title)"
            Version    = $parsed.Version
            Url        = if ($null -ne $urlProperty) { "$($urlProperty.Value)" } else { '' }
            Labels     = $waived.Labels
            AgeDays    = $waived.AgeDays
            MaxAgeDays = $waived.MaxAgeDays
            Reason     = "open PR #$number ($PackageIdentifier $($parsed.Version)) carries waived validation label(s) $($waived.Labels -join ', ') and is only $($waived.AgeDays) day(s) into the waiver hold; release $Version waits for moderator-waived validation (supersedes after $MaxAgeDays days)"
        }
    }

    return $null
}
