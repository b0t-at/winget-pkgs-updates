function Get-WingetManifestInstallerSha256Values {
    <#
    .SYNOPSIS
        Extracts unique InstallerSha256 values from manifest YAML content.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    $hashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($Content, 'InstallerSha256\s*:\s*([A-Fa-f0-9]{64})')) {
        [void]$hashes.Add($match.Groups[1].Value.ToUpperInvariant())
    }
    return @($hashes)
}

function Get-WingetManifestInstallerSha256ValuesFromPath {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string] $ManifestPath
    )

    $hashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in Get-ChildItem -LiteralPath $ManifestPath -Filter '*.yaml' -File) {
        foreach ($hash in Get-WingetManifestInstallerSha256Values -Content (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop)) {
            [void]$hashes.Add($hash)
        }
    }
    return @($hashes)
}

function Get-WingetDuplicateIdentifierCandidatesFromSearchItems {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $Items,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    $lastSegment = ($PackageIdentifier -split '\.')[-1]
    $candidates = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $title = "$($item.title)"
        if ([string]::IsNullOrWhiteSpace($title)) { continue }

        foreach ($match in [regex]::Matches($title, '(?<![A-Za-z0-9._+-])(?<Id>[A-Za-z0-9_+-]+(?:\.[A-Za-z0-9_+-]+)+)(?![A-Za-z0-9._+-])')) {
            $identifier = $match.Groups['Id'].Value
            if ($identifier -ieq $PackageIdentifier) { continue }
            if (-not $identifier.EndsWith(".$lastSegment", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($title -notmatch [regex]::Escape($Version)) { continue }
            [void]$candidates.Add($identifier)
        }
    }
    return @($candidates)
}

function Get-WingetPkgsInstallerManifestContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)] [string] $Repository,
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version
    )

    $manifestPath = Get-WingetPkgsManifestVersionPathPrefix -PackageIdentifier $PackageIdentifier -Version $Version
    $manifestPath += "$PackageIdentifier.installer.yaml"
    $raw = Invoke-GhCliWithRetry -OperationName "installer manifest read for $PackageIdentifier $Version" -ScriptBlock {
        gh api -X GET "repos/$Repository/contents/$manifestPath" -f ref=master --jq .content
    }
    if ($LASTEXITCODE -ne 0) {
        throw "gh installer manifest read failed with exit code $LASTEXITCODE."
    }
    $base64 = ((@($raw) | ForEach-Object { [string]$_ }) -join '').Trim() -replace '\s', ''
    if ([string]::IsNullOrWhiteSpace($base64)) {
        throw "GitHub returned empty installer manifest content for $PackageIdentifier $Version."
    }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64))
}

function Find-WingetDuplicateIdentifierByInstallerHash {
    <#
    .SYNOPSIS
        Detects another winget identifier for the same version carrying one of
        the generated installer hashes.

    .DESCRIPTION
        This is a fail-open pre-submission guard for repository moves: API
        errors become warnings, but a confirmed hash match under another
        identifier stops submission with DuplicateOfOtherIdentifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageIdentifier,
        [Parameter(Mandatory = $true)] [string] $Version,
        [Parameter(Mandatory = $true)] [string] $ManifestPath,
        [Parameter()] [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')] [string] $Repository = 'microsoft/winget-pkgs',
        [Parameter()] [scriptblock] $SearchInvoker,
        [Parameter()] [scriptblock] $ManifestReader
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $localHashes = @(Get-WingetManifestInstallerSha256ValuesFromPath -ManifestPath $ManifestPath)
    if ($localHashes.Count -eq 0) {
        return [PSCustomObject]@{ Duplicate = $false; Reason = $null; MatchingIdentifier = $null; MatchingHash = $null; MatchingUrl = $null; Warnings = @() }
    }

    $lastSegment = ($PackageIdentifier -split '\.')[-1]

    $items = @()
    try {
        if ($null -ne $SearchInvoker) {
            $items = @(& $SearchInvoker)
        }
        else {
            $query = "repo:$Repository is:pr in:title `"$lastSegment`" `"$Version`""
            $raw = Invoke-GhCliWithRetry -OperationName "duplicate identifier search for $PackageIdentifier $Version" -ScriptBlock {
                gh api -X GET 'search/issues' -f q=$query -f per_page=30 --jq '[.items[] | {number: .number, title: .title, body: .body, html_url: .html_url}]'
            }
            if ($LASTEXITCODE -ne 0) {
                throw "gh duplicate identifier search failed with exit code $LASTEXITCODE."
            }
            $json = (@($raw) -join "`n").Trim()
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $items = @($json | ConvertFrom-Json)
            }
        }
    }
    catch {
        $warnings.Add("Duplicate identifier search failed for ${PackageIdentifier}: $($_.Exception.Message)")
        $global:LASTEXITCODE = 0
        return [PSCustomObject]@{ Duplicate = $false; Reason = $null; MatchingIdentifier = $null; MatchingHash = $null; MatchingUrl = $null; Warnings = @($warnings) }
    }

    $candidateIdentifiers = @(Get-WingetDuplicateIdentifierCandidatesFromSearchItems -Items $items -PackageIdentifier $PackageIdentifier -Version $Version)
    foreach ($candidateIdentifier in $candidateIdentifiers) {
        try {
            if ($null -ne $ManifestReader) {
                $remoteContent = & $ManifestReader $candidateIdentifier
            }
            else {
                $remoteContent = Get-WingetPkgsInstallerManifestContent -Repository $Repository -PackageIdentifier $candidateIdentifier -Version $Version
            }
            $remoteHashes = @(Get-WingetManifestInstallerSha256Values -Content $remoteContent)
        }
        catch {
            $warnings.Add("Could not read installer manifest for possible duplicate ${candidateIdentifier} ${Version}: $($_.Exception.Message)")
            $global:LASTEXITCODE = 0
            continue
        }

        foreach ($hash in $localHashes) {
            if ($remoteHashes -contains $hash) {
                $matchingItem = @($items | Where-Object { "$($_.title)" -match [regex]::Escape($candidateIdentifier) } | Select-Object -First 1)
                $url = if ($matchingItem.Count -gt 0) { "$($matchingItem[0].html_url)" } else { '' }
                return [PSCustomObject]@{
                    Duplicate          = $true
                    Reason             = 'DuplicateOfOtherIdentifier'
                    MatchingIdentifier = $candidateIdentifier
                    MatchingHash       = $hash
                    MatchingUrl        = $url
                    Warnings           = @($warnings)
                }
            }
        }
    }

    return [PSCustomObject]@{ Duplicate = $false; Reason = $null; MatchingIdentifier = $null; MatchingHash = $null; MatchingUrl = $null; Warnings = @($warnings) }
}
