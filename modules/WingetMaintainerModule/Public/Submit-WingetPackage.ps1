<#
.SYNOPSIS
    Submits a validated manifest as a Pull Request to winget-pkgs repository.

.DESCRIPTION
    Takes a pre-generated and validated manifest folder and submits it as a PR
    to the winget-pkgs repository using WinMatsch, Komac, WinGetCreate, or
    a server-side branch in a verified user-owned fork.
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
    The tool to use for submission: "WinMatsch" (default), "Komac",
    "WinGetCreate", or "ForkBranch". ForkBranch never synchronizes the
    fork's default branch.

    .PARAMETER SubmissionTarget
    ForkBranch is restricted to "Upstream". It creates the branch and manifest
    commit in the configured, topology-verified user-owned fork, then opens a
    pull request against microsoft/winget-pkgs. It never directly pushes or
    commits content to microsoft/winget-pkgs.

    .PARAMETER Repository
    The repository where existing pull requests are checked and, for
    ForkBranch, where the pull request is created. ForkBranch supports
    microsoft/winget-pkgs or the configured verified fork, allowing an
    explicitly scoped test-fork submission.

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
        [ValidateSet("WinMatsch", "Komac", "WinGetCreate", "ForkBranch")]
        [string] $With = "WinMatsch",

        [Parameter(Mandatory = $false)]
        [string] $Token,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3)]
        [int] $MaxBranchMovedRetries = 1,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Upstream', 'Fork')]
        [string] $SubmissionTarget = 'Upstream',

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository = 'microsoft/winget-pkgs'
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

        # Reject invalid ForkBranch configurations before contacting the
        # upstream read API.
        if ($With -eq 'ForkBranch') {
            if ($SubmissionTarget -ne 'Upstream') {
                return @{
                    Success  = $false
                    Error    = 'ForkBranch submissions are restricted to the Upstream target; manifest writes remain in the configured fork.'
                    PrUrl    = $null
                    PrNumber = $null
                }
            }
            $forkRepository = "$env:WINGET_PKGS_FORK_REPO".Trim()
            if ([string]::IsNullOrWhiteSpace($forkRepository)) {
                return @{
                    Success  = $false
                    Error    = 'WINGET_PKGS_FORK_REPO is required for ForkBranch submissions.'
                    PrUrl    = $null
                    PrNumber = $null
                }
            }

            Assert-SafeWingetPkgsForkRepository -ForkRepository $forkRepository
            if ($Repository -ine 'microsoft/winget-pkgs' -and $Repository -ine $forkRepository) {
                return @{
                    Success  = $false
                    Error    = "ForkBranch submissions can only target microsoft/winget-pkgs or the configured fork '$forkRepository'."
                    PrUrl    = $null
                    PrNumber = $null
                }
            }
        }

        # A durable upstream check protects all submitters; tool-specific
        # concurrency only serializes workers from this workflow.
        if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version -OnlyOpen -Repository $Repository) {
            $existingPrUrl = Get-WingetPkgsPrUrl -PackageId $PackageId -Version $Version -Repository $Repository
            $existingPrNumber = if ($existingPrUrl -match '/pull/(?<Number>\d+)$') {
                $Matches['Number']
            }
            else {
                $null
            }

            Write-Host "A matching open PR already exists in $Repository; skipping submission." -ForegroundColor Yellow
            return @{
                Success  = $true
                Error    = $null
                PrUrl    = $existingPrUrl
                PrNumber = $existingPrNumber
            }
        }

        # Generators can emit mixed line endings. Normalize only after validation
        # and immediately before any submitter or fork commit consumes the files.
        Normalize-WingetManifestLineEndings -ManifestPath $fullManifestPath
        $finalValidation = Test-WingetManifestContent -ManifestPath $fullManifestPath -SkipPublishedComparison
        if (-not $finalValidation.Valid) {
            return @{
                Success  = $false
                Error    = "Final submit validation failed after line-ending normalization. $($finalValidation.Errors -join ' ')"
                PrUrl    = $null
                PrNumber = $null
            }
        }
        $submitReadySnapshot = Get-SubmittedManifestSnapshot -ManifestPath $fullManifestPath

        switch ($With) {
            "WinMatsch" {
                # Ensure WinMatsch is installed
                Install-WinMatsch

                $maxAttempts = $MaxBranchMovedRetries + 1
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    # Recheck before each retry in case another worker created
                    # the PR after the universal preflight completed.
                    if (Test-ExistingPRs -PackageIdentifier $PackageId -Version $Version -OnlyOpen -Repository $Repository) {
                        $existingPrUrl = Get-WingetPkgsPrUrl -PackageId $PackageId -Version $Version -Repository $Repository
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
                # Prefer a PATH-installed wingetcreate; otherwise download it and pin
                # the absolute path so the call is independent of the working directory.
                $wingetCreateCommand = Get-Command 'wingetcreate.exe' -CommandType Application -ErrorAction SilentlyContinue
                if ($wingetCreateCommand) {
                    $wingetCreatePath = $wingetCreateCommand.Source
                }
                else {
                    Install-WingetCreate
                    $wingetCreatePath = (Resolve-Path -LiteralPath '.\wingetcreate.exe').Path
                }

                Write-Host "--> Running: wingetcreate submit" -ForegroundColor White

                $output = & $wingetCreatePath submit --prtitle $PrTitle -t $Token $fullManifestPath 2>&1
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

            "ForkBranch" {
                $forkSubmission = Invoke-ForkBranchSubmission `
                    -ManifestPath $fullManifestPath `
                    -PackageId $PackageId `
                    -Version $Version `
                    -PrTitle $PrTitle `
                    -Token $Token `
                    -ForkRepository $forkRepository `
                    -TargetRepository $Repository `
                    -Resolves $Resolves

                $postSubmitSnapshot = Get-SubmittedManifestSnapshot -ManifestPath $fullManifestPath
                if (($submitReadySnapshot | ConvertTo-Json -Compress -Depth 5) -ne ($postSubmitSnapshot | ConvertTo-Json -Compress -Depth 5)) {
                    return @{
                        Success  = $false
                        Error    = 'Manifest artifacts changed during submission. Treating the submit result as unsafe; inspect the local manifest directory before retrying.'
                        PrUrl    = $null
                        PrNumber = $null
                    }
                }

                if (-not $forkSubmission.Created) {
                    if (-not $forkSubmission.DuplicateDetected) {
                        return @{
                            Success  = $false
                            Error    = $forkSubmission.Error
                            PrUrl    = $null
                            PrNumber = $null
                        }
                    }

                    $existingPrUrl = Get-WingetPkgsPrUrl `
                        -PackageId $PackageId `
                        -Version $Version `
                        -Repository $Repository
                    $existingPrNumber = if ($existingPrUrl -match '/pull/(?<Number>\d+)$') {
                        $Matches['Number']
                    }
                    else {
                        $null
                    }

                    return @{
                        Success  = $true
                        Error    = $null
                        PrUrl    = $existingPrUrl
                        PrNumber = $existingPrNumber
                    }
                }

                $prUrl = "$($forkSubmission.PullRequest.html_url)".Trim()
                $prNumber = "$($forkSubmission.PullRequest.number)".Trim()
                return @{
                    Success  = $true
                    Error    = $null
                    PrUrl    = $prUrl
                    PrNumber = $prNumber
                }
            }
        }

        Write-Host ""
        Write-Host "PR submitted successfully!" -ForegroundColor Green

        $postSubmitSnapshot = Get-SubmittedManifestSnapshot -ManifestPath $fullManifestPath
        if (($submitReadySnapshot | ConvertTo-Json -Compress -Depth 5) -ne ($postSubmitSnapshot | ConvertTo-Json -Compress -Depth 5)) {
            return @{
                Success  = $false
                Error    = 'Manifest artifacts changed during submission. Treating the submit result as unsafe; inspect the local manifest directory before retrying.'
                PrUrl    = $null
                PrNumber = $null
            }
        }

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
