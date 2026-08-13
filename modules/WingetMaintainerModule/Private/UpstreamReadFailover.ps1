<#
.SYNOPSIS
    Shared credential-tier helpers for public upstream winget-pkgs reads.

.DESCRIPTION
    Upstream duplicate and base-ref reads authenticate with the credential in
    WINGET_UPSTREAM_READ_TOKEN first (workflows pass the classic public-read
    WINGET_PAT there, 5,000 core requests/hour). When GitHub rejects that
    credential with an authorization or rate-limit status, the read retries
    once with WINGET_UPSTREAM_READ_FALLBACK_TOKEN (the probed Actions token or
    an optional WINGET_PUBLIC_READ_TOKEN) and finally falls back to anonymous
    public access. These helpers only shape upstream read requests; fork
    writes and the cross-repository PR creation never use them.
#>

function Get-WingetPkgsUpstreamReadCredentialTiers {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $tiers = [System.Collections.Generic.List[object]]::new()

    $primaryToken = "$env:WINGET_UPSTREAM_READ_TOKEN".Trim()
    if (-not [string]::IsNullOrWhiteSpace($primaryToken)) {
        $tiers.Add([pscustomobject]@{
            Token = $primaryToken
            Label = 'the primary upstream read token'
        })
    }

    $fallbackToken = "$env:WINGET_UPSTREAM_READ_FALLBACK_TOKEN".Trim()
    if (-not [string]::IsNullOrWhiteSpace($fallbackToken) -and $fallbackToken -cne $primaryToken) {
        $tiers.Add([pscustomobject]@{
            Token = $fallbackToken
            Label = 'the fallback upstream read token'
        })
    }

    $tiers.Add([pscustomobject]@{
        Token = $null
        Label = 'anonymous public access'
    })

    return $tiers
}

function Get-WingetPkgsGitHubApiFailureStatusCode {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    if ($null -ne $exception -and
        $null -ne $exception.PSObject.Properties['Response'] -and
        $null -ne $exception.Response) {
        return [int] $exception.Response.StatusCode
    }

    return 0
}

function Get-WingetPkgsUpstreamReadFailureStatusCode {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    return Get-WingetPkgsGitHubApiFailureStatusCode -ErrorRecord $ErrorRecord
}

function Get-WingetPkgsGitHubApiFailureResponseBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        return $ErrorRecord.ErrorDetails.Message
    }

    $exception = $ErrorRecord.Exception
    if ($null -eq $exception -or
        $null -eq $exception.PSObject.Properties['Response'] -or
        $null -eq $exception.Response) {
        return $null
    }
    $response = $exception.Response

    if ($null -ne $response.PSObject.Properties['Content'] -and $null -ne $response.Content) {
        try {
            return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch {
            return $null
        }
    }

    if ($null -ne $response.PSObject.Methods['GetResponseStream']) {
        try {
            $stream = $response.GetResponseStream()
        }
        catch {
            return $null
        }
        if ($null -ne $stream) {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                return $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }
        }
    }

    return $null
}

function Test-WingetPkgsUpstreamReadFailoverStatus {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $StatusCode
    )

    # 403/429 signal rate limiting; 401/404 defensively cover credential
    # anomalies such as the transient upstream 404s previously observed for
    # scoped tokens. Anything else is a real error and must surface.
    return $StatusCode -in 401, 403, 404, 429
}
