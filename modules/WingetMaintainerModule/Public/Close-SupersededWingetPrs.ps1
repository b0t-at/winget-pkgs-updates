function Close-SupersededWingetPrs {
    <#
    .SYNOPSIS
        Closes this tool's own older open upstream PRs after a newer version of
        the same package was submitted.

    .DESCRIPTION
        When version N+1 is submitted while the bot's version-N pull request is
        still open, the older PR can never merge and only costs moderator
        attention. This function searches the bot's open pull requests for the
        package, selects the strictly older ones via
        Select-WingetSupersededOpenPrs, and closes each with a short comment
        pointing at the successor.

        The operation is strictly best-effort and fail-open: any search or
        close failure is reported as a warning and never fails the caller,
        because the new PR - the thing that matters - already exists.

    .PARAMETER BotLogin
        The GitHub login whose PRs may be closed. Only PRs authored by this
        login are ever considered.

    .PARAMETER MaxCloses
        Upper bound of closes per invocation; a safety valve against runaway
        title parsing.

    .OUTPUTS
        PSCustomObject with ClosedPrNumbers, SkippedCount and Warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Version,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $BotLogin,

        [Parameter()]
        [int] $NewPrNumber = 0,

        [Parameter()]
        [string] $NewPrUrl,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository = 'microsoft/winget-pkgs',

        [Parameter()]
        [ValidateRange(1, 20)]
        [int] $MaxCloses = 5,

        # Injectable for tests: returns objects with number and title for the
        # bot's open PRs mentioning the package.
        [Parameter()]
        [scriptblock] $SearchInvoker,

        # Injectable for tests: receives ($Number, $Comment); performs the close.
        [Parameter()]
        [scriptblock] $CloseInvoker
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $closed = [System.Collections.Generic.List[int]]::new()

    if ($null -eq $SearchInvoker) {
        $SearchInvoker = {
            $query = "repo:$Repository is:pr is:open author:$BotLogin in:title `"$PackageId`""
            $raw = Invoke-GhCliWithRetry -OperationName "superseded-PR search for $PackageId" -ScriptBlock {
                gh api --paginate -X GET 'search/issues' -f q=$query --jq '[.items[] | {number: .number, title: .title}]'
            }
            $json = (@($raw) -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($json)) { return @() }
            # --paginate can emit one JSON array per page; normalize to objects.
            return @($json -split "(?<=\])\s*(?=\[)" | ForEach-Object { $_ | ConvertFrom-Json } | ForEach-Object { $_ })
        }
    }

    if ($null -eq $CloseInvoker) {
        $CloseInvoker = {
            param([int] $Number, [string] $Comment)
            Invoke-GhCliWithRetry -OperationName "close superseded PR #$Number" -ScriptBlock {
                gh pr close $Number --repo $Repository --comment $Comment
            } | Out-Null
        }
    }

    try {
        $openPrs = @(& $SearchInvoker)
    }
    catch {
        $warnings.Add("Superseded-PR search failed for ${PackageId}: $($_.Exception.Message)")
        return [PSCustomObject]@{
            ClosedPrNumbers = @()
            SkippedCount    = 0
            Warnings        = @($warnings)
        }
    }

    $candidates = @(Select-WingetSupersededOpenPrs `
            -OpenPrs $openPrs `
            -PackageIdentifier $PackageId `
            -NewVersion $Version `
            -NewPrNumber $NewPrNumber)

    $skipped = 0
    foreach ($candidate in $candidates) {
        if ($closed.Count -ge $MaxCloses) {
            $skipped++
            continue
        }

        $successor = if (-not [string]::IsNullOrWhiteSpace($NewPrUrl)) { $NewPrUrl } else { "$PackageId $Version" }
        $comment = "Superseded by $successor. Closing this older automated update to keep the review queue clean."
        try {
            & $CloseInvoker $candidate.Number $comment
            $closed.Add($candidate.Number)
            Write-Host "Closed superseded PR #$($candidate.Number) ($($candidate.Title))."
        }
        catch {
            $warnings.Add("Could not close superseded PR #$($candidate.Number): $($_.Exception.Message)")
        }
    }

    if ($skipped -gt 0) {
        $warnings.Add("Skipped $skipped superseded candidate(s) beyond the MaxCloses=$MaxCloses safety cap.")
    }

    return [PSCustomObject]@{
        ClosedPrNumbers = @($closed)
        SkippedCount    = $skipped
        Warnings        = @($warnings)
    }
}
