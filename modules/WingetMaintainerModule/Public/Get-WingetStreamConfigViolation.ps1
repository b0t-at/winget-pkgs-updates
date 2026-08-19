function Get-WingetStreamConfigViolation {
    <#
    .SYNOPSIS
        Validates monitored package entries against the stream-resolution rules.

    .DESCRIPTION
        A stream-versioned package ID must pin its version stream explicitly,
        otherwise the update pipeline would resolve the repo-global latest
        release and publish a wrong-stream version (the OpenJS.Electron.39 ->
        43.4.0 incident). The rules enforced here mirror the runtime guard in
        Get-LatestGHVersionTag:

          - NumericStream IDs (ending in ".<digits>") require a tagPattern.
          - ChannelSuffix IDs (.Beta/.Preview/.Nightly/.PreRelease) require a
            tagPattern or `pre-release: "true"` (an explicit prerelease-channel
            opt-in).

    .OUTPUTS
        One PSCustomObject per violating entry: PackageId, StreamKind, Message.
        An empty array means the configuration is valid.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]] $Packages,

        # Known-bad entries awaiting a separate fix; keep this list empty unless
        # a documented follow-up exists.
        [Parameter()]
        [string[]] $ExemptPackageIds = @()
    )

    $violations = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $Packages) {
        $packageId = Get-WingetPrecheckPackageField -Package $package -Name 'id'
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            continue
        }

        $streamKind = Get-WingetPackageIdStreamKind -PackageId $packageId
        if ($streamKind -eq 'None') {
            continue
        }
        if ($packageId -in $ExemptPackageIds) {
            continue
        }

        $tagPattern = Get-WingetPrecheckPackageField -Package $package -Name 'tagPattern'
        if (-not [string]::IsNullOrWhiteSpace($tagPattern)) {
            continue
        }

        $preReleaseValue = Get-WingetGraphQlFieldValue -InputObject $package -Name 'pre-release'
        $allowPrerelease = Test-WingetPreReleaseOptIn -Value $preReleaseValue
        if ($streamKind -eq 'ChannelSuffix' -and $allowPrerelease) {
            continue
        }

        $requirement = if ($streamKind -eq 'NumericStream') {
            "add a tagPattern that pins the stream (e.g. tagPattern: '^v39\.')"
        }
        else {
            "add a tagPattern or opt into the prerelease channel with pre-release: `"true`""
        }
        $violations.Add([PSCustomObject]@{
                PackageId  = $packageId
                StreamKind = $streamKind
                Message    = "Package '$packageId' looks stream-versioned ($streamKind) but has no tagPattern; the repo-global latest release would resolve the wrong stream. Fix: $requirement."
            })
    }

    return @($violations)
}
