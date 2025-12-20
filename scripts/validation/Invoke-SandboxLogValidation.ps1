<#
.SYNOPSIS
    Analyzes winget manifest installation results from Windows Sandbox testing.

.DESCRIPTION
    This script reads and displays the installation logs and ARP (Add/Remove Programs) entries
    captured during a Windows Sandbox manifest test. It provides a summary of:
    - WinGet installation log files
    - ARP entries before and after installation
    - Differences in ARP entries (newly installed programs)

.PARAMETER LogFolder
    Path to the logs folder containing WinGet logs and ARP entry files.

.EXAMPLE
    .\Test-Sandbox-Installation.ps1 -LogFolder "C:\Path\To\Logs"

.NOTES
    This script is called automatically by Test-Manifest-Sandbox.ps1 after sandbox testing completes.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, HelpMessage = 'Path to the logs folder')]
    [ValidateScript({
        if (-Not (Test-Path -Path $_ -PathType Container)) { throw "$_ is not a valid folder." }
        return $true
    })]
    [String] $LogFolder
)

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "   Sandbox Installation Analysis" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Display WinGet Log Files
Write-Host "[WinGet Log Files]" -ForegroundColor Green
Write-Host "------------------" -ForegroundColor Green
$WinGetLogsPath = Join-Path $LogFolder 'WinGetLogs'
if (Test-Path $WinGetLogsPath) {
    $logFiles = Get-ChildItem -Path $WinGetLogsPath -Recurse -File
    if ($logFiles.Count -gt 0) {
        Write-Host "Found $($logFiles.Count) log file(s):`n"
        foreach ($logFile in $logFiles) {
            $relativePath = $logFile.FullName.Substring($WinGetLogsPath.Length + 1)
            $sizeKB = [math]::Round($logFile.Length / 1KB, 2)
            Write-Host "  - $relativePath" -ForegroundColor Yellow
            Write-Host "    Size: $sizeKB KB | Modified: $($logFile.LastWriteTime)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No log files found." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WinGet logs folder not found at: $WinGetLogsPath" -ForegroundColor Red
}

# Display ARP Entry Files
Write-Host "`n`n[ARP Entry Files]" -ForegroundColor Green
Write-Host "-----------------" -ForegroundColor Green

$arpFiles = @('ARP_Before.csv', 'ARP_After.csv', 'ARP_Differences.csv')
foreach ($arpFile in $arpFiles) {
    $arpPath = Join-Path $LogFolder $arpFile
    if (Test-Path $arpPath) {
        $entries = Import-Csv -Path $arpPath
        Write-Host "`n  $arpFile - $($entries.Count) entries" -ForegroundColor Yellow
    } else {
        Write-Host "`n  $arpFile - NOT FOUND" -ForegroundColor Red
    }
}

# Display ARP Differences (New Installations)
Write-Host "`n`n[Installation Results]" -ForegroundColor Green
Write-Host "----------------------" -ForegroundColor Green
$arpDiffPath = Join-Path $LogFolder 'ARP_Differences.csv'
if (Test-Path $arpDiffPath) {
    $differences = Import-Csv -Path $arpDiffPath
    if ($differences.Count -gt 0) {
        Write-Host "`nDetected $($differences.Count) new ARP entry/entries:`n" -ForegroundColor Cyan
        $differences | Format-Table DisplayName, DisplayVersion, Publisher, Scope -AutoSize
    } else {
        Write-Host "`nNo new ARP entries detected. Installation may have failed or not created ARP entries." -ForegroundColor Yellow
    }
} else {
    Write-Host "`nARP differences file not found." -ForegroundColor Red
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "   Analysis Complete" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Log folder location: $LogFolder`n" -ForegroundColor Gray