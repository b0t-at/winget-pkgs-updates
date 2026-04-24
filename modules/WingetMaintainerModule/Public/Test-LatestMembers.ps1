Function Test-LatestMembers {
    param(
        [Parameter(Mandatory = $true)] $latestObject,
        [string]$versionPattern = '^\d+(?:\.\d+)*(-(?:alpha|beta)\.?\d+)?$',
        [string]$urlPattern = '(?i)^http[s]?:\/\/[^\s]+(\.msi|\.exe|\.appx|\.zip|\.msix|\.msixbundle|\.appxbundle)(\|(x64|x86|x32|arm64|neutral))?$',
        [string]$releaseNotesPattern = 'ReleaseNotes:'
    )
    
    $returnObject = [PSCustomObject]@{
        Version = $latestObject.Version
        URLs = $latestObject.URLs
        ReleaseNotes = $latestObject.ReleaseNotes
    }

    if (-not ($returnObject.Version)) {
        $lines = ($latestObject | Where-Object { $_ -notmatch $releaseNotesPattern }) -split "`n" -split " "

        $version = $lines | Where-Object { $_ -match $versionPattern } | Get-STNumericalSorted -Descending | Select-Object -First 1

        if ($version) {
            $returnObject.Version = $version
        }
        else {
            Write-Host "No Version ($version) found."
            exit 1
        }
    }
    if (-not ($returnObject.URLs)) {
        $lines = ($latestObject | Where-Object { $_ -notmatch $releaseNotesPattern }) -split "`n" -split " "

        $URLs = $lines | Where-Object { $_ -match $urlPattern }

        if ($URLs) {
            $returnObject.URLs = ($URLs -split "," -replace "^\s+|\s+$", "")
        }
        else {
            Write-Host "No URL ($($URLs -join ',')) found."
            exit 1
        }
    }
    if (-not ($returnObject.ReleaseNotes)) {
        $releaseNotes = $latestObject | Where-Object { $_ -match $releaseNotesPattern }
        if ($releaseNotes) {
            $returnObject.ReleaseNotes = $releaseNotes
        }
        else {
            Write-Host "ReleaseNotes not found in the content but releaseNotes are not required."
        }
    }
    return $returnObject
}