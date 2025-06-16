Param(
    [Parameter(Position = 0, HelpMessage = 'The Manifest to install in the Sandbox.')]
    [String] $ManifestURL,
    [Parameter(Position = 1, HelpMessage = 'The script to run in the Sandbox.')]
    [ScriptBlock] $Script,
    [switch] $SkipManifestValidation,
    [switch] $EnableExperimentalFeatures,
    [Parameter(HelpMessage = 'Additional options for WinGet')]
    [string] $WinGetOptions
)
$ManifestURL = $ManifestURL.TrimEnd('/')
$SplittedURL = $ManifestURL -split '/'

# Define the regular expression to find values between a single lowercase char and the version number
$regex = '/([a-z])/(.*?)/([0-9.]*$)'

# Find all values between a single letter and the version number
if ($ManifestURL -match $regex) {
    # Split the matched string by '/'
    $package = ($Matches[2]).replace("/", ".")
}
else {
    $package = "$($SplittedURL[-2]).$($SplittedURL[-3])"
}

if (Test-Path -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ManifestDownload')) {
    Remove-Item -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ManifestDownload') -Force -Recurse
}
$Manifest = New-Item -ItemType Directory -Path (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'ManifestDownload')
Invoke-WebRequest -Uri "$ManifestURL\$package.yaml" -OutFile "$Manifest\$package.yaml"
Invoke-WebRequest -Uri "$ManifestURL\$package.installer.yaml" -OutFile "$Manifest\$package.installer.yaml"
Invoke-WebRequest -Uri "$ManifestURL\$package.locale.en-US.yaml" -OutFile "$Manifest\$package.locale.en-US.yaml"
Write-Host "Manifest Path: $Manifest"

function Update-EnvironmentVariables {
    foreach ($level in "Machine", "User") {
        [Environment]::GetEnvironmentVariables($level).GetEnumerator() | % {
            # For Path variables, append the new values, if they're not already in there
            if ($_.Name -match '^Path$') {
                $_.Value = ($((Get-Content "Env:$($_.Name)") + ";$($_.Value)") -split ';' | Select -unique) -join ';'
            }
            $_
        } | Set-Content -Path { "Env:$($_.Name)" }
    }
}
  
function Get-ARPTable {
    $registry_paths = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    return Get-ItemProperty $registry_paths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and (-not $_.SystemComponent -or $_.SystemComponent -ne 1 ) } |
    Select-Object DisplayName, DisplayVersion, Publisher, @{N = 'ProductCode'; E = { $_.PSChildName } }, @{N = 'Scope'; E = { if ($_.PSDrive.Name -eq 'HKCU') { 'User' } else { 'Machine' } } }
}

$tempFolderName = 'SandboxTest'
$tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath $tempFolderName
# Clean temp directory
# Get-ChildItem $tempFolder -Recurse -Exclude $($(Split-Path $dependencies.SaveTo -Leaf) -replace '\.([^\.]+)$', '.*') | Remove-Item -Force -Recurse
New-Item $tempFolder -ItemType Directory -ErrorAction SilentlyContinue | Out-Null

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
    $folderName = (Get-Item $Manifest).Name
    if (Test-Path -Path "$tempFolder\$folderName") {
        Get-Item -Path "$tempFolder\$folderName" | Remove-Item -Force -Recurse    
    }
    Copy-Item -Path $Manifest -Recurse -Destination $tempFolder
    $Manifest = "$tempFolder\$folderName"
}

if (-Not $SkipManifestValidation -And -Not [String]::IsNullOrWhiteSpace($Manifest)) {
    Write-Host '--> Validating Manifest'
  
    if (-Not (Test-Path -Path $Manifest)) {
        throw [System.IO.DirectoryNotFoundException]::new('The Manifest does not exist.')
    }
  
    winget.exe validate $Manifest
    switch ($LASTEXITCODE) {
        '-1978335191' { throw [System.Exception]::new('Manifest validation failed.') }
        '-1978335192' { Start-Sleep -Seconds 5 }
        Default { continue }
    }
  
    Write-Host
}

# Create Bootstrap settings
# Experimental features can be enabled for forward compatibility with PR's
$bootstrapSettingsContent = @{}
$bootstrapSettingsContent['$schema'] = 'https://aka.ms/winget-settings.schema.json'
$bootstrapSettingsContent['logging'] = @{level = 'verbose' }
if ($EnableExperimentalFeatures) {
    $bootstrapSettingsContent['experimentalFeatures'] = @{
        dependencies     = $true
        openLogsArgument = $true
    }
}

# $settingsFolderName = 'WingetSettings'
# $settingsFolder = Join-Path -Path $tempFolder -ChildPath $settingsFolderName

# New-Item $settingsFolder -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
# $bootstrapSettingsFileName = 'settings.json'
# $bootstrapSettingsContent | ConvertTo-Json | Out-File (Join-Path -Path $settingsFolder -ChildPath $bootstrapSettingsFileName) -Encoding ascii
#$settingsPath = Join-Path -Path $tempFolderName -ChildPath "$settingsFolderName\settings.json"

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
    $manifestFileName = Split-Path $Manifest -Leaf
    $originalARP = Get-ARPTable
    Write-Host "--> Configuring Winget"
    winget settings --Enable LocalManifestFiles
    winget settings --Enable LocalArchiveMalwareScanOverride
    #Copy-Item -Path $settingsPath -Destination C:\Users\WDAGUtilityAccount\AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json
    Write-Host "--> Installing the Manifest $manifestFileName"
    #Write-Host "winget command: winget install -m $Manifest --verbose-logs --ignore-local-archive-malware-scan $WinGetOptions"
    Write-Host "Manifest: $Manifest"

    # Start the Test Script as a background job.
    $job = Start-Job -ScriptBlock { & winget install -m "C:\Users\runneradmin\AppData\Local\Temp\SandboxTest\ManifestDownload" --accept-package-agreements --verbose-logs --ignore-local-archive-malware-scan --dependency-source winget }
          
    # Wait for the job to complete or timeout.
    if (Wait-Job -Job $job -Timeout ([int]$env:TIMEOUT)) {
        Write-Host "Test Script completed within timeout."
        Receive-Job $job
        Remove-Job $job
    }
    else {
        Write-Host "Test Script timed out after $env:TIMEOUT seconds."
        #Stop-Job $job
        #exit 1
    }

    # $timeoutSecs = [int]$env:TIMEOUT
    # Write-Host "Starting winget install with a timeout of $timeoutSecs seconds."

    # $process = New-Object System.Diagnostics.Process
    # $process.StartInfo.FileName = "winget"
    # $process.StartInfo.Arguments = 'install -m "C:\Users\runneradmin\AppData\Local\Temp\SandboxTest\ManifestDownload" --accept-package-agreements --verbose-logs --ignore-local-archive-malware-scan --dependency-source winget'
    # $process.StartInfo.UseShellExecute = $false
    # $process.StartInfo.RedirectStandardOutput = $true
    # $process.StartInfo.RedirectStandardError = $true
    # $process.StartInfo.CreateNoWindow = $true

    # # Event handlers to stream live output.
    # $process.add_OutputDataReceived({ if ($_.Data) { Write-Host $_.Data } })
    # $process.add_ErrorDataReceived({ if ($_.Data) { Write-Host $_.Data } })

    # $process.Start() | Out-Null
    # $process.BeginOutputReadLine()
    # $process.BeginErrorReadLine()

    # if ($process.WaitForExit($timeoutSecs * 1000)) {
    #     Write-Host "Test Script completed within timeout."
    # }
    # else {
    #     Write-Host "Test Script timed out after $env:TIMEOUT seconds."
    # }


    #&{
    #winget install -m $Manifest --accept-package-agreements --verbose-logs --ignore-local-archive-malware-scan --dependency-source winget
    #}
    Write-Host "--> Refreshing environment variables"
    Update-EnvironmentVariables
    Write-Host "--> Comparing ARP Entries"
    $arpDiff = (Compare-Object (Get-ARPTable) $originalARP -Property DisplayName, DisplayVersion, Publisher, ProductCode, Scope) | Select-Object -Property * -ExcludeProperty SideIndicator
    $arpDiff | Format-Table
}

if (-Not [String]::IsNullOrWhiteSpace($Script)) {
    Write-Host '--> Running the following script:'
    {
        $Script
    }
} 

if (-Not [String]::IsNullOrWhiteSpace($Manifest)) {
    if ($arpDiff.Count -eq 0) {
        Write-Host "No differences found in ARP entries. - FAILURE"
        exit 1
    }
    else {
        Write-Host "Differences found in ARP entries. - SUCCESS"
    }
}