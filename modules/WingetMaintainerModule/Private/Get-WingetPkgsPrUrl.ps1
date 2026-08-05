<#
.SYNOPSIS
    Resolves the winget-pkgs pull request URL for a package that was just submitted.

.DESCRIPTION
    WinMatsch, Komac and WinGetCreate all print the created pull request URL to
    stdout on success, but each uses a different wording. This helper first scans
    the captured tool output for a GitHub pull request URL. If none is found (for
    example because the tool changed its output format or the URL was swallowed by
    ANSI formatting), it falls back to querying GitHub for the most recently opened
    pull request whose title matches the package and version.

.PARAMETER SubmitOutput
    The captured stdout/stderr of the submission tool.

.PARAMETER PackageId
    The package identifier, used by the GitHub CLI fallback lookup.

.PARAMETER Version
    The package version, used by the GitHub CLI fallback lookup.

.OUTPUTS
    System.String - the pull request URL, or $null when it could not be determined.
#>
function Get-WingetPkgsPrUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $SubmitOutput,

        [Parameter(Mandatory = $false)]
        [string] $PackageId,

        [Parameter(Mandatory = $false)]
        [string] $Version,

        [Parameter(Mandatory = $false)]
        [string] $Repository = 'microsoft/winget-pkgs'
    )

    # Preferred source: the submission tool printed the URL itself.
    if ($null -ne $SubmitOutput) {
        $outputText = ($SubmitOutput | Out-String)
        $urlMatches = [regex]::Matches(
            $outputText,
            'https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+'
        )

        if ($urlMatches.Count -gt 0) {
            # The newly created PR is the last one mentioned; earlier hits are
            # typically references to related/duplicate pull requests.
            $prUrl = $urlMatches[$urlMatches.Count - 1].Value
            Write-Verbose "Resolved PR URL from submission output: $prUrl"
            return $prUrl
        }
    }

    Write-Verbose "No PR URL found in submission output, falling back to GitHub CLI lookup."

    if ([string]::IsNullOrWhiteSpace($PackageId) -or [string]::IsNullOrWhiteSpace($Version)) {
        return $null
    }

    if (-not (Get-Command -Name gh -ErrorAction SilentlyContinue)) {
        Write-Verbose "GitHub CLI not available, cannot resolve PR URL."
        return $null
    }

    try {
        $json = gh pr list `
            --search "$PackageId $Version in:title" `
            --state 'open' `
            --limit 10 `
            --json 'url,createdAt' `
            --repo $Repository 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        $pullRequests = @($json | ConvertFrom-Json)
        if ($pullRequests.Count -eq 0) {
            return $null
        }

        $newest = $pullRequests |
            Sort-Object -Property { [datetime] $_.createdAt } -Descending |
            Select-Object -First 1

        Write-Verbose "Resolved PR URL via GitHub CLI: $($newest.url)"
        return $newest.url
    }
    catch {
        Write-Verbose "Could not resolve PR URL via GitHub CLI: $($_.Exception.Message)"
        return $null
    }
}
