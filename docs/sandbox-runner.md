# SandboxRunner operations (Windows Sandbox validation)

The SandboxRunner is the **single consumer** of the validation queue (decision D5). It polls the
Worker's internal API, runs `Test-Manifest-Sandbox.ps1` for one job at a time, and reports the
outcome. It is Windows-only and requires an **interactive desktop session** — Windows Sandbox does
not launch from Session 0 (the session used by normal Windows Services).

> ⚠️ Not verified live in this environment (no interactive Windows Sandbox / self-hosted runner
> available here). Follow this runbook on the sandbox host and validate before relying on it.

## Configuration (`Runner` section / env)

| Setting | Env var | Default |
| --- | --- | --- |
| Worker base URL | `Runner__WorkerBaseUrl` | `http://localhost:5099/` |
| API key | `Runner__ApiKey` | (required for a secured Worker) |
| Host label | `Runner__Host` | machine name |
| Script path | `Runner__ScriptPath` | `scripts/validation/Test-Manifest-Sandbox.ps1` |
| Poll interval (s) | `Runner__PollIntervalSeconds` | `15` |
| Timeout (min) | `Runner__TimeoutMinutes` | `30` |

Concurrency is **1 by construction** (a single sequential loop); each job is bounded by
`TimeoutMinutes` and reported as `timed_out` if it exceeds it.

## Why not a Windows Service?

A classic service runs in Session 0, which has no interactive desktop; Windows Sandbox refuses to
start there. Run the SandboxRunner in an **auto-logged-on interactive session** instead.

## Recommended setup: auto-logon + Scheduled Task (at logon)

1. **Enable auto-logon** for a dedicated local user (use a strong password; store it only where the
   OS keeps it). Configure via `netplwiz` or the Sysinternals `Autologon` tool. Do **not** commit
   credentials.
2. **Create a scheduled task that runs at logon** in that interactive session:

   ```powershell
   $exe = "C:\winget-maintainer\SandboxRunner\WingetMaintainer.SandboxRunner.exe"
   $action  = New-ScheduledTaskAction -Execute $exe
   $trigger = New-ScheduledTaskTrigger -AtLogOn
   # Run only when the interactive user is logged on (NOT "run whether logged on or not").
   $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\sandbox" -LogonType Interactive -RunLevel Highest
   $settings  = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
       -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
   Register-ScheduledTask -TaskName "WingetSandboxRunner" -Action $action -Trigger $trigger `
       -Principal $principal -Settings $settings
   ```

3. Provide configuration via machine environment variables or an `appsettings.json` next to the exe.
4. Confirm the runner starts on logon and that `Test-Manifest-Sandbox.ps1` can launch Windows Sandbox
   in that session.

## Logs

The runner logs JSON to the console and (optionally) to Loki. Point Grafana **Alloy** at the sandbox
script's log directory (`docker/alloy/config.alloy`, `SANDBOX_LOG_GLOB`) so per-run logs and
screenshots surface on the *Sandbox Validation* dashboard (label `phase=validate`).
