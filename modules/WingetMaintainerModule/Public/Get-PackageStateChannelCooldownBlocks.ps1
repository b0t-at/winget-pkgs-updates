function Get-PackageStateChannelCooldownBlocks {
    <#
    .SYNOPSIS
        Reads channel-package cooldown blocks from package state.

    .DESCRIPTION
        Nightly/Beta/Canary identifiers publish daily and share the same
        Defender false-positive pattern, so every build costs a moderator
        review while almost none merge. A channel package whose last validation
        run (state entry lastUpdated) is younger than CooldownDays is therefore
        blocked from the update matrix - regardless of the verdict, because an
        open PR means "wait" and a fresh failure means "the next build will
        fail the same way". Returns package identifiers mapped to the block
        details; consumed by the update precheck.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $StateFilePath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 365)]
        [double] $CooldownDays = 3,

        [Parameter(Mandatory = $false)]
        [datetime] $Now = (Get-Date).ToUniversalTime()
    )

    $blocks = [ordered]@{}
    if ($CooldownDays -le 0) {
        return $blocks
    }

    $stateData = Get-PackageState -StateFilePath $StateFilePath
    if ($null -eq $stateData) {
        return $blocks
    }

    foreach ($packageId in @($stateData.Keys)) {
        if (-not (Test-WingetChannelPackageId -PackageId $packageId)) {
            continue
        }

        $entry = $stateData[$packageId]
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('lastUpdated')) {
            continue
        }

        $lastUpdated = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$entry['lastUpdated'], [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lastUpdated)) {
            continue
        }

        $ageDays = ($Now.ToUniversalTime() - $lastUpdated).TotalDays
        if ($ageDays -lt $CooldownDays) {
            $blocks[$packageId] = [ordered]@{
                lastUpdated  = $lastUpdated.ToString('o')
                lastVersion  = [string]$entry['version']
                lastState    = [string]$entry['state']
                ageDays      = [Math]::Round([Math]::Max(0, $ageDays), 2)
                cooldownDays = $CooldownDays
            }
        }
    }

    return $blocks
}
