function Get-WinMatschPlatform {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return 'Windows'
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
        return 'Linux'
    }
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) {
        return 'MacOS'
    }

    throw 'Unsupported operating system for WinMatsch installation.'
}

function Get-WinMatschArchitecture {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64' { return 'x64' }
        'Arm64' { return 'arm64' }
        default { throw "Unsupported processor architecture for WinMatsch installation: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)." }
    }
}

function Get-WinMatschDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Platform = (Get-WinMatschPlatform),

        [Parameter(Mandatory = $false)]
        [string] $Architecture
    )

    switch ($Platform) {
        'Windows' {
            $assetName = 'winmatsch-win-x64.exe'
            $fileName = 'winmatsch.exe'
        }
        'Linux' {
            if ([string]::IsNullOrWhiteSpace($Architecture)) {
                $Architecture = Get-WinMatschArchitecture
            }
            if ($Architecture -notin @('x64', 'arm64')) {
                throw "Unsupported Linux processor architecture for WinMatsch installation: $Architecture."
            }
            $assetName = "winmatsch-linux-$Architecture"
            $fileName = 'winmatsch'
        }
        'MacOS' {
            if ([string]::IsNullOrWhiteSpace($Architecture)) {
                $Architecture = Get-WinMatschArchitecture
            }
            if ($Architecture -notin @('x64', 'arm64')) {
                throw "Unsupported macOS processor architecture for WinMatsch installation: $Architecture."
            }
            $assetName = "winmatsch-osx-$Architecture"
            $fileName = 'winmatsch'
        }
        default {
            throw "Unsupported operating system for WinMatsch installation: $Platform."
        }
    }

    [PSCustomObject]@{
        Url      = "https://winmatsch.oneinfra.de/latest/$assetName"
        FileName = $fileName
    }
}

function Set-WinMatschExecutablePermission {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    & chmod +x $Path
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to mark WinMatsch executable: $Path"
    }
}

function Install-WinMatsch {
    $executable = Get-Command "winmatsch" -ErrorAction SilentlyContinue
    if ($null -ne $executable) {
        Write-Host "WinMatsch is already installed"
        return
    }

    $download = Get-WinMatschDownload
    $localPath = Join-Path (Get-Location) $download.FileName

    if (-not (Test-Path $localPath)) {
        $downloadUrl = $download.Url
        Write-Host "Downloading WinMatsch from $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath
    }

    if (Test-Path $localPath) {
        if ((Get-WinMatschPlatform) -ne 'Windows') {
            Set-WinMatschExecutablePermission -Path $localPath
        }

        Write-Host "WinMatsch successfully downloaded"
        New-Alias winmatsch $localPath -scope Global
    }
    else {
        Write-Error "WinMatsch not downloaded"
        exit 1
    }
}
