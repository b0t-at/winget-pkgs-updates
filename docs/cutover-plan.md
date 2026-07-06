# Cutover & decommission plan (P7.3 / P7.4)

How the .NET service replaces the GitHub Actions + PowerShell/Python pipeline **without a risky big-bang**.
This is a plan, not an executed step — perform it on the live infrastructure once the earlier phases are
validated end-to-end.

## Current vs target

| Concern            | Legacy                           | Target                              |
| ------------------ | -------------------------------- | ----------------------------------- |
| Scheduling         | GitHub Actions cron              | Worker (Cronos)                     |
| Matrix/generation  | Python + PowerShell              | CLI/Worker (C#)                     |
| IPC between stages | artifact-name regex              | DB rows (PackageRun/ValidationJob)  |
| State              | `data/package-state.json` in git | SQLite (Worker-owned)               |
| Sandbox validation | self-hosted Actions runner       | SandboxRunner (interactive session) |
| Observability      | Actions logs / RDP               | Loki + Grafana                      |

## Phase A — Shadow mode (no behaviour change)

1. Deploy Worker + SandboxRunner + Loki/Grafana on the host(s) (see `docker/README.md`,
   `docs/sandbox-runner.md`). Keep `Worker:SubmitEnabled = false`.
2. Import current state: run the JSON→DB importer against `data/package-state.json` so the DB starts at
   parity (decision D14 semantics preserved).
3. Let the Worker run **alongside** the existing Actions pipeline. It resolves/generates/validates but
   does **not** submit PRs.
4. Compare outcomes for ~1 week: version resolved, manifest hash, and validation result should match the
   Actions pipeline. Investigate every divergence.

## Phase B — Switch submission

1. Enable `Worker:SubmitEnabled = true` for a small allow-list of packages; keep Actions submission off
   for those to avoid double PRs.
2. Verify PRs land correctly (komac/wingetcreate) from the Worker path.
3. Expand the allow-list gradually to all packages.

## Phase C — Retire the Actions cron

1. Disable the scheduled Actions workflows (keep manual `workflow_dispatch` + PR-based sandbox test
   workflows if still useful).
2. Stop writing `data/package-state.json` from Actions; the DB is now the source of truth. Keep the file
   as a read-only historical artifact until confidence is high.

## Phase D — Decommission (only after resolver parity)

1. Port the remaining `scripts/Packages/Update-*.ps1` scrapers to C# `IReleaseResolver` (workstream
   P-Resolvers) with golden tests. The `PowerShellShimResolver` bridges any not-yet-ported package.
2. Once every package resolves in C#, remove the PowerShell module, the Python orchestrators, and the
   generated workflow YAMLs from the core loop.
3. Confirm the repo builds and the Worker runs the full catalog with no PowerShell/Python in the loop.

## Rollback

At any phase, re-enabling the Actions cron and disabling `Worker:SubmitEnabled` returns to the legacy
pipeline; the DB and Loki data remain for diagnosis.

## Authentication (D-AUTH)

Until app-level auth is added, the Dashboard and Worker API must not be exposed publicly. Start with
**Tailscale-only** access (recommended), or a reverse proxy terminating basic/OIDC auth. The Worker API is
already gated by `X-Api-Key`; the Blazor dashboard currently relies on network-level protection.
