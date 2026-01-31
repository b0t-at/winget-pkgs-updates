<#
.SYNOPSIS
    Sends a notification to a self-hosted ntfy server.

.DESCRIPTION
    Sends a push notification through an ntfy server endpoint. Supports custom topics,
    priorities, tags, and message formatting. Used to notify about package update
    workflow failures.

.PARAMETER NtfyUrl
    The base URL of the ntfy server (e.g., "https://ntfy.example.com").

.PARAMETER Topic
    The ntfy topic to publish to.

.PARAMETER Title
    The notification title.

.PARAMETER Message
    The notification message body.

.PARAMETER Priority
    The notification priority (1-5, where 5 is urgent). Default is 3 (default).

.PARAMETER Tags
    Array of emoji tags for the notification (e.g., @("warning", "package")).

.PARAMETER Click
    Optional URL to open when notification is clicked.

.PARAMETER Actions
    Optional array of action buttons (hashtables with 'action', 'label', 'url' keys).

.EXAMPLE
    Send-NtfyNotification -NtfyUrl "https://ntfy.example.com" -Topic "winget-updates" `
        -Title "Package Update Failed" -Message "Fork.Fork failed sandbox validation" `
        -Priority 4 -Tags @("x", "package")

.EXAMPLE
    $params = @{
        NtfyUrl = $env:NTFY_URL
        Topic   = "winget-updates"
        Title   = "Validation Failed"
        Message = "Package: $PackageId`nVersion: $Version`nError: Sandbox test failed"
        Tags    = @("warning")
        Click   = "https://github.com/owner/repo/actions/runs/12345"
    }
    Send-NtfyNotification @params

.NOTES
    For ntfy documentation, see: https://docs.ntfy.sh/
#>

function Send-NtfyNotification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $NtfyUrl,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Topic,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 5)]
        [int] $Priority = 3,

        [Parameter(Mandatory = $false)]
        [string[]] $Tags = @(),

        [Parameter(Mandatory = $false)]
        [string] $Click,

        [Parameter(Mandatory = $false)]
        [hashtable[]] $Actions
    )

    # Normalize URL (remove trailing slash)
    $NtfyUrl = $NtfyUrl.TrimEnd('/')

    # Build the endpoint URL
    $endpoint = "$NtfyUrl/$Topic"

    # Build the request body
    $body = @{
        topic    = $Topic
        title    = $Title
        message  = $Message
        priority = $Priority
    }

    # Add optional fields
    if ($Tags.Count -gt 0) {
        $body.tags = $Tags
    }

    if (-not [string]::IsNullOrWhiteSpace($Click)) {
        $body.click = $Click
    }

    if ($Actions -and $Actions.Count -gt 0) {
        $body.actions = $Actions
    }

    # Convert to JSON
    $jsonBody = $body | ConvertTo-Json -Depth 4

    Write-Verbose "Sending notification to: $endpoint"
    Write-Verbose "Payload: $jsonBody"

    try {
        $response = Invoke-RestMethod -Uri $endpoint `
            -Method Post `
            -ContentType 'application/json' `
            -Body $jsonBody `
            -ErrorAction Stop

        Write-Host "Notification sent successfully to topic '$Topic'" -ForegroundColor Green
        Write-Verbose "Response: $($response | ConvertTo-Json -Compress)"

        return @{
            Success  = $true
            Response = $response
            Error    = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Warning "Failed to send notification: $errorMessage"

        return @{
            Success  = $false
            Response = $null
            Error    = $errorMessage
        }
    }
}

# Export the function when loaded as a module
Export-ModuleMember -Function Send-NtfyNotification
