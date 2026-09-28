function Remove-StaleWinMatschFeedback {
    <#
    .SYNOPSIS
        Prunes expired or superseded WinMatsch upstream-verdict feedback items.

    .DESCRIPTION
        Reviews top-level JSON feedback items in a WinMatsch feedback directory.
        Items are deleted when their recordedAt timestamp is older than the
        retention window, or when the associated microsoft/winget-pkgs pull
        request has merged. GitHub lookup failures are fail-safe and keep the
        item.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $FeedbackDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int] $RetentionDays = 30,

        [Parameter(Mandatory = $false)]
        [datetimeoffset] $Now = [datetimeoffset]::UtcNow,

        [Parameter(Mandatory = $false)]
        [string] $Repository = 'microsoft/winget-pkgs'
    )

    if (-not (Test-Path -LiteralPath $FeedbackDirectory -PathType Container)) {
        Write-Host "WinMatsch feedback directory does not exist; nothing to prune: $FeedbackDirectory"
        return @()
    }

    $cutoff = $Now.AddDays(-1 * $RetentionDays)
    $results = [System.Collections.Generic.List[object]]::new()
    $feedbackFiles = @(Get-ChildItem -LiteralPath $FeedbackDirectory -Filter '*.json' -File -ErrorAction SilentlyContinue)

    foreach ($file in $feedbackFiles) {
        $item = $null
        try {
            $item = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-Warning "Keeping WinMatsch feedback '$($file.Name)': invalid JSON ($($_.Exception.Message))."
            [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Kept'; Reason = 'InvalidJson' })
            continue
        }

        $recordedAtProperty = $item.PSObject.Properties['recordedAt']
        $recordedAt = $null
        if ($recordedAtProperty) {
            try {
                if ($recordedAtProperty.Value -is [datetimeoffset]) {
                    $recordedAt = $recordedAtProperty.Value
                }
                elseif ($recordedAtProperty.Value -is [datetime]) {
                    $recordedAt = [datetimeoffset]([datetime]$recordedAtProperty.Value)
                }
                else {
                    $recordedAt = [datetimeoffset]::Parse(
                        "$($recordedAtProperty.Value)",
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
                }
            }
            catch {
                $recordedAt = $null
            }
        }

        if ($null -ne $recordedAt) {
            if ($recordedAt -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Host "Pruned WinMatsch feedback '$($file.Name)': recordedAt $recordedAt is older than $RetentionDays days."
                [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Pruned'; Reason = 'Expired' })
                continue
            }
        }
        else {
            Write-Warning "Keeping WinMatsch feedback '$($file.Name)': missing or invalid recordedAt."
        }

        $pullRequestNumberProperty = $item.PSObject.Properties['pullRequestNumber']
        if (-not $pullRequestNumberProperty) {
            Write-Warning "Keeping WinMatsch feedback '$($file.Name)': missing pullRequestNumber."
            [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Kept'; Reason = 'MissingPullRequestNumber' })
            continue
        }

        $pullRequestNumber = "$($pullRequestNumberProperty.Value)"
        if ($pullRequestNumber -notmatch '^\d+$') {
            Write-Warning "Keeping WinMatsch feedback '$($file.Name)': missing pullRequestNumber."
            [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Kept'; Reason = 'MissingPullRequestNumber' })
            continue
        }

        try {
            $response = & gh api "repos/$Repository/pulls/$pullRequestNumber" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "gh api failed with exit code ${LASTEXITCODE}: $($response -join "`n")"
            }

            $pullRequest = ($response | Out-String) | ConvertFrom-Json -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace("$($pullRequest.merged_at)")) {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-Host "Pruned WinMatsch feedback '$($file.Name)': $Repository#$pullRequestNumber merged at $($pullRequest.merged_at)."
                [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Pruned'; Reason = 'Merged'; PullRequestNumber = $pullRequestNumber })
                continue
            }

            Write-Host "Keeping WinMatsch feedback '$($file.Name)': $Repository#$pullRequestNumber is not merged."
            [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Kept'; Reason = 'Open'; PullRequestNumber = $pullRequestNumber })
        }
        catch {
            Write-Warning "Keeping WinMatsch feedback '$($file.Name)': could not read $Repository#$pullRequestNumber ($($_.Exception.Message))."
            [void]$results.Add([pscustomobject]@{ File = $file.Name; Action = 'Kept'; Reason = 'LookupFailed'; PullRequestNumber = $pullRequestNumber })
        }
    }

    return $results
}
