function Get-PackageStateConfigHealthBlocks {
    <#
    .SYNOPSIS
        Reads definitive Config Health blocks from package state.

    .DESCRIPTION
        Returns package identifiers whose latest Config Health result is a
        definitive GitHub release-asset failure. These markers are consumed by
        the update precheck before packages enter the generation matrix.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath
    )

    $stateData = Get-PackageState -StateFilePath $StateFilePath
    $blocks = [ordered]@{}
    if ($null -eq $stateData) {
        return $blocks
    }

    foreach ($packageId in @($stateData.Keys)) {
        $entry = $stateData[$packageId]
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw "Package state entry '$packageId' must be an object."
        }
        if (-not $entry.Contains('configHealth')) {
            continue
        }

        $health = $entry['configHealth']
        if ($null -eq $health) {
            continue
        }
        if ($health -isnot [System.Collections.IDictionary]) {
            throw "Config Health state for '$packageId' must be an object."
        }

        $status = [string]$health['status']
        if ($status -in @('AssetMissing', 'RepoMissing')) {
            $blocks[$packageId] = $health
        }
    }

    return $blocks
}
