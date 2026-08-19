function Get-WingetReleaseLookbackWindow {
    <#
    .SYNOPSIS
        Returns the shared number of recent GitHub releases scanned for version resolution.

    .DESCRIPTION
        Both the full update job (Get-LatestGHVersionTag, gh release list --limit)
        and the batched update precheck (Select-GitHubPackagesNeedingUpdate,
        GraphQL releases(first: ...)) must scan the same window of recent
        releases. A smaller window in either place makes a tagPattern stream
        silently fall out of scope once enough newer releases stack on top of it
        (the OpenJS.Electron.33-.40 failure mode with the old 30-release
        gh default). 100 is the GraphQL per-page maximum.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()

    return 100
}
