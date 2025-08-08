# SandboxTest.ps1 Documentation

## Purpose
`SandboxTest.ps1` automates launching Windows Sandbox, installing (or repairing) WinGet inside it, optionally installing a local manifest, running a user supplied ScriptBlock, and exposing verbose WinGet logs on the host for analysis.

## Key Features
- Automated WinGet install from release assets (fallback to PowerShell module if needed)
- Optional local manifest installation via `winget install -m`
- ARP (Add/Remove Programs) delta output before/after install
- Execution of a provided ScriptBlock inside the sandbox
- Optional enabling of experimental WinGet features
- Real‑time access to WinGet verbose logs by directly mapping the sandbox log directory (`DiagOutputDir`) to a host folder (no post-run copy step)
- Supports prerelease selection and explicit version pinning

## Prerequisites
- Windows 10/11 Pro or Enterprise with Windows Sandbox feature enabled
- PowerShell 5.1+ (or 7+ if adapted)
- Internet access (unless all dependencies are cached)
- Optional: environment variable `WINGET_PKGS_GITHUB_TOKEN` to avoid GitHub API rate limits

## Exit Codes
| Code | Meaning |
|------|---------|
| -1 | Sandbox not available / not enabled |
| 0 | Success |
| 1 | Error fetching GitHub release metadata |
| 2 | Unable to terminate running sandbox process |
| 3 | WinGet not installed / installation failure |
| 4 | Manifest validation error |

## Parameters
| Parameter | Type | Default | Required | Description |
|-----------|------|---------|----------|-------------|
| `Manifest` | String (path) | (empty) | No | Path to a manifest folder or a YAML within one. Installed with `winget install -m` if provided. |
| `Script` | ScriptBlock | (empty) | No | Custom code executed after (optional) install. Saved as `BoundParameterScript.ps1`. |
| `MapFolder` | String (folder) | Current directory (`$pwd`) | No | Host folder base. The log subfolder is created here and mapped directly to the sandbox WinGet log path. |
| `WinGetVersion` | String | (empty) | No | Explicit WinGet version tag (e.g. `v1.9.2523`). If omitted: latest (or latest prerelease with `-Prerelease`). |
| `WinGetOptions` | String | (empty) | No | Extra arguments appended to the `winget install` command. |
| `LogFolderName` | String | (empty) | No | Optional custom prefix for the host log folder. Otherwise derived from manifest name (or `NoManifest`). Timestamp always appended. |
| `SkipManifestValidation` | Switch | False | No | Skips local manifest validation (use sparingly). |
| `Prerelease` | Switch | False | No | Use latest prerelease instead of latest stable. |
| `EnableExperimentalFeatures` | Switch | False | No | Enables defined experimental features in generated `settings.json`. |
| `Clean` | Switch | False | No | Forces re-download / cleaning of relevant caches (depending on implementation). |

## Log Exposure Strategy (Current Implementation)
1. Before launching the sandbox a unique log folder is created under `MapFolder` (name pattern below).
2. The sandbox configuration maps that host folder directly to the sandbox path:
   `%LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir`
3. Winget writes logs as usual; they appear immediately in the host log folder (live view, no copy needed).
4. Naming pattern:  
   - With `-LogFolderName`: `<LogFolderName>`  
   - Without: `<ManifestName|NoManifest>_<yyyyMMdd_HHmm>`

## Mapped Folders
- Test data folder (bootstrap script, settings, dependencies)
- Host log folder mapped as the sandbox `DiagOutputDir` (live log passthrough)

## High-Level Flow
1. Parse parameters and prepare host log destination folder.
2. Terminate lingering sandbox processes (avoid lock issues).
3. Fetch release metadata, build dependency list, download/verify.
4. Optionally enable experimental features.
5. Generate `settings.json` and bootstrap script.
6. Create `.wsb` configuration (mapped folders + direct log folder mapping + startup command).
7. Launch sandbox.
8. Inside sandbox: install/repair WinGet, apply settings, optionally install manifest, show ARP diff, run optional script.
9. Logs are already present live on host (no extra copy step).
10. Exit with appropriate code.

## Environment Variables
| Variable | Purpose |
|----------|---------|
| `WINGET_PKGS_GITHUB_TOKEN` | Increases GitHub API rate limits when querying release data |

## Examples
Install a manifest and view logs live:
```powershell
./SandboxTest.ps1 -Manifest ./manifests/m/MongoDB/MongoDB.Server/6.0.0
```

Use prerelease and additional options:
```powershell
./SandboxTest.ps1 -Manifest ./manifests/a/rex -Prerelease -WinGetOptions '--ignore-local-archive-malware-scan'
```

Run a post-install script:
```powershell
./SandboxTest.ps1 -Manifest ./manifests/g/glueckkanja/KONNEKT/1.0.0 -Script {
  Write-Host 'Verifying installation...'
  winget list | Select-String KONNEKT
}
```

Custom log folder prefix (e.g. CI run ID):
```powershell
./SandboxTest.ps1 -Manifest ./manifests/s/shawnbanasick/Tool/2.4.1 -LogFolderName Run1234
```

Baseline sandbox (no manifest):
```powershell
./SandboxTest.ps1
```

Enable experimental features and skip validation:
```powershell
./SandboxTest.ps1 -Manifest ./manifests/m/mortenn/App/5.0.0 -EnableExperimentalFeatures -SkipManifestValidation
```

## Recommendations
- Prefer supplying the manifest folder instead of a single YAML file.
- In CI, use `-LogFolderName` with run/build IDs for traceability.
- Avoid `-SkipManifestValidation` unless debugging.
- Provide a GitHub token for frequent executions to avoid rate limiting.

## Troubleshooting
| Symptom | Suggestion |
|---------|------------|
| Log folder empty | Confirm sandbox started and WinGet produced output; ensure mapping line with `<SandboxFolder>` exists in generated `.wsb`. |
| Exit code 3 | Check network, dependency downloads, or module fallback installation logs. |
| Sandbox will not start | Ensure feature is enabled and no stale processes remain. |
| Rate limit warnings | Set `WINGET_PKGS_GITHUB_TOKEN`. |

## Security Notes
- Mapped host log folder is writable from sandbox; avoid mapping sensitive directories.
- Always review any provided ScriptBlock.

## Possible Extensions
- Optional `-ZipLogs` (post-run archive if desired even with direct mapping).
- Parameter to purge old log folders.
- Filter to restrict which log file types are kept.

## Summary
`SandboxTest.ps1` launches an isolated Windows Sandbox, installs and configures WinGet, optionally installs a local manifest and runs custom logic, while exposing the WinGet verbose log directory live to a timestamped host folder.

---
Last Updated: (Adjust when modifying this document)
