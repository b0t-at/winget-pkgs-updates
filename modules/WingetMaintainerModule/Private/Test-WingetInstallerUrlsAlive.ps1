function Test-WingetInstallerUrlsAlive {
    <#
    .SYNOPSIS
        Verifies that every InstallerUrl in a manifest set still resolves before submission.

    .DESCRIPTION
        Installer downloads happen at generation time; sandbox validation can run
        much later, and publishers occasionally delete or re-cut release assets in
        between. Submitting such a manifest produces an upstream
        URL-Validation-Error pull request that only a human can clean up.

        This preflight probes every InstallerUrl with an HTTP HEAD request
        (falling back to a single-byte ranged GET when HEAD is rejected) and
        classifies the outcome:
          - 2xx/3xx: alive.
          - 404/410: definitively dead - the submission must be blocked.
          - Anything else (401/403/405/429/5xx, network errors): inconclusive.
            The check fails open with a warning so a CDN quirk or transient
            outage can never block an otherwise valid submission; upstream
            validation remains the authority for those cases.

    .OUTPUTS
        PSCustomObject with properties:
        - Valid: $false only when at least one URL is definitively dead.
        - DeadUrls: URLs that returned HTTP 404 or 410.
        - Warnings: human-readable notes for inconclusive probes.
        - CheckedCount: number of unique URLs probed.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Urls')]
        [AllowEmptyCollection()]
        [string[]] $InstallerUrls,

        # Injectable for tests: receives ($Url, $Method), returns the final
        # integer HTTP status code after redirects. Throw for transport errors.
        [Parameter()]
        [scriptblock] $HttpProbe,

        [Parameter()]
        [ValidateRange(1, 5)]
        [int] $MaxAttempts = 3,

        [Parameter()]
        [scriptblock] $Sleep = { param([int]$Seconds) Start-Sleep -Seconds $Seconds }
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $installerManifest = Get-ChildItem -Path $ManifestPath -Filter '*.installer.yaml' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $installerManifest) {
            return [PSCustomObject]@{
                Valid        = $true
                DeadUrls     = @()
                Warnings     = @("No installer manifest found under '$ManifestPath'; skipping the installer URL preflight.")
                CheckedCount = 0
            }
        }

        $InstallerUrls = @(Get-InstallerManifestEntries -Path $installerManifest.FullName |
                ForEach-Object { $_.InstallerUrl })
    }

    if ($null -eq $HttpProbe) {
        $HttpProbe = {
            param([string] $Url, [string] $Method)

            $parameters = @{
                Uri                = $Url
                Method             = $Method
                MaximumRedirection = 10
                TimeoutSec         = 30
                SkipHttpErrorCheck = $true
                UseBasicParsing    = $true
                ErrorAction        = 'Stop'
                Headers            = @{ 'User-Agent' = 'winget-pkgs-updates' }
            }
            if ($Method -eq 'Get') {
                # A ranged GET keeps the fallback cheap on servers that reject HEAD.
                $parameters.Headers['Range'] = 'bytes=0-0'
            }

            $response = Invoke-WebRequest @parameters
            return [int]$response.StatusCode
        }
    }

    $deadUrls = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $uniqueUrls = @($InstallerUrls | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    foreach ($url in $uniqueUrls) {
        $classification = $null

        for ($attempt = 1; $attempt -le $MaxAttempts -and $null -eq $classification; $attempt++) {
            $statusCode = $null
            $probeError = $null
            try {
                $statusCode = [int](& $HttpProbe $url 'Head')
                # Some servers reject HEAD outright; retry once with a ranged GET.
                if ($statusCode -in 400, 403, 405, 501) {
                    $statusCode = [int](& $HttpProbe $url 'Get')
                }
            }
            catch {
                $probeError = $_.Exception.Message
            }

            if ($null -ne $statusCode -and $statusCode -ge 200 -and $statusCode -lt 400) {
                $classification = 'alive'
            }
            elseif ($statusCode -in 404, 410) {
                $classification = 'dead'
                $deadUrls.Add($url)
            }
            elseif ($attempt -lt $MaxAttempts) {
                & $Sleep ($attempt * 2)
            }
            else {
                $detail = if ($probeError) { "probe failed: $probeError" } else { "HTTP $statusCode" }
                $warnings.Add("Installer URL preflight was inconclusive for $url ($detail); continuing because only HTTP 404/410 block submission.")
                $classification = 'inconclusive'
            }
        }
    }

    return [PSCustomObject]@{
        Valid        = $deadUrls.Count -eq 0
        DeadUrls     = @($deadUrls)
        Warnings     = @($warnings)
        CheckedCount = $uniqueUrls.Count
    }
}
