function Get-GHReleaseNotes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $false)][string]$Version
    )

    # Get the release notes for a specific version or the latest release
    if ($Version) {
        $releaseNotes = Invoke-GhCliWithRetry -OperationName "gh release view $Version notes for $Repo" -ScriptBlock {
            gh release view "$Version" --repo $Repo --json "body"
        } | ConvertFrom-Json | Select-Object -ExpandProperty body
    } else {
        $releaseNotes = Invoke-GhCliWithRetry -OperationName "gh release view notes for $Repo" -ScriptBlock {
            gh release view --repo $Repo --json "body"
        } | ConvertFrom-Json | Select-Object -ExpandProperty body
    }

    return $releaseNotes
}