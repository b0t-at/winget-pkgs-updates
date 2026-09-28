$WebsiteURL = "https://loupedeck.com/get-started/"

$websiteData = Invoke-WebRequest -Method Get -Uri $WebsiteURL -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

$installerLinks = @(
    $websiteData.Links |
        Where-Object { $_.href -match '(?i)/hubfs/.*/LD%20Software%20Downloads/.*/LoupedeckInstaller_(?<Version>\d+(?:\.\d+)+)\.exe(?:\?|$)' } |
        ForEach-Object {
            $href = $_.href.Split('?')[0]
            $versionMatch = [regex]::Match($href, 'LoupedeckInstaller_(?<Version>\d+(?:\.\d+)+)\.exe$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($versionMatch.Success) {
                [PSCustomObject]@{
                    Url     = $href
                    Version = [version]$versionMatch.Groups['Version'].Value
                }
            }
        } |
        Sort-Object -Property Version -Descending |
        Select-Object -Unique -Property Url, Version
)

if ($installerLinks.Count -eq 0) {
    throw "No Loupedeck Windows installer links found on $WebsiteURL."
}

$latest = $installerLinks | Select-Object -First 1
$fullDownloadURL = $latest.Url
$latestVersion = $latest.Version.ToString()

Write-Host "Full download URL: $fullDownloadURL"
Write-Host "Found latest version: $latestVersion"

$fullDownloadURLResponse = Invoke-WebRequest -Uri $fullDownloadURL -UseBasicParsing -Method Head -SkipHttpErrorCheck
if ($fullDownloadURLResponse.StatusCode -ne 200) {
    throw "Loupedeck installer URL is not valid: HTTP $($fullDownloadURLResponse.StatusCode) $fullDownloadURL"
}

return [PSCustomObject]@{
    Version = $latestVersion
    URLs    = $fullDownloadURL
}
