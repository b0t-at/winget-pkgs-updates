function Update-PackageStateConfigHealth {
    <#
    .SYNOPSIS
        Synchronizes definitive Config Health findings into package state.

    .DESCRIPTION
        Stores a nested configHealth marker for AssetMissing and RepoMissing
        results. A later non-blocking result clears that marker, allowing a
        recovered package back into the update matrix. Existing validation and
        open-PR state is preserved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Results,

        [Parameter()]
        [datetime] $CheckedAt = (Get-Date).ToUniversalTime()
    )

    function Get-ConfigHealthResultField {
        param(
            [Parameter(Mandatory = $true)] $Result,
            [Parameter(Mandatory = $true)] [string] $Name
        )

        if ($Result -is [System.Collections.IDictionary]) {
            return $Result[$Name]
        }

        $property = $Result.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }
        return $property.Value
    }

    $stateData = @{}
    if (Test-Path -Path $StateFilePath -PathType Leaf) {
        $stateData = Get-Content -Path $StateFilePath -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }

    $blocked = 0
    $updated = 0
    $cleared = 0
    $changed = $false
    $checkedAtText = $CheckedAt.ToUniversalTime().ToString('o')

    foreach ($result in $Results) {
        $packageId = [string](Get-ConfigHealthResultField -Result $result -Name 'PackageId')
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            continue
        }

        $status = [string](Get-ConfigHealthResultField -Result $result -Name 'Status')
        $shouldBlock = $status -in @('AssetMissing', 'RepoMissing')
        $entryExists = $stateData.ContainsKey($packageId)
        $entry = if ($entryExists) { $stateData[$packageId] } else { @{} }
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw "Package state entry '$packageId' must be an object."
        }

        if ($shouldBlock) {
            $blocked++
            $detail = [string](Get-ConfigHealthResultField -Result $result -Name 'Detail')
            $tag = [string](Get-ConfigHealthResultField -Result $result -Name 'Tag')
            $existingHealth = if ($entry.Contains('configHealth')) { $entry['configHealth'] } else { $null }
            if ($null -ne $existingHealth -and $existingHealth -isnot [System.Collections.IDictionary]) {
                throw "Config Health state for '$packageId' must be an object."
            }

            $isUnchanged = $null -ne $existingHealth -and
                [string]$existingHealth['status'] -eq $status -and
                [string]$existingHealth['detail'] -eq $detail -and
                [string]$existingHealth['tag'] -eq $tag
            if ($isUnchanged) {
                continue
            }

            $entry['configHealth'] = [ordered]@{
                status    = $status
                detail    = $detail
                tag       = $tag
                checkedAt = $checkedAtText
            }
            $stateData[$packageId] = $entry
            $updated++
            $changed = $true
            continue
        }

        if ($entry.Contains('configHealth')) {
            $entry.Remove('configHealth')
            if ($entry.Count -eq 0) {
                $stateData.Remove($packageId)
            }
            else {
                $stateData[$packageId] = $entry
            }
            $cleared++
            $changed = $true
        }
    }

    if ($changed) {
        $directory = Split-Path -Path $StateFilePath -Parent
        if (-not (Test-Path -Path $directory -PathType Container)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }
        $stateData | ConvertTo-Json -Depth 10 | Set-Content -Path $StateFilePath -Encoding utf8 -Force
    }

    return [PSCustomObject]@{
        Blocked = $blocked
        Updated = $updated
        Cleared = $cleared
        Changed = $changed
    }
}
