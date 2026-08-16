# Read the CSV file
$packages = Import-Csv ".\winget-finalurlchanged.csv"

# GitHub API function
function Get-GitHubReleaseAssets {
    param (
        [string]$Owner,
        [string]$Repo
    )
    
    try {
        # Set GitHub API headers - uncomment and add token if hitting rate limits
        $headers = @{
            "Accept" = "application/vnd.github.v3+json"
            # "Authorization" = "token YOUR_GITHUB_TOKEN"
        }
        
        # Get the latest release
        $apiUrl = "https://api.github.com/repos/${$Owner}/${$Repo}/releases/latest"
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get -ErrorAction Stop
        
        # Return the assets
        return $release.assets
    }
    catch {
        Write-Warning "Error getting releases for ${$Owner}/${$Repo}: $_"
        return $null
    }
}

# Process each package and add new URLs
foreach ($package in $packages) {
    Write-Host "Processing $($package.PackageId)..."
    
    # Get latest release assets
    $assets = Get-GitHubReleaseAssets -Owner $package.GitHubOwner -Repo $package.GitHubRepo
    
    if ($assets) {
        # Filter for installer file types
        $installerAssets = $assets | Where-Object { 
            $_.name -match '\.exe$|\.msi$|\.zip$|\.msix|\.msixbundle$' 
        }
        
        if ($installerAssets.Count -gt 0) {
            # Get details of the current URL
            $currentFileName = ($package.InstallerUrlInWinget -split '/')[-1]
            $currentFileType = [System.IO.Path]::GetExtension($currentFileName)
            
            # Try to find a matching asset based on file extension and name pattern
            $bestMatch = $null
            
            # First try exact file extension match with similar naming
            $sameExtension = $installerAssets | Where-Object { [System.IO.Path]::GetExtension($_.name) -eq $currentFileType }
            
            if ($sameExtension.Count -gt 0) {
                # Look for similar naming patterns (architecture, platform references)
                $architectureMatches = @("x64", "amd64", "x86_64", "64bit", "64-bit", "win64", "windows-x64")
                foreach ($pattern in $architectureMatches) {
                    if ($currentFileName -match $pattern) {
                        $matchingAsset = $sameExtension | Where-Object { $_.name -match $pattern } | Select-Object -First 1
                        if ($matchingAsset) {
                            $bestMatch = $matchingAsset
                            break
                        }
                    }
                }
                
                # If no matches found, just take the first asset with the same extension
                if (-not $bestMatch -and $sameExtension.Count -gt 0) {
                    $bestMatch = $sameExtension | Select-Object -First 1
                }
            }
            
            # If still no match, take the first installer asset
            if (-not $bestMatch -and $installerAssets.Count -gt 0) {
                $bestMatch = $installerAssets | Select-Object -First 1
            }
            
            # Add the URL to the package
            if ($bestMatch) {
                $package | Add-Member -MemberType NoteProperty -Name "NewInstallerUrl" -Value $bestMatch.browser_download_url -Force
                Write-Host "Found match: $($bestMatch.name)" -ForegroundColor Green
            }
            else {
                $package | Add-Member -MemberType NoteProperty -Name "NewInstallerUrl" -Value "No suitable asset found" -Force
                Write-Host "No suitable asset found" -ForegroundColor Yellow
            }
        }
        else {
            $package | Add-Member -MemberType NoteProperty -Name "NewInstallerUrl" -Value "No installer assets found" -Force
            Write-Host "No installer assets found" -ForegroundColor Yellow
        }
    }
    else {
        $package | Add-Member -MemberType NoteProperty -Name "NewInstallerUrl" -Value "Failed to get release assets" -Force
        Write-Host "Failed to get release assets" -ForegroundColor Red
    }
}

# Export the updated CSV
$packages | Export-Csv -Path ".\winget-finalurlchanged-updated.csv" -NoTypeInformation
Write-Host "Updated CSV exported to winget-finalurlchanged-updated.csv" -ForegroundColor Green