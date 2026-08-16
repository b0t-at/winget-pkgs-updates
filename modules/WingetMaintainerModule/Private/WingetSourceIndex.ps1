#Requires -Version 7.0

<#
    Access layer for the official WinGet source index (`source2.msix`).

    The community source ships a small SQLite database that already knows the
    published (latest) version of every package in `microsoft/winget-pkgs`. That
    is roughly a 3 MB download versus cloning the ~250k manifest files, so it is
    the cheapest possible starting point for a repository-wide scan.

    SQLite access uses `winsqlite3.dll`, which is part of Windows, so no external
    module or NuGet package is needed. Non-Windows hosts fall back to the
    `sqlite3` CLI that GitHub-hosted Linux runners already provide.
#>

$script:WingetSourceIndexUri = 'https://cdn.winget.microsoft.com/cache/source2.msix'
$script:WingetSourceIndexEntryName = 'Public/index.db'

function Get-WingetSourceIndexCacheRoot {
    param([string] $CachePath)

    if ([string]::IsNullOrWhiteSpace($CachePath)) {
        $CachePath = Join-Path ([System.IO.Path]::GetTempPath()) 'winget-source-index'
    }

    if (-not (Test-Path -LiteralPath $CachePath)) {
        New-Item -ItemType Directory -Path $CachePath -Force | Out-Null
    }

    return (Resolve-Path -LiteralPath $CachePath).Path
}

function Initialize-WingetSqliteInterop {
    <#
    .SYNOPSIS
        Declares the minimal read-only P/Invoke surface for winsqlite3.dll.
    #>
    if ('WingetSqliteNative' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WingetSqliteNative
{
    public const int OpenReadOnly = 0x00000001;
    public const int Ok = 0;
    public const int Row = 100;

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open_v2", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Open(byte[] filename, out IntPtr db, int flags, IntPtr vfs);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare_v2", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Prepare(IntPtr db, byte[] sql, int byteCount, out IntPtr statement, out IntPtr tail);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Step(IntPtr statement);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int ColumnCount(IntPtr statement);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ColumnText(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_name", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ColumnName(IntPtr statement, int column);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize", CallingConvention = CallingConvention.Cdecl)]
    public static extern int FinalizeStatement(IntPtr statement);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Close(IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_errmsg", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ErrorMessage(IntPtr db);

    public static string ToManagedString(IntPtr value)
    {
        return value == IntPtr.Zero ? null : Marshal.PtrToStringUTF8(value);
    }
}
'@
}

function Invoke-WingetSourceIndexQuery {
    <#
    .SYNOPSIS
        Runs a read-only query against an extracted WinGet index database.

    .OUTPUTS
        One PSCustomObject per row, with one property per selected column.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $DatabasePath,
        [Parameter(Mandatory = $true)] [string] $Query
    )

    if (-not $IsWindows) {
        $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if (-not $sqlite) {
            throw 'Reading the WinGet source index on this platform requires the sqlite3 CLI to be on PATH.'
        }

        $json = & $sqlite.Source -json $DatabasePath $Query
        if ([string]::IsNullOrWhiteSpace(($json -join ''))) {
            return @()
        }

        return @(($json -join "`n") | ConvertFrom-Json)
    }

    Initialize-WingetSqliteInterop

    $database = [IntPtr]::Zero
    $statement = [IntPtr]::Zero
    $tail = [IntPtr]::Zero

    $rc = [WingetSqliteNative]::Open(
        [System.Text.Encoding]::UTF8.GetBytes($DatabasePath + "`0"),
        [ref] $database,
        [WingetSqliteNative]::OpenReadOnly,
        [IntPtr]::Zero)
    if ($rc -ne [WingetSqliteNative]::Ok) {
        throw "Failed to open the WinGet source index at '$DatabasePath' (sqlite rc=$rc)."
    }

    try {
        $rc = [WingetSqliteNative]::Prepare(
            $database,
            [System.Text.Encoding]::UTF8.GetBytes($Query + "`0"),
            -1,
            [ref] $statement,
            [ref] $tail)
        if ($rc -ne [WingetSqliteNative]::Ok) {
            $message = [WingetSqliteNative]::ToManagedString([WingetSqliteNative]::ErrorMessage($database))
            throw "Failed to prepare the WinGet source index query (sqlite rc=$rc): $message"
        }

        $columnCount = [WingetSqliteNative]::ColumnCount($statement)
        $columnNames = for ($i = 0; $i -lt $columnCount; $i++) {
            [WingetSqliteNative]::ToManagedString([WingetSqliteNative]::ColumnName($statement, $i))
        }

        $rows = [System.Collections.Generic.List[object]]::new()
        while ([WingetSqliteNative]::Step($statement) -eq [WingetSqliteNative]::Row) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $columnCount; $i++) {
                $row[$columnNames[$i]] = [WingetSqliteNative]::ToManagedString([WingetSqliteNative]::ColumnText($statement, $i))
            }
            $rows.Add([PSCustomObject]$row)
        }

        return $rows.ToArray()
    }
    finally {
        if ($statement -ne [IntPtr]::Zero) { [void][WingetSqliteNative]::FinalizeStatement($statement) }
        if ($database -ne [IntPtr]::Zero) { [void][WingetSqliteNative]::Close($database) }
    }
}

function Get-WingetSourceIndexDatabasePath {
    <#
    .SYNOPSIS
        Downloads and extracts `Public/index.db` from the community source MSIX.

    .DESCRIPTION
        The MSIX is a plain zip container. A HEAD request compares Last-Modified
        and Content-Length against the cached copy so repeated scans in the same
        day re-use the extracted database instead of downloading it again.
    #>
    [CmdletBinding()]
    param(
        [Parameter()] [string] $CachePath,
        [Parameter()] [switch] $Force
    )

    $root = Get-WingetSourceIndexCacheRoot -CachePath $CachePath
    $msixPath = Join-Path $root 'source2.msix'
    $databasePath = Join-Path $root 'index.db'
    $metadataPath = Join-Path $root 'index.meta.json'

    $remoteTag = $null
    try {
        $head = Invoke-WebRequest -Uri $script:WingetSourceIndexUri -Method Head -TimeoutSec 60
        $remoteTag = '{0}|{1}' -f ($head.Headers['Last-Modified'] -join ''), ($head.Headers['Content-Length'] -join '')
    }
    catch {
        Write-Verbose "HEAD request for the WinGet source index failed: $($_.Exception.Message)"
    }

    if (-not $Force -and (Test-Path -LiteralPath $databasePath) -and (Test-Path -LiteralPath $metadataPath)) {
        $cachedTag = (Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json).Tag
        if ($null -ne $remoteTag -and $cachedTag -eq $remoteTag) {
            Write-Verbose "Re-using cached WinGet source index at '$databasePath'."
            return $databasePath
        }
    }

    Write-Verbose "Downloading the WinGet source index from $($script:WingetSourceIndexUri)."
    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $script:WingetSourceIndexUri -OutFile $msixPath -TimeoutSec 300
    }
    finally {
        $ProgressPreference = $previousProgress
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($msixPath)
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -eq $script:WingetSourceIndexEntryName } | Select-Object -First 1
        if (-not $entry) {
            throw "The WinGet source package did not contain '$($script:WingetSourceIndexEntryName)'."
        }

        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $databasePath, $true)
    }
    finally {
        $archive.Dispose()
    }

    if ($null -ne $remoteTag) {
        @{ Tag = $remoteTag; RetrievedAt = (Get-Date).ToUniversalTime().ToString('o') } |
            ConvertTo-Json |
            Set-Content -LiteralPath $metadataPath -Encoding utf8
    }

    return $databasePath
}
