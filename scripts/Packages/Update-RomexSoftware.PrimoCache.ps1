# Download the webpage
$website = Invoke-WebRequest -Uri $WebsiteURL
$WebsiteContent = $website.Content
$WebsiteLinks = $website.Links

# Extract version using multiple patterns
$versionPatterns = @(
    "PrimoCache[^\d]*(\d+\.\d+\.\d+)",
    "Version[^\d]*(\d+\.\d+\.\d+)",
    "v(\d+\.\d+\.\d+)",
    "Download[^\d]*(\d+\.\d+\.\d+)",
    "PrimoCache_Setup_(\d+\.\d+\.\d+)\.exe"
)

$allVersions = @()
foreach ($pattern in $versionPatterns) {
    $matches = $WebsiteContent | Select-String -Pattern $pattern -AllMatches
    if ($matches) {
        $allVersions += $matches.Matches | ForEach-Object { $_.Groups[1].Value }
    }
}

# Fallback: extract from download links
if ($allVersions.Count -eq 0) {
    $downloadLinks = $WebsiteLinks | Where-Object { $_.href -match "PrimoCache_Setup_(\d+\.\d+\.\d+)\.exe" }
    if ($downloadLinks) {
        $allVersions = $downloadLinks | ForEach-Object { 
            $match = [regex]::Match($_.href, "PrimoCache_Setup_(\d+\.\d+\.\d+)\.exe")
            if ($match.Success) { $match.Groups[1].Value }
        } | Where-Object { $_ }
    }
}

# Get latest version
$latestVersion = $null
if ($allVersions.Count -gt 0) {
    $uniqueVersions = $allVersions | Sort-Object -Unique
    try {
        $latestVersion = ($uniqueVersions | ForEach-Object { [System.Version]$_ } | Sort-Object -Descending | Select-Object -First 1).ToString()
    } catch {
        $latestVersion = $uniqueVersions | Sort-Object -Descending | Select-Object -First 1
    }
}

# Validate version and construct URL
if (-not $latestVersion) {
    Write-Warning "Could not extract version from website"
    return [PSCustomObject]@{ SilentFail = $true }
}

$latestVersionUrl = "https://static.romexsoftware.com/download/primo-cache/PrimoCache_Setup_$latestVersion.exe"

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