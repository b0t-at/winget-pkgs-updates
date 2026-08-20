# winget-pkgs-updates
**PR repo:** [winget-pkgs](https://github.com/microsoft/winget-pkgs.git)
**Fork repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### Pull requests:
- [**all open PRs**](https://github.com/microsoft/winget-pkgs/pulls/damn-good-b0t)
- [**need attention**](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t)

| Package Version Handling| Count|
|----------------------------|---------------------------------------------------------------|
| Script based     | ![Script based Packages](https://img.shields.io/badge/ScriptPackages-23-green) |
| GitHub Release based     | ![GitHub based Packages](https://img.shields.io/badge/GithubPackages-1042-blue) |


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
