function Install-WinMatsch {
    $executable = Get-Command "winmatsch" -ErrorAction SilentlyContinue
    if ($null -ne $executable) {
        Write-Host "WinMatsch is already installed"
        return
    }

    if (-not (Test-Path ".\winmatsch.exe")) {
        $downloadUrl = "https://winmatsch.oneinfra.de/latest/winmatsch-win-x64.exe"
        Write-Host "Downloading WinMatsch from $downloadUrl"
        Invoke-WebRequest -Uri $downloadUrl -OutFile "winmatsch.exe"
    }

    if (Test-Path ".\winmatsch.exe") {
        Write-Host "WinMatsch successfully downloaded"
        New-Alias winmatsch "$(get-location)\winmatsch.exe" -scope Global
    }
    else {
        Write-Error "WinMatsch not downloaded"
        exit 1
    }
}
