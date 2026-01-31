function Update-WingetPackage {
    <#
    .SYNOPSIS
        Generates a winget package manifest for a new version.

    .DESCRIPTION
        Fetches the latest version information and generates the manifest files locally.
        This function NO LONGER submits PRs directly - it only generates manifests.
        Use Submit-WingetPackage after validation to create the PR.

    .OUTPUTS
        PSCustomObject with properties:
        - Generated: Boolean indicating if manifest was generated
        - ManifestPath: Full path to the generated manifest folder
        - PackageId: The package identifier
        - Version: The package version
        - PrTitle: Suggested PR title
        - Resolves: Issue number if applicable
        - Reason: Reason if manifest was not generated (e.g., "VersionExists", "PRExists")
    #>
    param(
        [Parameter(Mandatory = $false)] [string] $WebsiteURL,
        [Parameter(Mandatory = $false)] [string] $WingetPackage = ${Env:PackageName},
        [Parameter(Mandatory = $false)][ValidateSet("Komac", "WinGetCreate")] [string] $With = "Komac",
        [Parameter(Mandatory = $false)] [string] $resolves = (${Env:resolves} -match '^\d+$' ? ${Env:resolves} : ""),
        [Parameter(Mandatory = $false)] [bool] $Submit = $false,
        [Parameter(Mandatory = $false)] [string] $latestVersion,
        [Parameter(Mandatory = $false)] [string] $latestVersionURL,
        [Parameter(Mandatory = $false)] [bool] $IsTemplateUpdate = $false,
        [Parameter(Mandatory = $false)] [string] $releaseNotes,
        [Parameter(Mandatory = $false)] [string] $GHRepo,
        [Parameter(Mandatory = $false)] [string] $GHURLs
    )

    # Initialize result object
    $result = [PSCustomObject]@{
        Generated    = $false
        ManifestPath = $null
        PackageId    = $WingetPackage
        Version      = $null
        PrTitle      = $null
        Resolves     = $resolves
        Reason       = $null
    }

    # Custom validation
    if (-not $IsTemplateUpdate -and -not $WebsiteURL -and (-not $latestVersion -or -not $latestVersionURL)) {
        throw "Either WebsiteURL or both latestVersion and latestVersionURL are required."
    }

    # NOTE: The $Submit parameter is now deprecated. This function always generates locally.
    # Use Submit-WingetPackage after validation to create the PR.
    if ($Submit) {
        Write-Warning "The -Submit parameter is deprecated. Manifests are now generated locally only. Use Submit-WingetPackage after validation."
    }

    $gitToken = Test-GitHubToken

    if ($latestVersion -and $latestVersionURL) {
        $Latest = @{
            Version      = $latestVersion
            URLs         = $latestVersionURL.split(",").trim().split(" ")
            ReleaseNotes = $releaseNotes
        }
    }
    elseif ($GHRepo -and $GHURLs) {

        $versionTag = Get-LatestGHVersionTag -Repo $GHRepo
        $latestVersion = Get-LatestARPVersion -Repo $GHRepo -Tag $versionTag -GHURLs $GHURLs
        
        $Latest = @{
            Version = $latestVersion
            URLs    = $GHURLs.split(",").trim().split(" ").replace('{ARPVERSION}', $latestVersion).replace('{TAG}', $versionTag).replace('{VERSION}', $latestVersion)
        }
    }
    else {
        Write-Host "Getting latest version and URL for $wingetPackage from $WebsiteURL"
        $Latest = Get-VersionAndUrl -wingetPackage $wingetPackage -WebsiteURL $WebsiteURL
    }

    if ($null -eq $Latest) {
        Write-Host "No version info found"
        $result.Reason = "NoVersionInfo"
        return $result
    }
    Write-Host $Latest
    Write-Host $($Latest.Version)
    Write-Host $($Latest.URLs)
    Write-Host $($Latest.releaseNotes)

    $result.Version = $Latest.Version
    $prMessage = "Update version: $wingetPackage version $($Latest.Version)"
    $result.PrTitle = $prMessage

    $PackageAndVersionInWinget = Test-PackageAndVersionInGithub -wingetPackage $wingetPackage -latestVersion $($Latest.Version)

    $ManifestOutPath = "./"

    if ($PackageAndVersionInWinget) {

        $PRExists = Test-ExistingPRs -PackageIdentifier $wingetPackage -Version $($Latest.Version)
        
        if (!$PRExists) {
            Write-Host "Generating manifest with $With for $wingetPackage Version $($Latest.Version)"
            Switch ($With) {
                "Komac" {
                    Install-Komac
                    # Always use --dry-run to generate manifest locally (never submit directly)
                    $komacArgs = @(
                        "update"
                        $wingetPackage
                        "--version", $Latest.Version
                        "--urls"
                    )
                    $komacArgs += ($Latest.URLs).split(" ").replace('|x64','').replace('|x86','').replace('|arm64','')
                    $komacArgs += "--dry-run"
                    if ($resolves -match '^\d+$') {
                        $komacArgs += "--resolves"
                        $komacArgs += $resolves
                    }
                    $komacArgs += "-t"
                    $komacArgs += $gitToken
                    $komacArgs += "--output"
                    $komacArgs += "$ManifestOutPath"
                    
                    Write-Host "Running: komac $($komacArgs -replace $gitToken, '***' -join ' ')"
                    & komac @komacArgs
                }
                "WinGetCreate" {
                    if ($GHRepo -and $versionTag -and !$Latest.ReleaseNotes) {
                        $Latest.ReleaseNotes = Get-GHReleaseNotes -Repo $GHRepo -Version $versionTag
                    }
                    Install-WingetCreate
                    # Always generate locally (no -s flag)
                    .\wingetcreate.exe update $wingetPackage -v $Latest.Version -u ($Latest.URLs).split(" ") --prtitle $prMessage -t $gitToken -o $ManifestOutPath
                }
                default { 
                    Write-Error "Invalid value \"$With\" for -With parameter. Valid values are 'Komac' and 'WinGetCreate'"
                    $result.Reason = "InvalidTool"
                    return $result
                }
            }

            # If release notes are provided, add them to the manifest
            if ($Latest.releaseNotes) {
                Write-Host "Adding release notes to the manifest in $ManifestOutPath"
                $localFiles = Get-ChildItem -Recurse -Path $ManifestOutPath -Filter "*.locale.*.yaml"
                foreach ($file in $localFiles) {
                    Add-Content -Path $file.FullName -Value "$($Latest.ReleaseNotes)"
                    $newFile = Get-Content -Path $file.FullName
                    # Output new File to see if release notes are added
                    $newFile
                }
            }

            # Calculate full manifest path
            $fullManifestPath = Join-Path -Path $ManifestOutPath -ChildPath "manifests/$($wingetPackage.Substring(0, 1).ToLower())/$($wingetPackage.replace(".","/"))/$($Latest.Version)"
            
            if (Test-Path -Path $fullManifestPath) {
                $result.Generated = $true
                $result.ManifestPath = (Resolve-Path -Path $fullManifestPath).Path
                Write-Host "Manifest generated successfully at: $($result.ManifestPath)" -ForegroundColor Green

                # Output for GitHub Actions
                if ($env:GITHUB_OUTPUT) {
                    "generated=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                    "manifest-path=$($result.ManifestPath)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                    "package-id=$wingetPackage" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                    "version=$($Latest.Version)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                    "pr-title=$prMessage" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                }
            }
            else {
                Write-Warning "Manifest folder not found at expected path: $fullManifestPath"
                $result.Reason = "ManifestNotGenerated"
            }
        }
        else {
            Write-Host "PR already exists for $wingetPackage version $($Latest.Version)"
            $result.Reason = "PRExists"
            
            if ($env:GITHUB_OUTPUT) {
                "generated=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
                "reason=PRExists" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
            }
        }
    }
    else {
        Write-Host "Version $($Latest.Version) already exists in winget for $wingetPackage"
        $result.Reason = "VersionExists"
        
        if ($env:GITHUB_OUTPUT) {
            "generated=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
            "reason=VersionExists" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        }
    }

    return $result
}
