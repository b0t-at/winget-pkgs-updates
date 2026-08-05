<#
.SYNOPSIS
    Submits a validated manifest as a Pull Request to winget-pkgs repository.

.DESCRIPTION
    Takes a pre-generated and validated manifest folder and submits it as a PR
    to the winget-pkgs repository using either Komac or WinGetCreate.
    This function should only be called after manifest validation and sandbox
    testing have passed.

.PARAMETER ManifestPath
    Path to the manifest folder containing the YAML files to submit.

.PARAMETER PackageId
    The package identifier (e.g., "Microsoft.VSCode").

.PARAMETER Version
    The package version being submitted.

.PARAMETER PrTitle
    Optional custom PR title. If not provided, uses default format.

.PARAMETER Resolves
    Optional GitHub issue number that this PR resolves.

.PARAMETER With
    The tool to use for submission: "WinMatsch" (default), "Komac" or "WinGetCreate".

.PARAMETER Token
    GitHub Personal Access Token with repo scope. If not provided, uses
    GITHUB_TOKEN or WINGET_PAT environment variables.

.PARAMETER MaxBranchMovedRetries
    Maximum retries after WinMatsch reports its safe GH2020 branch-moved
    conflict. Each retry runs a fresh WinMatsch validation/submission attempt.

.EXAMPLE
    Submit-WingetPackage -ManifestPath "./manifests/f/Fork/Fork/1.85.0" `
        -PackageId "Fork.Fork" -Version "1.85.0"

.EXAMPLE
    Submit-WingetPackage -ManifestPath $manifestPath -PackageId $pkgId `
        -Version $ver -Resolves "12345" -PrTitle "Update Fork.Fork to 1.85.0"

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if PR was created
    - Error: Error message (if failed)
    - PrUrl: URL of the created pull request ($null if it could not be determined)
    - PrNumber: Number of the created pull request ($null if it could not be determined)
#>

function Submit-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({
            if (-not (Test-Path -Path $_ -PathType Container)) {
                throw "Manifest path '$_' does not exist or is not a directory."
            }
            return $true
        })]
        [string] $ManifestPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $PackageId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Version,

        [Parameter(Mandatory = $false)]
        [string] $PrTitle,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^\d+$')]
        [string] $Resolves,

        [Parameter(Mandatory = $false)]
        [ValidateSet("WinMatsch", "Komac", "WinGetCreate")]
        [string] $With = "WinMatsch",

        [Parameter(Mandatory = $false)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3)]
        [int] $MaxBranchMovedRetries = 1
    )

    # Get GitHub token
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = $env:GITHUB_TOKEN
        if ([string]::IsNullOrWhiteSpace($Token)) {
            $Token = $env:WINGET_PAT
        }
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return @{
            Success  = $false
            Error    = "No GitHub token provided. Set GITHUB_TOKEN or WINGET_PAT environment variable."
            PrUrl    = $null
            PrNumber = $null
        }
    }

    # Set default PR title
    if ([string]::IsNullOrWhiteSpace($PrTitle)) {
        $PrTitle = "Update version: $PackageId version $Version"
    }

    # Resolve the full manifest path
    $fullManifestPath = (Resolve-Path -Path $ManifestPath).Path

    Write-Host "=== Submitting Package ===" -ForegroundColor Cyan
    Write-Host "Package:  $PackageId" -ForegroundColor Gray
    Write-Host "Version:  $Version" -ForegroundColor Gray
    Write-Host "Path:     $fullManifestPath" -ForegroundColor Gray
    Write-Host "Tool:     $With" -ForegroundColor Gray
    Write-Host ""

    try {
        $winmatschResult = $null

        switch ($With) {
            "WinMatsch" {
                # Ensure WinMatsch is installed
                Install-WinMatsch

                $maxAttempts = $MaxBranchMovedRetries + 1
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    # This is a read-only check against microsoft/winget-pkgs.
                    # WinMatsch remains the only component that creates the PR.
                    if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version) {
                        $existingPrUrl = Get-WingetPkgsPrUrl -PackageId $PackageId -Version $Version
                        $existingPrNumber = if ($existingPrUrl -match '/pull/(?<Number>\d+)$') {
                            $Matches['Number']
                        }
                        else {
                            $null
                        }

                        Write-Host 'A matching winget-pkgs PR already exists; skipping submission.' -ForegroundColor Yellow
                        return @{
                            Success  = $true
                            Error    = $null
                            PrUrl    = $existingPrUrl
                            PrNumber = $existingPrNumber
                        }
                    }

                    $attemptResult = Invoke-WinMatschSubmitAttempt `
                        -ManifestPath $fullManifestPath `
                        -PrTitle $PrTitle `
                        -Token $Token `
                        -Resolves $Resolves
                    $output = $attemptResult.Output
                    $exitCode = $attemptResult.ExitCode
                    $winmatschResult = $attemptResult.Result

                    if ($exitCode -eq 0) {
                        break
                    }

                    $reportedError = $attemptResult.Error
                    if (-not $reportedError) { $reportedError = "Output: $output" }

                    if ((Test-WinMatschBranchMovedRetryable -Attempt $attemptResult) -and $attempt -lt $maxAttempts) {
                        Write-Warning "WinMatsch validated branch moved before PR creation (GH2020); retrying fresh validation ($($attempt + 1) of $maxAttempts)."
                        continue
                    }

                    return @{
                        Success  = $false
                        Error    = "WinMatsch submit failed with exit code $exitCode after $attempt attempt(s). $reportedError"
                        PrUrl    = $null
                        PrNumber = $null
                    }
                }
            }

            "Komac" {
                # Ensure Komac is installed
                Install-Komac

                # Build komac submit command arguments
                $komacArgs = @(
                    "submit"
                    $fullManifestPath
                    "--yes"
                    "--token", $Token
                )

                # Add resolves if provided
                if (-not [string]::IsNullOrWhiteSpace($Resolves)) {
                    $komacArgs += "--resolves"
                    $komacArgs += $Resolves
                }

                Write-Host "--> Running: komac $($komacArgs -replace $Token, '***' -join ' ')" -ForegroundColor White
                
                $output = & komac @komacArgs 2>&1
                $exitCode = $LASTEXITCODE

                Write-Host $output

                if ($exitCode -ne 0) {
                    return @{
                        Success  = $false
                        Error    = "Komac submit failed with exit code $exitCode. Output: $output"
                        PrUrl    = $null
                        PrNumber = $null
                    }
                }
            }

            "WinGetCreate" {
                # Ensure WinGetCreate is installed
                Install-WingetCreate

                Write-Host "--> Running: wingetcreate submit" -ForegroundColor White

                $output = & .\wingetcreate.exe submit --prtitle $PrTitle -t $Token $fullManifestPath 2>&1
                $exitCode = $LASTEXITCODE

                Write-Host $output

                if ($exitCode -ne 0) {
                    return @{
                        Success  = $false
                        Error    = "WinGetCreate submit failed with exit code $exitCode. Output: $output"
                        PrUrl    = $null
                        PrNumber = $null
                    }
                }
            }
        }

        Write-Host ""
        Write-Host "PR submitted successfully!" -ForegroundColor Green

        # Prefer the structured result; fall back to scraping the console output.
        $prUrl = $null
        $prNumber = $null

        if ($winmatschResult -and $winmatschResult.pullRequest) {
            $prUrl = "$($winmatschResult.pullRequest.url)".Trim()
            $prNumber = "$($winmatschResult.pullRequest.number)".Trim()
            if ($prUrl) { Write-Verbose "PR URL taken from WinMatsch --result-json." }
        }

        if ([string]::IsNullOrWhiteSpace($prUrl)) {
            $prUrl = Get-WingetPkgsPrUrl -SubmitOutput $output -PackageId $PackageId -Version $Version
            $prNumber = $null
        }

        if ($prUrl) {
            if ([string]::IsNullOrWhiteSpace($prNumber) -and $prUrl -match '/pull/(?<Number>\d+)$') {
                $prNumber = $Matches['Number']
            }
            Write-Host "PR URL:   $prUrl" -ForegroundColor Cyan
        }
        else {
            Write-Warning "PR was created but its URL could not be determined."
        }

        return @{
            Success  = $true
            Error    = $null
            PrUrl    = $prUrl
            PrNumber = $prNumber
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red

        return @{
            Success  = $false
            Error    = $errorMessage
            PrUrl    = $null
            PrNumber = $null
        }
    }
}

# Export the function when loaded as a module
Export-ModuleMember -Function Submit-WingetPackage
