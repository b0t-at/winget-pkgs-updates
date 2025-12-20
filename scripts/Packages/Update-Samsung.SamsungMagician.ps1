if ($Env:GITHUB_TOKEN) {
    Write-Host 'GITHUB_TOKEN detected'
    $gitToken = ${Env:GITHUB_TOKEN}
}
else {
    Write-Host 'GITHUB_TOKEN not detected'
    exit 1
}

$wingetPackage = "Samsung.SamsungMagician"

# scrap website for download link https://semiconductor.samsung.com/consumer-storage/support/tools/
$website = "https://www.samsung.com/semiconductor/minisite/ssd/download/tools/"
$websiteContent = Invoke-WebRequest -Uri $website

$links = $websiteContent.Links | Where-Object { $_.href -like "*.exe" -and $_.href -like "*Samsung_Magician_Installer*" }

$latestVersionUrl = $links[0].href

# get full name of file from link
$fileName = $latestVersionUrl.Split("/")[-1]

#download exe File
Invoke-WebRequest -Uri $latestVersionUrl -OutFile $fileName

$file = Get-ChildItem -Path $fileName
$latestVersion = $file.VersionInfo.ProductVersion.trim()



$prMessage = "Update version: $wingetPackage version $latestVersion"

$foundMessage, $textVersion, $separator, $wingetVersions = winget search --id $wingetPackage --source winget --versions

# Check for existing versions in winget
if ($wingetVersions -contains $latestVersion) {
    Write-Output "Latest version of $wingetPackage $latestVersion is already present in winget."
}
else {
    # Check for existing PRs
    $ExistingPRs = gh pr list --search "$($wingetPackage) version $($latestVersion) in:title draft:false" --state 'all' --json 'title,url' --repo 'microsoft/winget-pkgs' | ConvertFrom-Json

    if ($ExistingPRs.Count -gt 0) {
        Write-Output "$foundMessage"
        $ExistingPRs | ForEach-Object {
            Write-Output "Found existing PR: $($_.title)"
            Write-Output "-> $($_.url)"
        }
    }
    elseif ($wingetVersions -and ($wingetVersions -notmatch $latestVersion)) {
        Invoke-WebRequest https://aka.ms/wingetcreate/latest -OutFile wingetcreate.exe
        .\wingetcreate.exe update $wingetPackage -s -v $latestVersion -u "$latestVersionUrl" --prtitle $prMessage -t $gitToken
    }
    else { 
        Write-Output "$foundMessage"
        Write-Output "No existing PRs found. Check why wingetcreate has not run."
    }
}
