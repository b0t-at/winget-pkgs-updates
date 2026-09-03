function Get-WingetPreSubmissionHold {
    <#
    .SYNOPSIS
        Applies the submission policies that decide whether a new version
        should NOT be generated right now even though it is unpublished and has
        no open duplicate PR.

    .DESCRIPTION
        Evaluated in order; the first hold wins:
          1. ReleaseTooFresh - the GitHub release (newest relevant asset upload)
             is younger than the package's minimum age (disabled by default, see
             Resolve-WingetMinReleaseAgeHours). GitHub-release packages only.
          2. BlockedByUpstreamValidation - the bot's previous PR for this exact
             version was closed unmerged with a blocking validation label
             (Defender, dead URL, certificate, driver, installer crash ...).
          3. HeldForManualValidation - the bot's open PR for an older version of
             the package sits in the moderators' manual-validation queue
             (Azure-Pipeline-Passed + Validation-Executable-Error /
             Validation-No-Executables), is younger than 14 days and the new
             version is only a patch bump.
        Every lookup is fail-open: an API failure is reported as a warning and
        never suppresses an update. Bot-scoped checks are skipped when the bot
        login cannot be resolved (see Get-WingetBotLogin).

    .OUTPUTS
        $null when nothing holds, otherwise an object with Reason (a
        GITHUB_OUTPUT-safe token) and Detail (human-readable explanation).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageId,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter()] [AllowEmptyCollection()] [string[]] $InstallerUrls = @(),
        [Parameter()] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository = 'microsoft/winget-pkgs',
        [Parameter()] [AllowEmptyString()] [string] $GHRepo,
        [Parameter()] [AllowEmptyString()] [string] $GHTag,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $MinReleaseAgeHours
    )

    if (-not [string]::IsNullOrWhiteSpace($GHRepo) -and -not [string]::IsNullOrWhiteSpace($GHTag)) {
        $minAgeHours = Resolve-WingetMinReleaseAgeHours -Configured $MinReleaseAgeHours
        try {
            $freshnessHold = Get-GHReleaseFreshnessHold -Repo $GHRepo -Tag $GHTag -InstallerUrls $InstallerUrls -MinAgeHours $minAgeHours
            if ($null -ne $freshnessHold) {
                return [PSCustomObject]@{ Reason = 'ReleaseTooFresh'; Detail = $freshnessHold.Reason }
            }
        }
        catch {
            Write-Warning "Release freshness check for $PackageId $Version failed: $($_.Exception.Message). Continuing without the delay."
        }
    }

    $botLogin = Get-WingetBotLogin
    if ([string]::IsNullOrWhiteSpace($botLogin)) {
        Write-Host 'Bot login not configured (BOT_LOGIN / WINGET_PKGS_FORK_REPO); skipping upstream PR policy checks.'
        return $null
    }

    try {
        $blocked = Find-WingetPkgsBlockedBotPr -PackageIdentifier $PackageId -Version $Version -BotLogin $botLogin -Repository $Repository
        if ($null -ne $blocked) {
            $detail = $blocked.Reason
            if (-not [string]::IsNullOrWhiteSpace($blocked.Url)) { $detail += " ($($blocked.Url))" }
            return [PSCustomObject]@{ Reason = 'BlockedByUpstreamValidation'; Detail = $detail }
        }
    }
    catch {
        Write-Warning "Upstream failure-memory check for $PackageId $Version failed: $($_.Exception.Message). Continuing."
    }

    try {
        $held = Find-WingetPkgsPatchSupersessionHold -PackageIdentifier $PackageId -Version $Version -BotLogin $botLogin -Repository $Repository
        if ($null -ne $held) {
            $detail = $held.Reason
            if (-not [string]::IsNullOrWhiteSpace($held.Url)) { $detail += " ($($held.Url))" }
            return [PSCustomObject]@{ Reason = 'HeldForManualValidation'; Detail = $detail }
        }
    }
    catch {
        Write-Warning "Manual-validation queue check for $PackageId $Version failed: $($_.Exception.Message). Continuing."
    }

    return $null
}

function Assert-WingetNumericStreamVersion {
    <#
    .SYNOPSIS
        Fails closed when a numeric-stream identifier resolved a version from a
        different stream.

    .DESCRIPTION
        For identifiers whose last segment is a number (OpenJS.Electron.41,
        LookupFoundation.RevitLookup.2021) the resolved version's first numeric
        segment must equal that number. tagPattern is the primary pin; this is
        the runtime backstop against a pattern that is too loose or a tag whose
        spelling does not carry the stream number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageId,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Version,
        [Parameter()] [AllowEmptyString()] [string] $Tag
    )

    if ((Get-WingetPackageIdStreamKind -PackageId $PackageId) -ne 'NumericStream') {
        return
    }

    $stream = [regex]::Match($PackageId, '\.(\d+)$').Groups[1].Value
    $firstSegment = [regex]::Match("$Version", '\d+').Value
    if ([string]::IsNullOrWhiteSpace($firstSegment)) {
        throw "Package ID '$PackageId' pins the $stream stream but the resolved version '$Version' (tag '$Tag') has no numeric segment."
    }

    if ([bigint]::Parse($firstSegment) -ne [bigint]::Parse($stream)) {
        throw "Package ID '$PackageId' pins the $stream stream but resolved version '$Version' (tag '$Tag') belongs to the $firstSegment stream. Tighten the entry's tagPattern in github-releases-monitored.yml."
    }
}
