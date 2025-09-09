$WebsiteURL = "https://support.loupedeck.com/loupedeck-software-download"

$websiteData = Invoke-WebRequest -Method Get -Uri $WebsiteURL

$installerLink = ($websiteData.Links | Where-Object { $_.href -like "*.exe*" } | Select-Object -ExpandProperty href).ToString()

if($installerLink.Count -eq 0 -or $installerLink.Count -gt 1) {
    Write-Host "No installer links or too much installer links found"
    exit 1
}

# get substring position "SoftwareDownloads and replace everything until there with prefix url"
#$installerLink = $installerLink.Substring($installerLink.IndexOf("LD%20Software%20Downloads"))
#$fullDownloadURL = "https://support.loupedeck.com/hubfs/Knowledge%20Base/$installerLink"
$fullDownloadURL = $installerLink.Split('?')[0]
# check if full download URL is valid
Write-Host "Full download URL: $fullDownloadURL"

# download latest version from loupedeck.com and get version by filename
$versionInfo = Get-ProductVersionFromFile -WebsiteURL $fullDownloadURL -VersionInfoProperty "ProductVersion"

Write-Host "Found latest version: $versionInfo"
$latestversion = $versionInfo

# check if full download URL is valid
$fullDownloadURLResponse = Invoke-WebRequest -Uri $fullDownloadURL -UseBasicParsing -Method Head
if ($fullDownloadURLResponse.StatusCode -ne 200) {
    Write-Host "Full download URL is not valid"
    exit 1
}

return [PSCustomObject]@{
    Version = $latestVersion
    URLs = $fullDownloadURL
  }