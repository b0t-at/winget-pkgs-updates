function Set-PackageStateOpenPr {
    <#
    .SYNOPSIS
        Records or clears the cached open-PR marker for a package in the state file.

    .DESCRIPTION
        Stores a nested "openPr" object ({ version, checkedAt }) on the package's state
        entry so the pre-matrix update check can skip packages that already have an open
        upstream PR for the pending version. Creates a minimal entry when the package has
        no state yet and preserves all other fields on existing entries.

        With -Clear, removes the openPr marker (and the entry itself when nothing else
        remains). Clearing is a no-op that leaves the file untouched when no marker exists.

    .PARAMETER StateFilePath
        Path to the package-state.json file.

    .PARAMETER PackageIdentifier
        The winget package identifier (e.g., "MongoDB.Server").

    .PARAMETER Version
        The pending version an open upstream PR was found for.

    .PARAMETER CheckedAt
        UTC timestamp of the PR check. Defaults to now; injectable for tests.

    .PARAMETER Clear
        Removes the cached open-PR marker instead of setting it.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Set')]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [string] $PackageIdentifier,

        [Parameter(Mandatory = $true, ParameterSetName = 'Set')]
        [string] $Version,

        [Parameter(Mandatory = $false, ParameterSetName = 'Set')]
        [datetime] $CheckedAt = (Get-Date).ToUniversalTime(),

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch] $Clear
    )

    $stateData = @{}
    if (Test-Path -Path $StateFilePath -PathType Leaf) {
        $stateData = Get-Content -Path $StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }

    if ($Clear) {
        if (-not $stateData.ContainsKey($PackageIdentifier)) {
            return
        }
        $entry = $stateData[$PackageIdentifier]
        if (-not $entry.ContainsKey('openPr')) {
            return
        }
        $entry.Remove('openPr')
        if ($entry.Count -eq 0) {
            $stateData.Remove($PackageIdentifier)
        }
    }
    else {
        $entry = if ($stateData.ContainsKey($PackageIdentifier)) { $stateData[$PackageIdentifier] } else { @{} }
        $entry['openPr'] = @{
            version   = $Version
            checkedAt = $CheckedAt.ToUniversalTime().ToString('o')
        }
        $stateData[$PackageIdentifier] = $entry
    }

    $directory = Split-Path -Path $StateFilePath -Parent
    if (-not (Test-Path -Path $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $stateData | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFilePath -Encoding utf8 -Force
}
