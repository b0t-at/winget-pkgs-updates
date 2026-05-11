function Get-WingetPackageRelativePath {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier
    )

    if ([string]::IsNullOrWhiteSpace($PackageIdentifier)) {
        throw 'PackageIdentifier is required.'
    }

    $firstChar = $PackageIdentifier.Substring(0, 1).ToLowerInvariant()
    $packagePath = $PackageIdentifier.Replace('.', '/')
    return "manifests/$firstChar/$packagePath"
}

function Get-WingetGitHubHeaders {
    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'winget-pkgs-updates'
    }

    if (-not [string]::IsNullOrWhiteSpace($env:WINGET_PKGS_GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:WINGET_PKGS_GITHUB_TOKEN)"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)"
    }

    return $headers
}

function Get-WingetPublishedVersionsFromGitHub {
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier
    )

    $packageRelativePath = Get-WingetPackageRelativePath -PackageIdentifier $PackageIdentifier
    $uri = "https://api.github.com/repos/microsoft/winget-pkgs/contents/$packageRelativePath`?ref=master"
    $response = Invoke-WebRequest -Uri $uri -Headers (Get-WingetGitHubHeaders) -Method Get -SkipHttpErrorCheck
    $statusCode = [int]$response.StatusCode

    if ($statusCode -eq 404) {
        return [PSCustomObject]@{
            PackageExists = $false
            Versions      = @()
        }
    }

    if ($statusCode -lt 200 -or $statusCode -ge 300) {
        throw "GitHub API request failed for $PackageIdentifier with HTTP status $statusCode."
    }

    $entries = @($response.Content | ConvertFrom-Json)
    $versions = @($entries | Where-Object { $_.type -eq 'dir' } | ForEach-Object { [string]$_.name } | Sort-Object -Unique)

    return [PSCustomObject]@{
        PackageExists = $true
        Versions      = $versions
    }
}

function Get-WingetSortableVersionKey {
    param([AllowNull()] [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version)) {
        return ''
    }

    return [regex]::Replace($Version, '(\d+)', {
            param($Match)
            $Match.Value.PadLeft(20, '0')
        })
}

function Get-WingetNumericVersionAlias {
    param([AllowNull()] [string] $Version)

    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^\d+(\.\d+)*$') {
        return $null
    }

    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($segment in $Version.Split('.')) {
        $normalizedSegment = $segment.TrimStart('0')
        if ([string]::IsNullOrWhiteSpace($normalizedSegment)) {
            $normalizedSegment = '0'
        }
        $segments.Add($normalizedSegment)
    }

    while ($segments.Count -gt 1 -and $segments[$segments.Count - 1] -eq '0') {
        $segments.RemoveAt($segments.Count - 1)
    }

    return ($segments.ToArray() -join '.')
}

function Find-WingetPublishedVersionMatch {
    param(
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $false)] [string[]] $PublishedVersions = @()
    )

    $exactMatch = @($PublishedVersions | Where-Object { $_ -eq $Version } | Select-Object -First 1)
    if ($exactMatch.Count -gt 0) {
        return [PSCustomObject]@{
            Version   = $exactMatch[0]
            MatchType = 'Exact'
        }
    }

    $versionAlias = Get-WingetNumericVersionAlias -Version $Version
    if ([string]::IsNullOrWhiteSpace($versionAlias)) {
        return $null
    }

    $aliasMatches = @($PublishedVersions |
        Where-Object { $_ -ne $Version -and (Get-WingetNumericVersionAlias -Version $_) -eq $versionAlias } |
        Sort-Object { Get-WingetSortableVersionKey -Version $_ } -Descending)

    if ($aliasMatches.Count -gt 0) {
        return [PSCustomObject]@{
            Version   = $aliasMatches[0]
            MatchType = 'NumericAlias'
        }
    }

    return $null
}

function ConvertTo-WingetVersionStyle {
    param(
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $false)] [string[]] $PublishedVersions = @()
    )

    if ([string]::IsNullOrWhiteSpace($Version) -or $Version -notmatch '^\d+(\.\d+)*$') {
        return $Version
    }

    $requestedSegments = $Version.Split('.')
    $styleCandidates = @($PublishedVersions |
        Where-Object { $_ -match '^\d+(\.\d+)*$' -and $_.Split('.').Count -eq $requestedSegments.Count } |
        Sort-Object { Get-WingetSortableVersionKey -Version $_ } -Descending)

    if ($styleCandidates.Count -eq 0) {
        return $Version
    }

    $styleSegments = $styleCandidates[0].Split('.')
    $alignedSegments = [System.Collections.Generic.List[string]]::new()

    for ($index = 0; $index -lt $requestedSegments.Count; $index++) {
        $requestedSegment = $requestedSegments[$index]
        $styleSegment = $styleSegments[$index]
        $normalizedSegment = $requestedSegment.TrimStart('0')
        if ([string]::IsNullOrWhiteSpace($normalizedSegment)) {
            $normalizedSegment = '0'
        }

        if ($styleSegment -match '^0+\d+$') {
            $alignedSegments.Add($normalizedSegment.PadLeft($styleSegment.Length, '0'))
        }
        else {
            $alignedSegments.Add($normalizedSegment)
        }
    }

    return ($alignedSegments.ToArray() -join '.')
}