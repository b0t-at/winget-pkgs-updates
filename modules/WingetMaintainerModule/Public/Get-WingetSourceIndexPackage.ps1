function Get-WingetSourceIndexPackage {
    <#
    .SYNOPSIS
        Returns every package published in the WinGet community source, with the
        version WinGet currently considers latest.

    .DESCRIPTION
        Reads the official `source2.msix` index database instead of enumerating
        the `microsoft/winget-pkgs` manifest tree. The download is a few
        megabytes and the result is authoritative: `latest_version` is the value
        WinGet itself resolves for `winget upgrade`, so no version sorting
        heuristics are needed on our side.

        The extracted database is cached; a HEAD request decides whether the
        cached copy is still current.

    .PARAMETER PackageIdentifier
        Optional filter. Supports wildcards and is matched case-insensitively.

    .PARAMETER CachePath
        Directory used for the downloaded MSIX and the extracted database.
        Defaults to a `winget-source-index` folder under the user's temp path.

    .PARAMETER Force
        Re-downloads the source package even when the cached copy looks current.

    .OUTPUTS
        PSCustomObject with PackageIdentifier, PackageName, Moniker and
        WingetVersion.

    .EXAMPLE
        Get-WingetSourceIndexPackage -PackageIdentifier 'Gyan.FFmpeg.*'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)] [string] $PackageIdentifier,
        [Parameter()] [string] $CachePath,
        [Parameter()] [switch] $Force
    )

    $databasePath = Get-WingetSourceIndexDatabasePath -CachePath $CachePath -Force:$Force

    $rows = Invoke-WingetSourceIndexQuery `
        -DatabasePath $databasePath `
        -Query 'SELECT id, name, moniker, latest_version FROM packages ORDER BY id'

    foreach ($row in $rows) {
        if (-not [string]::IsNullOrWhiteSpace($PackageIdentifier) -and $row.id -notlike $PackageIdentifier) {
            continue
        }

        [PSCustomObject]@{
            PackageIdentifier = $row.id
            PackageName       = $row.name
            Moniker           = $row.moniker
            WingetVersion     = $row.latest_version
        }
    }
}
