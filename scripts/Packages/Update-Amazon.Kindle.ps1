$initialUrl = "https://www.amazon.com/kindlepcdownload"
$UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:149.0) Gecko/20100101 Firefox/149.0"
$maxRedirects = 5

$currentUrl = $initialUrl
$resolvedUrl = $null

for ($hop = 0; $hop -le $maxRedirects; $hop++) {
    $statusCode = $null
    $locationHeader = $null
    $contentType = $null

    try {
        # Disable auto-redirect so we can inspect each hop (status, Location, Content-Type) explicitly.
        $response = Invoke-WebRequest -Method Get -Uri $currentUrl -MaximumRedirection 0 -UserAgent $UserAgent -ErrorAction Stop
        $statusCode = [int]$response.StatusCode
        $contentType = $response.Headers['Content-Type'] | Select-Object -First 1
    }
    catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        # Any non-2xx (redirects included, since MaximumRedirection is 0) lands here.
        $webResponse = $_.Exception.Response
        $statusCode = [int]$webResponse.StatusCode
        $locationHeader = $webResponse.Headers.Location
        if ($webResponse.Content -and $webResponse.Content.Headers -and $webResponse.Content.Headers.ContentType) {
            $contentType = $webResponse.Content.Headers.ContentType.ToString()
        }
    }
    catch {
        throw "Request to '$currentUrl' failed without an HTTP response (final URI checked: $currentUrl): $($_.Exception.Message)"
    }

    # Redirect: Amazon may return any 3xx; capture Location regardless of specific code and keep following the chain.
    if ($statusCode -ge 300 -and $statusCode -lt 400) {
        if (-not $locationHeader) {
            throw "Amazon returned redirect status $statusCode for '$currentUrl' without a Location header (final URI: $currentUrl)."
        }
        $locationUri = [Uri]$locationHeader
        $currentUrl = if ($locationUri.IsAbsoluteUri) { $locationUri.AbsoluteUri } else { [Uri]::new([Uri]$currentUrl, $locationUri).AbsoluteUri }
        Write-Host "Redirect ($statusCode): -> $currentUrl"
        continue
    }

    # Direct response: success without a redirect. Confirm it's actually a download and not a challenge/interstitial page.
    if ($statusCode -ge 200 -and $statusCode -lt 300) {
        if ($contentType -match '(?i)^\s*text/html') {
            throw "Amazon returned an HTML page instead of an installer for '$currentUrl' (status $statusCode, content-type '$contentType'). This usually indicates a challenge/verification page (final URI: $currentUrl)."
        }
        $resolvedUrl = $currentUrl
        break
    }

    # Anything else (4xx/5xx, etc.) is treated as an error/challenge page.
    throw "Amazon returned an unexpected response for '$currentUrl' (status $statusCode, content-type '$contentType'). This may indicate an error or challenge page (final URI: $currentUrl)."
}

if (-not $resolvedUrl) {
    throw "Failed to resolve the Kindle download URL after following $maxRedirects redirect(s) starting from '$initialUrl' (final URI checked: $currentUrl)."
}

$latestVersionUrl = $resolvedUrl
Write-Host "Full download URL: $latestVersionUrl"
$latestVersion = Get-ProductVersionFromFile -WebsiteURL $latestVersionUrl -VersionInfoProperty "ProductVersion"

return [PSCustomObject]@{
    Version = $latestVersion
    URLs    = $latestVersionUrl
}