# winget-pkgs-updates
**PR repo:** [winget-pkgs](https://github.com/microsoft/winget-pkgs.git)
**Fork repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### Pull requests:
- [**all open PRs**](https://github.com/microsoft/winget-pkgs/pulls/damn-good-b0t)
- [**need attention**](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t)

| Package Version Handling| Count|
|----------------------------|---------------------------------------------------------------|
| Script based     | ![Script based Packages](https://img.shields.io/badge/ScriptPackages-23-green) |
| GitHub Release based     | ![GitHub based Packages](https://img.shields.io/badge/GithubPackages-1027-blue) |


## Package-specific WinMatsch overrides

Keep safety questions enabled by default. When a package has reviewed, stable
exceptions, add a WinMatsch override-pack YAML file to the repository and set
its matrix entry's `overridePack` field to that repository-relative path:

```yaml
- id: Publisher.App
  repo: publisher/app
  url: https://github.com/publisher/app/releases/download/v{VERSION}/setup.exe
  overridePack: overrides/Publisher.App.yaml
```

The single-package workflow exposes the same path as `overridePack`. The wrapper
rejects missing files and rejects override packs with Komac or WinGetCreate, so
an override cannot be silently ignored.

For a reviewed installer architecture, type, or scope transition, set
`allowStructuralRewrite: true` on that package's matrix entry. This approval is
disabled by default and maps only to WinMatsch's `--allow-structural-rewrite`
option.

## Editing the monitored list

`github-releases-monitored.yml` is the source of truth, but the workflows read
the generated sidecar `.github/workflows-data/update-github-packages-*.packages.json`.
After every edit (adding, retiring or reconfiguring a package) regenerate the
sidecar and commit it together with the yml:

```powershell
pip install pyyaml
python scripts/orchestrate_gh-packages.py
```

`tests/GitHubReleaseMonitoringConfiguration.Tests.ps1` fails when the sidecar
and the yml disagree, so a retired package can no longer keep being submitted
because the regeneration step was skipped. Retire a package by commenting out
its entry and adding a `#  <Id> is excluded: <reason>` note above it;
`scripts/Disable-ReAddedExcludedPackages.ps1` re-applies documented exclusions.

## Submission policies

Besides the duplicate-PR and published-version checks, manifest generation
stops (reason in the job output) when one of these holds applies:

| Reason | Rule |
| --- | --- |
| `ReleaseTooFresh` | The GitHub release is younger than the minimum age, measured from the newest of the release's publish time and the upload time of the assets the package uses. Disabled by default (`0`); set globally via `WINGET_MIN_RELEASE_AGE_HOURS` or per package via `minReleaseAgeHours` on the matrix entry, e.g. `48` for packages whose publisher files their own PR within a day. |
| `BlockedByUpstreamValidation` | The bot's previous PR for the identical version was closed unmerged with a blocking label (`Validation-Defender-Error`, `Binary-Validation-Error`, `Validation-Certificate-Root`, `URL-Validation-Error`, `Validation-Unattended-Failed`, `Validation-Installation-Error`, `Validation-Shell-Execute`, `Blocking-Issue`, `DriverInstall`). A new upstream version is submitted normally. |
| `HeldForManualValidation` | The bot's open PR for an older version carries `Azure-Pipeline-Passed` plus `Validation-Executable-Error`/`Validation-No-Executables` (moderators' manual-validation queue), is younger than 14 days, and the new version is only a patch bump. Superseding would reset the package's place in that queue. Non-patch releases and PRs older than 14 days supersede as before. |

The update precheck additionally skips `ChannelCooldown` packages: identifiers
ending in `.Nightly`, `.Beta`, `.Preview`, `.PreRelease` or `.Canary` run at
most once every 3 days, regardless of the previous run's verdict.

Numeric-stream identifiers (`OpenJS.Electron.41`) must pin their stream with a
`tagPattern`; generation additionally fails closed when the resolved version
does not start with the pinned number.

## End-to-end installer analysis

`scripts/analyze/Invoke-InstallerE2E.ps1` answers "what would our pipeline do
with this installer?" without touching any monitored package:

```powershell
# Direct URL(s)
./scripts/analyze/Invoke-InstallerE2E.ps1 -InstallerUrl 'https://example.com/setup.exe'

# Any winget-pkgs PR - installer URLs are extracted from the PR's manifests
./scripts/analyze/Invoke-InstallerE2E.ps1 -WingetPkgsPr 421311
```

It runs `winmatsch analyze` per URL (architecture, installer type, silent
switches, hashes, dependencies), generates a throwaway manifest with
`winmatsch new` under a demo identifier (nothing is submitted), validates it,
and - when Windows Sandbox is enabled - installs it via
`scripts/validation/Test-Manifest-Sandbox.ps1`. `report.md` and `report.json`
are written to `data/e2e-analysis/<timestamp>/` (gitignored). Use
`-SkipSandbox`, `-SkipManifest`, or `-SkipAnalyze` to shorten the loop.
