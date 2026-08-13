# manifest_updater.ps1

#Requires -Module powershell-yaml # Or ensure it's installed: Install-Module powershell-yaml -Scope CurrentUser

# --- Configuration ---
# IMPORTANT: Adjust the path to your local clone of the winget-pkgs repository!
$Global:WINGET_PKGS_REPO_PATH = "Q:\winget-pkgs" # Example path, please adjust

# --- Helper Functions ---

function Download-FileContent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Url
    )
    process {
        Write-Host "      Attempting download from: $Url"
        try {
            # Headers to mimic a browser, can help with some servers
            $headers = @{
                'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
            }
            # Invoke-WebRequest to get raw bytes
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -Headers $headers #-MaximumRedirection 0 # Allow redirects handled manually if needed or trust default
            
            # Check if it's a redirect (GitHub often redirects releases/download/...)
            # if ($response.StatusCode -in (301, 302, 303, 307, 308)) {
            #     [URI]$redirectUrl = $response.Headers.Location[0]
            #     Write-Host "      Redirected to: $redirectUrl"
            #     $response = Invoke-WebRequest -Uri $redirectUrl.AbsoluteUri -UseBasicParsing -TimeoutSec 60 -Headers $headers
            # }

            if ($response.StatusCode -ne 200) {
                throw "Failed to download file. Status code: $($response.StatusCode)"
            }
            
            $fileData = $response.Content # Raw byte array
            Write-Host "      Download successful: $($fileData.Length) Bytes from $Url"
            if ($fileData -match "<!DOCTYPE html>*") {
                write-host "      WARNING: Downloaded content appears to be HTML, not a file. This may indicate a problem with the URL or server response."    
                break
            }
            Start-Sleep -Milliseconds 500 # Brief pause to avoid overwhelming servers
            return $fileData
        }
        catch {
            Write-Error "      Error downloading from $($Url): $($_.Exception.Message)"
            throw # Re-throw the exception
        }
    }
}

function Calculate-SHA256 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )
    process {
        try {
            $tempFile = New-TemporaryFile
            [System.IO.File]::WriteAllBytes($tempFile.FullName, $Data)
            $hash = (Get-FileHash -Path $tempFile.FullName -Algorithm SHA256).Hash.ToLower()
            Remove-Item $tempFile.FullName -Force
            return $hash
        }
        catch {
            Write-Error "Error calculating SHA256: $($_.Exception.Message)"
            throw
        }
    }
}

function Load-Yaml {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    process {
        try {
            Import-Module powershell-yaml -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch {
            Write-Error "Module 'powershell-yaml' is required. Please install it using: Install-Module powershell-yaml -Scope CurrentUser"
            throw "Module 'powershell-yaml' not found."
        }
        Get-Content $FilePath -Raw | ConvertFrom-Yaml
    }
}

function Replace-SHA256 {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $Data, # Can be PSCustomObject or Hashtable
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )
    process {
        try {
            Import-Module powershell-yaml -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch {
            Write-Error "Module 'powershell-yaml' is required. Please install it using: Install-Module powershell-yaml -Scope CurrentUser"
            throw "Module 'powershell-yaml' not found."
        }
        $ManifestFileContent = Get-Content -Path $FilePath -Raw
        # ConvertTo-Yaml by default might not have the desired depth or formatting for complex manifests.
        # if hashes installerSHA256 dies not match NewSHA256, then replace it
        if ($Data.Installers) {
            foreach ($installer in $Data.Installers) {
                if ($installer.InstallerSha256 -ne $installer.NewSha256) {
                    $ManifestFileContent = $ManifestFileContent.replace($installer.InstallerSha256, $installer.NewSha256)
                    Write-Host "   Replacing SHA256 in manifest file: $FilePath"
                    Write-Host "   Old SHA256: $($installer.InstallerSha256)"
                    Write-Host "   New SHA256: $($installer.NewSha256)"
                }
            }
        }

        $ManifestFileContent | Out-File -FilePath $FilePath -Encoding utf8
    }
}

function Get-PackageManifestFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageIdentifier,
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )
    process {
        if (-not $PackageIdentifier -or -not $RepoPath -or -not (Test-Path $RepoPath -PathType Container)) {
            Write-Warning "    [Get-PackageManifestFiles] Invalid PackageIdentifier ('$PackageIdentifier') or Repo Path ('$RepoPath')."
            return @()
        }

        $parts = $PackageIdentifier.Split('.')
        if ($parts.Length -lt 2) {
            Write-Warning "    [Get-PackageManifestFiles] Invalid PackageIdentifier format: $PackageIdentifier"
            return @()
        }

        # Construct the path to the package directory
        # e.g., manifests/b/beeyev/telegram-owl/
        $packageDir = Join-Path -Path $RepoPath -ChildPath "manifests"
        $packageDir = Join-Path -Path $packageDir -ChildPath $PackageIdentifier[0].ToString().ToLower()
        foreach ($part in $parts) {
            $packageDir = Join-Path -Path $packageDir -ChildPath $part
        }
        
        if (-not (Test-Path $packageDir -PathType Container)) {
            # Write-Warning "    [Get-PackageManifestFiles] Package directory not found: $packageDir"
            return @()
        }

        # Search for *.installer.yaml files recursively within the package directory
        # The filename must exactly match PackageIdentifier.installer.yaml
        $foundFiles = Get-ChildItem -Path $packageDir -Recurse -Filter "$($PackageIdentifier).installer.yaml" | ForEach-Object { $_.FullName }
        
        $validManifests = [System.Collections.Generic.List[string]]::new()
        foreach ($manifestFile in $foundFiles) {
            try {
                $data = Load-Yaml -FilePath $manifestFile
                if ($data.PackageIdentifier -eq $PackageIdentifier -and $data.ManifestType.ToLower() -eq "installer") {
                    $validManifests.Add((Resolve-Path $manifestFile).Path)
                }
            }
            catch {
                # Write-Warning "    [Get-PackageManifestFiles] Error processing $manifestFile: $($_.Exception.Message), skipping."
            }
        }
        # Write-Host "    [Get-PackageManifestFiles] Found installer manifests for $PackageIdentifier: $($validManifests -join ', ')"
        return $validManifests | Select-Object -Unique
    }
}


function Create-GitHubPRPlaceholder {
    [CmdletBinding()]
    param (
        [string]$ManifestPath,
        [string]$PackageId,
        [string]$PackageVersion,
        [string]$Reason = "Hash Update"
    )
    process {
        Write-Host "  ACTION REQUIRED: Create GitHub PR for $PackageId v$PackageVersion ($Reason)" -ForegroundColor Yellow
        Write-Host "    Manifest: $ManifestPath"
        $existingPR = Test-ExistingPRs -Version $PackageVersion -PackageIdentifier $PackageId -onlyOpen
        if ($existingPR) {
            Write-Host "  Existing PR found for $PackageId $PackageVersion. No action needed." -ForegroundColor Green
            return
        }
        $commitMessage = "Update Hash for $PackageId $PackageVersion"
        $prTitle = "update Hash for $PackageId $PackageVersion"
        $prBody = "Updated installer hash for $PackageId $PackageVersion due to mismatch."
        Write-Host "    Commit message suggestion: $commitMessage"
        Write-Host "    PR title suggestion: $prTitle"
        Write-Host "    PR body suggestion: $prBody"
        #Write-Host "    >>>> INSERT YOUR PR CREATION CODE HERE <<<<" -ForegroundColor Cyan
        Write-Host "  No existing PR found for $PackageId $PackageVersion. Proceeding with PR creation." -ForegroundColor Green
        Import-Module (Join-Path $PSScriptRoot '..\modules\WingetMaintainerModule\WingetMaintainerModule.psd1') -Force
        $submission = Submit-WingetPackage `
            -ManifestPath (Split-Path -Parent $ManifestPath) `
            -PackageId $PackageId `
            -Version $PackageVersion `
            -PrTitle $prTitle `
            -Token $gitToken `
            -With WinGetCreate
        if (-not $submission.Success) {
            throw "WinGetCreate submission failed: $($submission.Error)"
        }
    }
}

# Function to call our custom scripts to (maybe) detect the version from the installer
function Call-OtherScriptPlaceholder {
    [CmdletBinding()]
    param (
        [string]$PackageId,
        [string]$PackageVersion,
        [string]$Architecture,
        [string]$Url,
        [string]$ManifestSha,
        [string]$ActualSha
    )
    process {
        Write-Host "  ACTION REQUIRED: Call external script for $PackageId v$PackageVersion ($Architecture)" -ForegroundColor Yellow
        Write-Host "    URL: $Url"
        Write-Host "    Manifest Hash: $ManifestSha"
        Write-Host "    Actual Hash: $ActualSha"
        Write-Host "    Reason: Hash Mismatch on Vanity URL (latest version)."
        Write-Host "    >>>> INSERT YOUR EXTERNAL SCRIPT CALL HERE <<<<" -ForegroundColor Cyan
    }
}

function Process-Manifest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$ManifestObject
    )
    process {
        $ManifestFilePath = Join-Path -Path $Global:WINGET_PKGS_REPO_PATH -ChildPath $ManifestObject.FilePath
        Write-Host "Processing Manifest: $ManifestFilePath"
        if (-not (Test-Path $ManifestFilePath -PathType Leaf)) {
            Write-Error "ERROR: Manifest file not found: $ManifestFilePath"
            return
        }

        try {
            $manifestData = Load-Yaml -FilePath $ManifestFilePath
        }
        catch {
            Write-Error "Error loading manifest $($ManifestFilePath): $($_.Exception.Message)"
            return
        }

        $packageId = $manifestData.PackageIdentifier
        $currentPkgVersionStr = $manifestData.PackageVersion
        $installers = $manifestData.Installers

        $existingPR = Test-ExistingPRs -Version $currentPkgVersionStr -PackageIdentifier $packageId -onlyOpen
        if ($existingPR) {
            Write-Host "  Existing PR found for $PackageId $PackageVersion. No action needed." -ForegroundColor Green
            return
        }
        
        if (-not $installers) {
            # Some manifests (e.g., locale) don't have an Installers section
            Write-Host "No Installers section found in manifest $ManifestFilePath. Skipping."
            return
        }
        
        $manifestUpdatedOverall = $false

        for ($i = 0; $i -lt $installers.Count; $i++) {
            $installerEntry = $installers[$i]
            $installerUrl = $installerEntry.InstallerUrl
            $manifestSha256 = if ($null -ne $installerEntry.InstallerSha256) { [string]$installerEntry.InstallerSha256 } else { "" }
            $manifestSha256 = $manifestSha256.ToLower() # Ensure it's a string
            $architecture = if ($null -ne $installerEntry.Architecture) { $installerEntry.Architecture } else { "neutral" }


            if (-not $installerUrl) {
                Write-Warning "  Skipping Installer entry $i for $architecture (Package: $packageId v$currentPkgVersionStr) due to missing InstallerUrl."
                continue
            }

            Write-Host "`n  Checking Installer for: $packageId v$currentPkgVersionStr ($architecture)"
            Write-Host "    URL: $installerUrl"
            if ([string]::IsNullOrEmpty($manifestSha256)) {
                Write-Host "    Manifest SHA256: Not present"
            }
            else {
                Write-Host "    Manifest SHA256: $manifestSha256"
            }

            # Check if the version is in the URL.
            # Important: currentPkgVersionStr could be "Unknown" or other non-standard values.
            $isDirectLink = $false
            if ($currentPkgVersionStr -and $currentPkgVersionStr.ToLower() -ne "unknown" -and ($installerUrl.Contains($currentPkgVersionStr) -or $installerUrl.Contains($currentPkgVersionStr.trim(".0")) -or $installerUrl.Contains($currentPkgVersionStr.trim(".0.0")))) {
                $isDirectLink = $true
                if ($ManifestObject.IsDirectLink -ne $isDirectLink) { $ManifestObject | Add-Member -MemberType NoteProperty -Name "IsDirectLink" -Value $true }
            }

            if ($isDirectLink) {
                #if ($false) {
                Write-Host "    Type: Direct Link (Version found in URL)"
                try {
                    $fileContentBytes = Download-FileContent -Url $installerUrl
                    $actualSha256 = Calculate-SHA256 -Data $fileContentBytes
                    Write-Host "    Calculated SHA256: $actualSha256"

                    if ($manifestSha256 -ne $actualSha256) {
                        Write-Warning "    SHA256 MISMATCH! Updating manifest."
                        $manifestData.Installers[$i].NewSha256 = $actualSha256.ToUpper()
                        $manifestUpdatedOverall = $true
                        Write-Host "    SUCCESS: Hash for $packageId v$currentPkgVersionStr ($architecture) updated in manifest data." -ForegroundColor Green
                    }
                    else {
                        Write-Host "    SHA256 MATCH. No changes needed for this installer."
                    }
                }
                catch {
                    Write-Error "    Error processing direct link $($installerUrl): $($_.Exception.Message)"
                }
            }
            else {
                # Potential Vanity URL
                Write-Host "    Type: Potential Vanity URL (Version not in URL or PackageVersion is 'Unknown')"
                #return # Early exit if potential vanity URL URL - This function will be implemented later™️
                
                $allPackageManifestFiles = Get-PackageManifestFiles -PackageIdentifier $packageId -RepoPath $Global:WINGET_PKGS_REPO_PATH
                
                $versionsUsingThisUrlInfo = [System.Collections.Generic.List[PSCustomObject]]::new()
                foreach ($otherManifestFilePath in $allPackageManifestFiles) {
                    try {
                        $otherManifestContent = Load-Yaml -FilePath $otherManifestFilePath
                        $otherVersionStr = $otherManifestContent.PackageVersion
                        
                        if (-not $otherVersionStr -or -not $otherManifestFilePath) { continue }

                        foreach ($otherInstEntry in $otherManifestContent.Installers) {
                            if ($otherInstEntry.InstallerUrl -eq $installerUrl) {
                                # Ensure each version is added only once
                                if (-not ($versionsUsingThisUrlInfo | Where-Object { $_.version -eq $otherVersionStr })) {
                                    $versionsUsingThisUrlInfo.Add([PSCustomObject]@{
                                            version             = $otherVersionStr
                                            path                = (Resolve-Path $otherManifestFilePath).Path
                                            isCurrentProcessing = ((Resolve-Path $otherManifestFilePath).Path -eq (Resolve-Path $ManifestFilePath).Path)
                                        })
                                }
                                break # URL found in this other manifest
                            }
                        }
                    }
                    catch {
                        Write-Warning "      Warning: Could not check other manifest $($otherManifestFilePath): $($_.Exception.Message)"
                    }
                }
                
                # Ensure current manifest is in the list if it wasn't picked up or to mark it correctly
                $currentInList = $versionsUsingThisUrlInfo | Where-Object { $_.version -eq $currentPkgVersionStr -and $_.path -eq (Resolve-Path $ManifestFilePath).Path }
                if (-not $currentInList -and $currentPkgVersionStr) {
                    $versionsUsingThisUrlInfo.Add([PSCustomObject]@{
                            version             = $currentPkgVersionStr
                            path                = (Resolve-Path $ManifestFilePath).Path
                            isCurrentProcessing = $true
                        })
                }


                # Filter out invalid versions (e.g., "Unknown") before sorting
                $validVersionsInfo = $versionsUsingThisUrlInfo | Where-Object { $_.version -and $_.version.ToLower() -ne "unknown" }
                
                # Sort by version (semantic versioning)
                $sortedVersionsInfo = $validVersionsInfo | Sort-Object -Property @{Expression = { try { [System.Version]$_.version } catch { Write-Warning "Could not parse version '$($_.version)' for sorting."; return ([System.Version]"0.0") } } }
                
                if ($sortedVersionsInfo.Count -gt 1) {
                    # URL is shared by multiple valid versions
                    
                    Write-Host "    Vanity URL $installerUrl is used by multiple versions: $($sortedVersionsInfo.version -join ', ')"
                    
                    $latestVersionInfoWithUrl = $sortedVersionsInfo[-1]

                    # Is the currently processed manifest the latest one using this URL?
                    if ($latestVersionInfoWithUrl.version -eq $currentPkgVersionStr -and `
                            $latestVersionInfoWithUrl.path -eq (Resolve-Path $ManifestFilePath).Path) {
                        Write-Host "    Current version $currentPkgVersionStr is the LATEST using this vanity URL."
                        try {
                            $fileContentBytes = Download-FileContent -Url $installerUrl
                            $actualSha256 = Calculate-SHA256 -Data $fileContentBytes
                            Write-Host "    Calculated SHA256 for vanity URL (latest version): $actualSha256"

                            # try to find Version from downloaded installer file
                            $FileversionFromFile = Get-ProductVersionFromFile $installerUrl -VersionInfoProperty "FileVersion"
                            $ProductVersionFromFile = Get-ProductVersionFromFile $installerUrl -VersionInfoProperty "ProductVersion"

                            if ($FileversionFromFile -ne $currentPkgVersionStr -and $ProductVersionFromFile -ne $currentPkgVersionStr) {
                                Write-Warning "    WARNING: Version from file ($versionFromFile) does not match current version ($currentPkgVersionStr). Terminating."
                                return
                            }
                            else {
                                Write-Host "    Version from file matches current version: $currentPkgVersionStr"
                            }

                            if ($manifestSha256 -ne $actualSha256) {
                                Write-Warning "    SHA256 MISMATCH on vanity URL (latest version)!"
                                $manifestData.Installers[$i].NewSha256 = $actualSha256.ToUpper()
                                $manifestUpdatedOverall = $true
                                Write-Host "    SUCCESS: Hash for $packageId v$currentPkgVersionStr ($architecture) updated in manifest data." -ForegroundColor Green

                            }
                            else {
                                Write-Host "    SHA256 MATCH on vanity URL (latest version). No changes needed."
                            }
                        }
                        catch {
                            Write-Error "    Error processing vanity URL $installerUrl for current (latest) version: $($_.Exception.Message)"
                        }
                    }
                    else {
                        # Current manifest is an older version using a vanity URL
                        Write-Warning "    Current version $currentPkgVersionStr uses a vanity URL but is NOT the latest."
                        Write-Warning "    Latest version using this URL ($installerUrl) is $($latestVersionInfoWithUrl.version) (in $($latestVersionInfoWithUrl.path))."
                        Write-Warning "    Manifest $ManifestFilePath (Version $currentPkgVersionStr) should potentially be removed or updated to a version-specific link."
                        $existingPR = Test-ExistingPRs -Version $currentPkgVersionStr -PackageIdentifier $packageId -onlyOpen
                        if ($existingPR) {
                            Write-Host "  Existing PR found for $PackageId $PackageVersion. No action needed." -ForegroundColor Green
                            return
                        }
                        komac remove $packageId --version $currentPkgVersionStr --resolves $ManifestObject.IssueId --reason "Newer Version with same URL available in winget" --submit
                        # No hash change or PR here as the manifest is considered "outdated" for this URL.
                        return
                    }
                }
                else {
                    # URL is not shared, or this is the only (valid) version. Treat as direct link for this version.
                    Write-Host "    URL $installerUrl appears unique to this version or no other versions share it. Treating as direct link for this version."
                    try {
                        $fileContentBytes = Download-FileContent -Url $installerUrl
                        $actualSha256 = Calculate-SHA256 -Data $fileContentBytes
                        Write-Host "    Calculated SHA256: $actualSha256"

                        # try to find Version from downloaded installer file
                        $FileversionFromFile = Get-ProductVersionFromFile $installerUrl -VersionInfoProperty "FileVersion" -ErrorAction SilentlyContinue
                        $ProductVersionFromFile = Get-ProductVersionFromFile $installerUrl -VersionInfoProperty "ProductVersion" -ErrorAction SilentlyContinue

                        if ($FileversionFromFile -ne $currentPkgVersionStr -and $ProductVersionFromFile -ne $currentPkgVersionStr) {
                            Write-Warning "    WARNING: Version from file ($FileversionFromFile or $ProductVersionFromFile) does not match current version ($currentPkgVersionStr). Terminating."
                            return
                        }

                        if ($manifestSha256 -ne $actualSha256) {
                            Write-Warning "    SHA256 MISMATCH on vanity URL (latest version)!"
                            $manifestData.Installers[$i].NewSha256 = $actualSha256.ToUpper()
                            $manifestUpdatedOverall = $true
                            Write-Host "    SUCCESS: Hash for $packageId v$currentPkgVersionStr ($architecture) updated in manifest data." -ForegroundColor Green

                        }
                        else {
                            Write-Host "    SHA256 MATCH on vanity URL (latest version). No changes needed."
                        }
                    }
                    catch {
                        Write-Error "    Error processing unique non-versioned link $($installerUrl): $($_.Exception.Message)"
                    }
                }
            }
        } # End for each installer

        if ($manifestUpdatedOverall) {
            try {
                # Save the updated manifest back to the original file
                Replace-SHA256 -Data $manifestData -FilePath $ManifestFilePath
                Write-Host "`nManifest $ManifestFilePath has been updated locally." -ForegroundColor Green
                switch ($isDirectLink) {
                    $true { $PRReason = "Direct Link Hash Update" }
                    $false { $PRReason = "Vanity URL Hash Update" }
                    Default { $PRReason = "Hash Update" }
                }
                Create-GitHubPRPlaceholder -ManifestPath $ManifestFilePath -PackageId $packageId -PackageVersion $currentPkgVersionStr -Reason $PRReason

            }
            catch {
                Write-Error "Error saving updated manifest $($ManifestFilePath): $($_.Exception.Message)"
            }
        }
        else {
            Write-Host "`nNo changes made to manifest $ManifestFilePath."
        }
    } # End process block of Process-Manifest
}

# --- Main Execution (Example) ---
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    Write-Host "--- manifest_updater.ps1 ---"
    # IMPORTANT: Set WINGET_PKGS_REPO_PATH correctly at the top of the script!
    if (-not (Test-Path $Global:WINGET_PKGS_REPO_PATH -PathType Container)) {
        Write-Error "ERROR: WINGET_PKGS_REPO_PATH '$($Global:WINGET_PKGS_REPO_PATH)' is not a valid directory."
        Write-Error "Please configure the path at the top of the script."
    }
    else {
        # Example: Path to a manifest you want to check
        # Adjust this path to an existing manifest in your local clone.
        # e.g., manifests/m/Microsoft/PowerToys/0.80.0/Microsoft.PowerToys.installer.yaml
        #$testManifestRelPath = "manifests/c/ChemTableSoftware/FilesInspector/4.05/ChemTableSoftware.FilesInspector.installer.yaml"

        foreach ($hashmissmatch in $HashIssues) {
            # Provide a path to a manifest you want to test:
            # To test the script, uncomment the following line and set a valid path:
            if ($hashmissmatch.isInPR -eq $false) { Process-Manifest -ManifestObject $hashmissmatch }
            
        }

        foreach ($hashmissmatch in $HashIssuesWithoutInPr) {
            # Provide a path to a manifest you want to test:
            # To test the script, uncomment the following line and set a valid path:
            if ($hashmissmatch.isInPR -eq $false -and $hashmissmatch.PackageId -ne "LSoftTechnologies.ActiveLiveCD") { Process-Manifest -ManifestObject $hashmissmatch }
            
        }


        # # Provide a path to a manifest you want to test:
        # $manifestToTest = Join-Path -Path $Global:WINGET_PKGS_REPO_PATH -ChildPath $testManifestRelPath
        
        # # To test the script, uncomment the following line and set a valid path:
        # Process-Manifest -ManifestFilePath $manifestToTest
        
        Write-Host "`nScript is ready. Please uncomment the Process-Manifest call in the main execution block and provide a valid manifest path to test it."
        Write-Host "Ensure WINGET_PKGS_REPO_PATH ('$($Global:WINGET_PKGS_REPO_PATH)') is correct and the 'powershell-yaml' module is installed."

        # Example for testing a fictional vanity URL scenario:
        # 1. Create dummy files in your WINGET_PKGS_REPO_PATH:
        #    - manifests/f/Foo/Bar/1.0.0/Foo.Bar.installer.yaml (URL: https://example.com/latest.exe, SHA_OLD)
        #    - manifests/f/Foo/Bar/1.1.0/Foo.Bar.installer.yaml (URL: https://example.com/latest.exe, SHA_NEW_SERVER)
        # 2. Call Process-Manifest for the 1.0.0 version.
        # 3. Call Process-Manifest for the 1.1.0 version.
        # (Ensure https://example.com/latest.exe is actually reachable or mock the Download-FileContent function)
    }
}
