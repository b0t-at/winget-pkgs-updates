function Update-WingetPackage {
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

    # Custom validation
    if (-not $IsTemplateUpdate -and -not $WebsiteURL -and (-not $latestVersion -or -not $latestVersionURL)) {
        throw "Either WebsiteURL or both latestVersion and latestVersionURL are required."
    }

    # if ($Submit -eq $false) {
    #     $env:DRY_RUN = $true
    # }


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
        exit 1
    }
    Write-Host $Latest
    Write-Host $($Latest.Version)
    Write-Host $($Latest.URLs)
    Write-Host $($Latest.releaseNotes)

    $prMessage = "Update version: $wingetPackage version $($Latest.Version)"

    $PackageAndVersionInWinget = Test-PackageAndVersionInGithub -wingetPackage $wingetPackage -latestVersion $($Latest.Version)

    $ManifestOutPath = "./"

    if ($PackageAndVersionInWinget) {

        $PRExists = Test-ExistingPRs -PackageIdentifier $wingetPackage -Version $($Latest.Version)
        
        if (!$PRExists) {
            Write-Host "Downloading $With and open PR for $wingetPackage Version $($Latest.Version)"
            Switch ($With) {
                "Komac" {
                    Install-Komac
                    #.\komac update $wingetPackage --version $Latest.Version --urls ($Latest.URLs).split(" ") --dry-run ($resolves -match '^\d+$' ? "--resolves" : $null ) ($resolves -match '^\d+$' ? $resolves : $null ) -t $gitToken --output "$ManifestOutPath"
                    komac update $wingetPackage --version $Latest.Version --urls ($Latest.URLs).split(" ").replace('|x64','').replace('|x86','').replace('|arm64','') ($Submit -eq $true -and !$Latest.ReleaseNotes ? '-s' : '--dry-run') ($resolves -match '^\d+$' ? "--resolves" : $null ) ($resolves -match '^\d+$' ? $resolves : $null ) -t $gitToken --output "$ManifestOutPath"
                }
                "WinGetCreate" {
                    if ($GHRepo -and $versionTag -and !$Latest.ReleaseNotes) {
                        $Latest.ReleaseNotes = Get-GHReleaseNotes -Repo $GHRepo -Version $versionTag
                    }
                    Install-WingetCreate
                    #.\wingetcreate.exe update $wingetPackage -v $Latest.Version -u ($Latest.URLs).split(" ") --prtitle $prMessage -t $gitToken -o $ManifestOutPath
                    .\wingetcreate.exe update $wingetPackage ($Submit -eq $true -and !$Latest.ReleaseNotes ? "-s" : $null ) -v $Latest.Version -u ($Latest.URLs).split(" ") --prtitle $prMessage -t $gitToken -o $ManifestOutPath
                }
                default { 
                    Write-Error "Invalid value \"$With\" for -With parameter. Valid values are 'Komac' and 'WinGetCreate'"
                }
            }

            # Apply manifest overrides if they exist
            Write-Host "Checking for manifest overrides for $wingetPackage"
            $manifestFiles = Get-ChildItem -Recurse -Path $ManifestOutPath -Filter "*.yaml"
            $placeholders = Get-PackagePlaceholders -PackageIdentifier $wingetPackage -Version $Latest.Version -LatestInfo $Latest
            
            foreach ($file in $manifestFiles) {
                $manifestType = "default"
                
                # Determine manifest type from filename
                if ($file.Name -match "\.installer\.") {
                    $manifestType = "installer"
                } elseif ($file.Name -match "\.locale\.") {
                    $manifestType = "locale"
                } elseif ($file.Name -match "\.yaml$" -and $file.Name -notmatch "\.locale\." -and $file.Name -notmatch "\.installer\.") {
                    $manifestType = "version"
                }
                
                # Get overrides for this manifest type
                $overrides = Get-ManifestOverrides -PackageIdentifier $wingetPackage -ManifestType $manifestType
                
                if ($overrides.Count -gt 0) {
                    Write-Host "Applying overrides to $($file.FullName)"
                    Apply-ManifestOverrides -ManifestPath $file.FullName -Overrides $overrides -Placeholders $placeholders
                }
            }
            
            # Legacy support: If release notes are provided, add them to locale manifests
            if ($Latest.releaseNotes) {
                Write-Host "Adding release notes to locale manifests in $ManifestOutPath"
                $localeFiles = Get-ChildItem -Recurse -Path $ManifestOutPath -Filter "*.locale.*.yaml"
                foreach ($file in $localeFiles) {
                    # Check if ReleaseNotes already exists in the file to avoid duplication
                    $fileContent = Get-Content -Path $file.FullName -Raw
                    if ($fileContent -notmatch "ReleaseNotes:") {
                        Add-Content -Path $file.FullName -Value "ReleaseNotes: |"
                        # Format release notes with proper indentation
                        $formattedNotes = $Latest.ReleaseNotes -split "`n" | ForEach-Object { "  $_" }
                        Add-Content -Path $file.FullName -Value $formattedNotes
                    }
                    $newFile = Get-Content -Path $file.FullName
                    # Output new File to see if release notes are added
                    $newFile
                }
            }
            
            # Submit PR with wingetcreate if -Submit is set to true
            if ($Submit -eq $true) {
                Install-WingetCreate
                Write-Host "Submitting PR for $wingetPackage Version $($Latest.Version)"
                .\wingetcreate.exe submit --prtitle $prMessage -t $gitToken "$($ManifestOutPath)manifests/$($wingetPackage.Substring(0, 1).ToLower())/$($wingetPackage.replace(".","/"))/$($Latest.Version)"
            }            
        }
    }
}
