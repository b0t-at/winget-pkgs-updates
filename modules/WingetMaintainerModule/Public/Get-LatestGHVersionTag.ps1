function Get-LatestGHVersionTag {
    <#
    .SYNOPSIS
        Resolves the newest relevant release tag of a GitHub repository.

    .DESCRIPTION
        Scans the newest releases of the repository (shared lookback window, see
        Get-WingetReleaseLookbackWindow) and picks the release for the monitored
        stream:

          - With -TagPattern: newest release (by publish date) whose tag matches.
          - With -AllowPrerelease and no -TagPattern: newest prerelease-flagged
            release (the "prerelease channel"). GitHub's isLatest never points
            at a prerelease, so the repo-global latest would always be wrong.
          - Otherwise: the release GitHub marks as latest, with a REST fallback.

        Prereleases are excluded unless -AllowPrerelease is set.

        Fail-closed guard: when -PackageId looks stream-versioned (e.g.
        OpenJS.Electron.39 or Vendor.App.Beta) and no -TagPattern is given, the
        function throws instead of silently resolving the repo-global latest
        release of a different stream.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$TagPattern,
        # Winget package identifier; enables the stream-versioned fail-closed guard.
        [Parameter(Mandatory = $false)][string]$PackageId,
        # Include prerelease-flagged releases (config key `pre-release: "true"`).
        [Parameter(Mandatory = $false)][switch]$AllowPrerelease
    )

    if (-not $TagPattern -and $PackageId) {
        $streamKind = Get-WingetPackageIdStreamKind -PackageId $PackageId
        if ($streamKind -eq 'NumericStream') {
            throw "Package ID '$PackageId' pins a numeric version stream but no tagPattern is configured for repo '$Repo'. The repo-global latest release would resolve the wrong stream (e.g. Electron 39 -> 43.x). Add a tagPattern to the entry in github-releases-monitored.yml (e.g. tagPattern: '^v39\.')."
        }
        if ($streamKind -eq 'ChannelSuffix' -and -not $AllowPrerelease) {
            throw "Package ID '$PackageId' names a release channel but the entry has neither a tagPattern nor pre-release: `"true`" configured for repo '$Repo'. The repo-global latest release would resolve the stable channel instead. Add a tagPattern and/or pre-release: `"true`" to the entry in github-releases-monitored.yml."
        }
    }

    $releaseWindow = Get-WingetReleaseLookbackWindow
    $releases = Invoke-GhCliWithRetry -OperationName "gh release list for $Repo" -ScriptBlock {
        gh release list --repo $Repo --limit $releaseWindow --json "name,tagName,publishedAt,isLatest,isPrerelease"
    } | ConvertFrom-Json
    if (-not $AllowPrerelease) {
        $releases = $releases | Where-Object { $_.isPrerelease -eq $false }
    }
    if ($TagPattern) {
        $releases = $releases | Where-Object { $_.tagName -match $TagPattern }
        $latestRelease = $releases | Sort-Object -Property publishedAt -Descending | Select-Object -First 1
    }
    elseif ($AllowPrerelease) {
        # Prerelease channel: isLatest never points at a prerelease, so pick the
        # newest prerelease-flagged release instead.
        $latestRelease = $releases | Where-Object { $_.isPrerelease -eq $true } | Sort-Object -Property publishedAt -Descending | Select-Object -First 1
    }
    else {
        $latestRelease = $releases | Where-Object { $_.isLatest -eq $true } | Sort-Object -Property publishedAt -Descending | Select-Object -First 1
    }
    $latestVersionTag = $latestRelease.tagName

    # Fallback: gh release list may omit the GitHub-marked "latest" release.
    # Query the dedicated releases/latest endpoint as a backup. Only meaningful
    # for the default stable-latest selection.
    if (-not $latestVersionTag -and -not $TagPattern -and -not $AllowPrerelease) {
        try {
            $latestApi = Invoke-GhCliWithRetry -OperationName "gh api releases/latest for $Repo" -WarningAction SilentlyContinue -ScriptBlock {
                gh api "repos/$Repo/releases/latest"
            } | ConvertFrom-Json
            if ($latestApi.tag_name) {
                $latestVersionTag = $latestApi.tag_name
            }
        }
        catch { }
    }

    if ($latestVersionTag) {
        Write-Host "Latest Tag of $Repo : $latestVersionTag"
        return $latestVersionTag
    }
    else {
        $selection = if ($TagPattern) {
            "matched tagPattern '$TagPattern'"
        }
        elseif ($AllowPrerelease) {
            'was flagged as prerelease'
        }
        else {
            'was marked latest'
        }
        throw "No release tag found for repo $Repo : none of the newest $releaseWindow releases $selection. Check the entry in github-releases-monitored.yml (tagPattern/pre-release) or whether the stream has ended upstream."
    }
}