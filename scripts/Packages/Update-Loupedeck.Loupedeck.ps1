$WebsiteURL = "https://loupedeck.com/get-started/"

$websiteData = Invoke-WebRequest -Method Get -Uri $WebsiteURL -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

$installerLink = ($websiteData.Links | Where-Object { $_.href -like "*support.loupedeck.com/hubfs/*LD%20Software%20Downloads/*.exe*" } | Select-Object -ExpandProperty href -Unique).ToString()

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