function Get-PackageState {
    <#
    .SYNOPSIS
        Reads package validation state from the state file.

    .PARAMETER StateFilePath
        Path to the package-state.json file.

    .PARAMETER PackageIdentifier
        Optional package identifier to retrieve. If omitted, returns all entries.

    .OUTPUTS
        The state entry for the specified package, or a hashtable of all entries.
        Returns $null if the file or entry doesn't exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $false)]
        [string] $PackageIdentifier
    )

    if (-not (Test-Path -Path $StateFilePath -PathType Leaf)) {
        return $null
    }

    $stateData = Get-Content -Path $StateFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($PackageIdentifier)) {
        return $stateData
    }

    if ($stateData.ContainsKey($PackageIdentifier)) {
        return $stateData[$PackageIdentifier]
    }

    return $null
}
