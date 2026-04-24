$redirectUrl = "https://www.amazon.com/kindlepcdownload"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:149.0) Gecko/20100101 Firefox/149.0"
try {
    Invoke-WebRequest -Method Get -Uri $redirectUrl -MaximumRedirection 0 -UserAgent $UserAgent -ErrorAction Stop
}
catch {
    if ($_.Exception.Response.StatusCode -eq 301) {
        $RedirectUrl = $_.Exception.Response.Headers.Location
    }
}

if(!$RedirectUrl) {
    throw "Failed to retrieve the redirect URL."
}

$latestVersionUrl = $RedirectUrl.AbsoluteUri
#$latestVersion = [regex]::Match($RedirectUrl.AbsolutePath, '.*.*KindleForPC-installer-(\d+.\d+.\d+).*').Groups[1].Value
Write-Host "Full download URL: $latestVersionUrl"
$latestVersion = Get-ProductVersionFromFile -WebsiteURL $latestVersionUrl -VersionInfoProperty "ProductVersion"

return [PSCustomObject]@{
    Version = $latestVersion
    URLs    = $latestVersionUrl
}