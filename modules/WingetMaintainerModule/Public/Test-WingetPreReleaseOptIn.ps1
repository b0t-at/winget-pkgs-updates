function Test-WingetPreReleaseOptIn {
    <#
    .SYNOPSIS
        Normalizes the monitored configuration's `pre-release` value to a boolean.

    .DESCRIPTION
        The `pre-release` key travels from github-releases-monitored.yml through
        the generated packages.json into the workflow matrix, so it may arrive as
        a boolean or as the strings "true"/"1"/"yes" (any casing). Anything else
        (including $null and empty strings) means "stable releases only".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool]) {
        return $Value
    }
    return ("$Value").Trim() -in @('true', '1', 'yes')
}
