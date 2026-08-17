function Get-WingetPrTitlePackageVersion {
    <#
    .SYNOPSIS
        Extracts the package identifier and version from one of this tool's own
        pull request titles.

    .DESCRIPTION
        Only the exact title shapes this repository has ever produced are
        parsed ("Update version: <id> version <version>" plus the legacy
        combined "Add version: ... - Update version: ..." form). Anything else
        returns $null so hygiene decisions are never made from a title whose
        meaning is uncertain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Title
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    # The legacy combined form ends with the current form, so matching the
    # final occurrence covers both.
    $match = [regex]::Match(
        $Title.Trim(),
        '(?:^|\s-\s)(?:Update|Add) version:\s+(?<Package>[A-Za-z0-9._+-]+)\s+version\s+(?<Version>[A-Za-z0-9._+-]+)$')
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        PackageIdentifier = $match.Groups['Package'].Value
        Version           = $match.Groups['Version'].Value
    }
}

function Select-WingetSupersededOpenPrs {
    <#
    .SYNOPSIS
        Selects this tool's own open pull requests that are superseded by a
        newly submitted version of the same package.

    .DESCRIPTION
        Pure decision logic: given the bot's open upstream pull requests and a
        freshly submitted package/version, returns the strictly older PRs for
        the same package that should be closed. PRs whose titles cannot be
        parsed, that belong to other packages, that carry the same or a newer
        version, or that are the new PR itself are never selected.

    .OUTPUTS
        Objects with Number, Title, Version and Reason properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $OpenPrs,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string] $NewVersion,

        [Parameter()]
        [int] $NewPrNumber = 0
    )

    $newVersionKey = Get-WingetSortableVersionKey -Version $NewVersion
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($pr in $OpenPrs) {
        if ($null -eq $pr) { continue }

        $number = 0
        if (-not [int]::TryParse("$($pr.number)", [ref] $number) -or $number -le 0) { continue }
        if ($NewPrNumber -gt 0 -and $number -eq $NewPrNumber) { continue }

        $parsed = Get-WingetPrTitlePackageVersion -Title "$($pr.title)"
        if ($null -eq $parsed) { continue }
        if ($parsed.PackageIdentifier -ine $PackageIdentifier) { continue }

        $versionKey = Get-WingetSortableVersionKey -Version $parsed.Version
        if ([string]::IsNullOrWhiteSpace($versionKey) -or $versionKey -ge $newVersionKey) { continue }

        $selected.Add([PSCustomObject]@{
                Number  = $number
                Title   = "$($pr.title)"
                Version = $parsed.Version
                Reason  = "superseded by $PackageIdentifier $NewVersion"
            })
    }

    return @($selected)
}

function Select-WingetHygienePrActions {
    <#
    .SYNOPSIS
        Plans hygiene actions for this tool's own open upstream pull requests.

    .DESCRIPTION
        Pure decision logic for the scheduled PR hygiene sweep. For every
        parsable open PR of the bot it decides:
          - close-superseded: an open PR for the same package carries a newer
            version (ties are kept: equal versions are left for the duplicate
            detection in the submission path).
          - close-published: the PR's exact version is already published in
            winget-pkgs (the PR itself is open, so it was closed/rejected
            upstream or someone else shipped the version first).
          - keep: everything else, annotated with the PR's validation labels so
            the sweep summary can group attention-needing PRs.
        Unparsable titles are always kept untouched.

    .OUTPUTS
        Objects with Action (close-superseded | close-published | keep),
        Number, Title, PackageIdentifier, Version, Reason and Labels.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        # Objects with number, title and optionally labels (names or objects with a name property).
        [object[]] $OpenPrs,

        # Receives a package identifier, returns the published version strings
        # for that package (empty array when the package does not exist).
        # Optional: when omitted, the published check is skipped entirely.
        [Parameter()]
        [scriptblock] $PublishedVersionsResolver
    )

    $actions = [System.Collections.Generic.List[object]]::new()
    $parsedPrs = [System.Collections.Generic.List[object]]::new()

    foreach ($pr in $OpenPrs) {
        if ($null -eq $pr) { continue }

        $number = 0
        if (-not [int]::TryParse("$($pr.number)", [ref] $number) -or $number -le 0) { continue }

        $labels = @()
        $labelsProperty = $pr.PSObject.Properties['labels']
        if ($null -ne $labelsProperty -and $null -ne $labelsProperty.Value) {
            $labels = @($labelsProperty.Value | ForEach-Object {
                    if ($_ -is [string]) { $_ } else { [string]$_.name }
                } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        $parsed = Get-WingetPrTitlePackageVersion -Title "$($pr.title)"
        if ($null -eq $parsed) {
            $actions.Add([PSCustomObject]@{
                    Action            = 'keep'
                    Number            = $number
                    Title             = "$($pr.title)"
                    PackageIdentifier = $null
                    Version           = $null
                    Reason            = 'title not parsable; never touched'
                    Labels            = $labels
                })
            continue
        }

        $parsedPrs.Add([PSCustomObject]@{
                Number            = $number
                Title             = "$($pr.title)"
                PackageIdentifier = $parsed.PackageIdentifier
                Version           = $parsed.Version
                VersionKey        = Get-WingetSortableVersionKey -Version $parsed.Version
                Labels            = $labels
            })
    }

    $publishedCache = @{}

    foreach ($group in ($parsedPrs | Group-Object -Property { $_.PackageIdentifier.ToLowerInvariant() })) {
        # Newest version first; ties resolved toward the higher PR number so
        # exactly one PR per package survives the supersession pass.
        $ordered = @($group.Group | Sort-Object -Property @{ Expression = { $_.VersionKey } }, @{ Expression = { $_.Number } } -Descending)
        $newest = $ordered[0]

        foreach ($pr in $ordered) {
            if ($pr.Number -ne $newest.Number -and $pr.VersionKey -lt $newest.VersionKey) {
                $actions.Add([PSCustomObject]@{
                        Action            = 'close-superseded'
                        Number            = $pr.Number
                        Title             = $pr.Title
                        PackageIdentifier = $pr.PackageIdentifier
                        Version           = $pr.Version
                        Reason            = "superseded by open PR #$($newest.Number) ($($newest.PackageIdentifier) $($newest.Version))"
                        Labels            = $pr.Labels
                    })
                continue
            }

            $publishedMatch = $false
            if ($null -ne $PublishedVersionsResolver) {
                $cacheKey = $pr.PackageIdentifier.ToLowerInvariant()
                if (-not $publishedCache.ContainsKey($cacheKey)) {
                    $publishedCache[$cacheKey] = @(& $PublishedVersionsResolver $pr.PackageIdentifier)
                }
                $publishedMatch = @($publishedCache[$cacheKey]) -contains $pr.Version
            }

            if ($publishedMatch) {
                $actions.Add([PSCustomObject]@{
                        Action            = 'close-published'
                        Number            = $pr.Number
                        Title             = $pr.Title
                        PackageIdentifier = $pr.PackageIdentifier
                        Version           = $pr.Version
                        Reason            = "version $($pr.Version) is already published in winget-pkgs"
                        Labels            = $pr.Labels
                    })
            }
            else {
                $actions.Add([PSCustomObject]@{
                        Action            = 'keep'
                        Number            = $pr.Number
                        Title             = $pr.Title
                        PackageIdentifier = $pr.PackageIdentifier
                        Version           = $pr.Version
                        Reason            = 'open and current'
                        Labels            = $pr.Labels
                    })
            }
        }
    }

    return @($actions | Sort-Object -Property Number)
}
