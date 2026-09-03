function Get-GHReleaseFreshnessHold {
    <#
    .SYNOPSIS
        Decides whether a GitHub release is still too fresh to be submitted.

    .DESCRIPTION
        Publishers frequently re-upload assets in the first hours after a
        release (hash mismatches, temporarily missing installers) and some
        publishers file their own winget PR within hours. The orchestrator
        therefore waits until the newest relevant asset upload is at least
        MinAgeHours old. The age is measured from the newest of: the release's
        published_at and the updated_at (fallback created_at) of the assets
        whose download URL the package actually uses; when none of the
        requested URLs matches an asset, every asset counts.

        Returns $null when the release is old enough (or MinAgeHours is 0), or
        a hold object (AgeHours, MinAgeHours, NewestAt, Reason) otherwise.
        Lookup failures surface as exceptions so the caller can fail open.

    .PARAMETER Repo
        GitHub repository in owner/name form.

    .PARAMETER Tag
        Release tag to inspect.

    .PARAMETER InstallerUrls
        Installer download URLs (architecture/scope hints already stripped).

    .PARAMETER MinAgeHours
        Minimum age in hours. 0 disables the gate.

    .PARAMETER ReleaseProvider
        Injectable for tests: returns the REST release object
        (published_at, assets[].browser_download_url/updated_at/created_at).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repo,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Tag,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]] $InstallerUrls = @(),

        [Parameter()]
        [ValidateRange(0, 8760)]
        [double] $MinAgeHours = 0,

        [Parameter()]
        [scriptblock] $ReleaseProvider,

        [Parameter()]
        [datetime] $Now = [datetime]::UtcNow
    )

    if ($MinAgeHours -le 0) {
        return $null
    }

    if ($null -eq $ReleaseProvider) {
        $ReleaseProvider = {
            Invoke-GhCliWithRetry -OperationName "gh api release $Tag for $Repo" -ScriptBlock {
                gh api "repos/$Repo/releases/tags/$Tag"
            } | ConvertFrom-Json
        }
    }

    $release = & $ReleaseProvider
    if ($null -eq $release) {
        throw "Release $Tag of $Repo could not be read."
    }

    $timestamps = [System.Collections.Generic.List[datetime]]::new()
    $parseTimestamp = {
        param($Value)
        $parsed = [datetime]::MinValue
        if ($null -ne $Value -and [datetime]::TryParse("$Value", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) {
            return $parsed
        }
        return $null
    }

    $publishedAt = & $parseTimestamp (Get-WingetGraphQlFieldValue -InputObject $release -Name 'published_at')
    if ($null -ne $publishedAt) { $timestamps.Add($publishedAt) }

    $assetsValue = Get-WingetGraphQlFieldValue -InputObject $release -Name 'assets'
    $assets = if ($null -eq $assetsValue) { @() } else { @($assetsValue | Where-Object { $null -ne $_ }) }
    $requested = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($url in $InstallerUrls) {
        if (-not [string]::IsNullOrWhiteSpace($url)) { $null = $requested.Add($url.Trim()) }
    }

    $matchingAssets = @($assets | Where-Object {
            $downloadUrl = [string](Get-WingetGraphQlFieldValue -InputObject $_ -Name 'browser_download_url')
            -not [string]::IsNullOrWhiteSpace($downloadUrl) -and $requested.Contains($downloadUrl.Trim())
        })
    $relevantAssets = if ($matchingAssets.Count -gt 0) { $matchingAssets } else { $assets }

    foreach ($asset in $relevantAssets) {
        $assetTime = & $parseTimestamp (Get-WingetGraphQlFieldValue -InputObject $asset -Name 'updated_at')
        if ($null -eq $assetTime) {
            $assetTime = & $parseTimestamp (Get-WingetGraphQlFieldValue -InputObject $asset -Name 'created_at')
        }
        if ($null -ne $assetTime) { $timestamps.Add($assetTime) }
    }

    if ($timestamps.Count -eq 0) {
        throw "Release $Tag of $Repo exposes neither a publish time nor asset upload times."
    }

    $newestAt = ($timestamps | Sort-Object -Descending | Select-Object -First 1).ToUniversalTime()
    $ageHours = ($Now.ToUniversalTime() - $newestAt).TotalHours
    if ($ageHours -ge $MinAgeHours) {
        return $null
    }

    $assetScope = if ($matchingAssets.Count -gt 0) { "$($matchingAssets.Count) requested asset(s)" } else { "all $($assets.Count) asset(s)" }
    return [PSCustomObject]@{
        AgeHours    = [Math]::Round([Math]::Max(0, $ageHours), 2)
        MinAgeHours = $MinAgeHours
        NewestAt    = $newestAt.ToString('o')
        Reason      = "release $Tag of $Repo was last touched $([Math]::Round([Math]::Max(0, $ageHours), 1)) h ago (newest of publish time and ${assetScope}: $($newestAt.ToString('u'))); waiting until it is $MinAgeHours h old"
    }
}

function Resolve-WingetMinReleaseAgeHours {
    <#
    .SYNOPSIS
        Resolves the effective minimum release age for a package.

    .DESCRIPTION
        Precedence: the package's configured value (matrix field
        minReleaseAgeHours) > WINGET_MIN_RELEASE_AGE_HOURS environment variable
        > built-in default of 0 hours (disabled). Blank or non-numeric values fall through
        to the next tier; negative values are treated as 0 (disabled).
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Configured,
        [Parameter()] [double] $Default = 0
    )

    foreach ($candidate in @($Configured, $env:WINGET_MIN_RELEASE_AGE_HOURS)) {
        $value = 0.0
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            [double]::TryParse("$candidate".Trim(), [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref] $value)) {
            return [Math]::Max(0, $value)
        }
    }

    return $Default
}
