function Get-LatestGHVersionTag {
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$TagPattern
    )


    $releases = gh release list --repo $Repo --json "name,tagName,publishedAt,isLatest,isPrerelease" | ConvertFrom-Json | Where-Object { $_.isPrerelease -eq $false }
    if ($TagPattern) {
        $releases = $releases | Where-Object { $_.tagName -match $TagPattern }
        $latestRelease = $releases | Sort-Object -Property publishedAt -Descending | Select-Object -First 1
    }
    else {
        $latestRelease = $releases | Where-Object { $_.isLatest -eq $true } | Sort-Object -Property publishedAt -Descending | Select-Object -First 1
    }
    $latestVersionTag = $latestRelease.tagName

    # Fallback: gh release list may omit the GitHub-marked "latest" release.
    # Query the dedicated releases/latest endpoint as a backup.
    if (-not $latestVersionTag -and -not $TagPattern) {
        try {
            $latestApi = gh api "repos/$Repo/releases/latest" 2>$null | ConvertFrom-Json
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
        Write-Host "No Tag found for Repo $Repo"
        exit 1
    }
}