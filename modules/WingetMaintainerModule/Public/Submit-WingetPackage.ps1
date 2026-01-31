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
    The tool to use for submission: "Komac" (default) or "WinGetCreate".

.PARAMETER Token
    GitHub Personal Access Token with repo scope. If not provided, uses
    GITHUB_TOKEN or WINGET_PAT environment variables.

.EXAMPLE
    Submit-WingetPackage -ManifestPath "./manifests/f/Fork/Fork/1.85.0" `
        -PackageId "Fork.Fork" -Version "1.85.0"

.EXAMPLE
    Submit-WingetPackage -ManifestPath $manifestPath -PackageId $pkgId `
        -Version $ver -Resolves "12345" -PrTitle "Update Fork.Fork to 1.85.0"

.OUTPUTS
    PSCustomObject with properties:
    - Success: Boolean indicating if PR was created
    - PrUrl: URL to the created PR (if successful)
    - Error: Error message (if failed)
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
        [ValidateSet("Komac", "WinGetCreate")]
        [string] $With = "Komac",

        [Parameter(Mandatory = $false)]
        [string] $Token
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
            Success = $false
            PrUrl   = $null
            Error   = "No GitHub token provided. Set GITHUB_TOKEN or WINGET_PAT environment variable."
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
        switch ($With) {
            "Komac" {
                # Ensure Komac is installed
                Install-Komac

                # Build komac submit command arguments
                $komacArgs = @(
                    "submit"
                    $fullManifestPath
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
                        Success = $false
                        PrUrl   = $null
                        Error   = "Komac submit failed with exit code $exitCode. Output: $output"
                    }
                }

                # Try to extract PR URL from output
                $prUrl = $null
                if ($output -match 'https://github\.com/microsoft/winget-pkgs/pull/\d+') {
                    $prUrl = $Matches[0]
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
                        Success = $false
                        PrUrl   = $null
                        Error   = "WinGetCreate submit failed with exit code $exitCode. Output: $output"
                    }
                }

                # Try to extract PR URL from output
                $prUrl = $null
                if ($output -match 'https://github\.com/microsoft/winget-pkgs/pull/\d+') {
                    $prUrl = $Matches[0]
                }
            }
        }

        Write-Host ""
        Write-Host "PR submitted successfully!" -ForegroundColor Green
        if ($prUrl) {
            Write-Host "PR URL: $prUrl" -ForegroundColor Cyan
        }

        # Output PR URL for GitHub Actions
        if ($env:GITHUB_OUTPUT) {
            "pr-url=$prUrl" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        }

        return @{
            Success = $true
            PrUrl   = $prUrl
            Error   = $null
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "ERROR: $errorMessage" -ForegroundColor Red

        return @{
            Success = $false
            PrUrl   = $null
            Error   = $errorMessage
        }
    }
}

# Export the function when loaded as a module
Export-ModuleMember -Function Submit-WingetPackage
