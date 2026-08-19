function Get-WingetPackageIdStreamKind {
    <#
    .SYNOPSIS
        Classifies a winget package identifier as stream-versioned or not.

    .DESCRIPTION
        Stream-versioned identifiers pin the package to something other than the
        repository's newest stable release, so resolving them from the
        repo-global "latest" release is always wrong:

          - NumericStream: the ID ends in ".<digits>" (e.g. OpenJS.Electron.39
            tracks the 39.x line). Requires a tagPattern.
          - ChannelSuffix: the ID ends in ".Beta", ".Preview", ".Nightly",
            ".PreRelease" or ".Pre-release" (case-insensitive). Requires a
            tagPattern or an explicit pre-release opt-in.
          - None: a plain identifier that follows the latest stable release.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PackageId
    )

    if ($PackageId -match '\.\d+$') {
        return 'NumericStream'
    }
    if ($PackageId -match '\.(Beta|Preview|Nightly|Pre-?Release)$') {
        return 'ChannelSuffix'
    }
    return 'None'
}
