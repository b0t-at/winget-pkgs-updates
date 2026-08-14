function Test-PackageStateOpenPrFresh {
    <#
    .SYNOPSIS
        Tests whether the state file holds a fresh cached open-PR marker for a package version.

    .DESCRIPTION
        Returns $true only when the package's state entry carries an "openPr" object whose
        version matches the pending version and whose checkedAt timestamp is within the TTL.
        Any missing, mismatched, unparsable, or expired marker returns $false so the caller
        falls back to a live PR search.

    .PARAMETER StateFilePath
        Path to the package-state.json file.

    .PARAMETER PackageIdentifier
        The winget package identifier (e.g., "MongoDB.Server").

    .PARAMETER Version
        The pending version to compare against the cached marker.

    .PARAMETER TtlHours
        Maximum age of the cached marker in hours. Defaults to 24.

    .PARAMETER Now
        Reference time for the age calculation. Defaults to UTC now; injectable for tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true)]
        [string] $Version,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 8760)]
        [int] $TtlHours = 24,

        [Parameter(Mandatory = $false)]
        [datetime] $Now = (Get-Date).ToUniversalTime()
    )

    $entry = Get-PackageState -StateFilePath $StateFilePath -PackageIdentifier $PackageIdentifier
    if ($null -eq $entry -or -not $entry.ContainsKey('openPr')) {
        return $false
    }

    $openPr = $entry['openPr']
    if ($null -eq $openPr -or $openPr['version'] -ne $Version) {
        return $false
    }

    $checkedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$openPr['checkedAt'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$checkedAt)) {
        return $false
    }

    $ageHours = ($Now.ToUniversalTime() - $checkedAt).TotalHours
    return $ageHours -le $TtlHours
}
