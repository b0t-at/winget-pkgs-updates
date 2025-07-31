# Download the webpage
$website = Invoke-WebRequest -Uri $WebsiteURL
$WebsiteContent = $website.Content
$WebsiteLinks = $website.Links

# Find download links that match PrimoCache pattern
$downloadLinks = $WebsiteLinks | Where-Object { $_.href -match "PrimoCache_Setup_(\d+\.\d+\.\d+)\.exe" }

$versionUrlPairs = @()
if ($downloadLinks) {
    # Extract version and URL pairs from actual download links
    $versionUrlPairs = $downloadLinks | ForEach-Object { 
        $match = [regex]::Match($_.href, "PrimoCache_Setup_(\d+\.\d+\.\d+)\.exe")
        if ($match.Success) {
            $version = $match.Groups[1].Value
            $url = $_.href
            
            # Make URL absolute if it's relative
            if ($url -notmatch "^https?://") {
                $baseUri = [System.Uri]$WebsiteURL
                $url = [System.Uri]::new($baseUri, $url).ToString()
            }
            
            [PSCustomObject]@{
                Version = $version
                URL = $url
            }
        }
    } | Where-Object { $_ }
}

# Fallback: extract versions from webpage content if no download links found
if ($versionUrlPairs.Count -eq 0) {
    $versionPatterns = @(
        "PrimoCache[^\d]*(\d+\.\d+\.\d+)",
        "Version[^\d]*(\d+\.\d+\.\d+)",
        "v(\d+\.\d+\.\d+)",
        "Download[^\d]*(\d+\.\d+\.\d+)"
    )

    $allVersions = @()
    foreach ($pattern in $versionPatterns) {
        $matches = $WebsiteContent | Select-String -Pattern $pattern -AllMatches
        if ($matches) {
            $allVersions += $matches.Matches | ForEach-Object { $_.Groups[1].Value }
        }
    }
    
    # If we found versions but no download links, we cannot proceed without constructing URLs
    if ($allVersions.Count -eq 0) {
        Write-Warning "Could not find download links or extract version from website"
        return [PSCustomObject]@{ SilentFail = $true }
    }
    
    Write-Warning "Could not find download links, but found versions. Unable to determine download URLs without constructing them."
    return [PSCustomObject]@{ SilentFail = $true }
}

# Get latest version from the found download links
$latestVersionUrl = $null
$latestVersion = $null

if ($versionUrlPairs.Count -gt 0) {
    try {
        # Sort by version and get the latest
        $latestPair = $versionUrlPairs | Sort-Object { [System.Version]$_.Version } -Descending | Select-Object -First 1
        $latestVersion = $latestPair.Version
        $latestVersionUrl = $latestPair.URL
    } catch {
        # Fallback to string sorting
        $latestPair = $versionUrlPairs | Sort-Object Version -Descending | Select-Object -First 1
        $latestVersion = $latestPair.Version
        $latestVersionUrl = $latestPair.URL
    }
}

if (-not $latestVersion -or -not $latestVersionUrl) {
    Write-Warning "Could not determine latest version and download URL from website"
    return [PSCustomObject]@{ SilentFail = $true }
}

# Verify the download URL exists
try {
    $response = Invoke-WebRequest -Method Head -Uri $latestVersionUrl -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        Write-Warning "Download URL does not exist: $latestVersionUrl"
        return [PSCustomObject]@{ SilentFail = $true }
    }
} catch {
    Write-Warning "Could not verify download URL: $latestVersionUrl - $($_.Exception.Message)"
    return [PSCustomObject]@{ SilentFail = $true }
}

return [PSCustomObject]@{
    Version = $latestVersion
    URLs = $latestVersionUrl
}