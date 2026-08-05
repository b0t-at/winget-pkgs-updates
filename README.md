# winget-pkgs-updates
**PR repo:** [winget-pkgs](https://github.com/microsoft/winget-pkgs.git)  
**Fork repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### PRs:
- [**all open PRs**](https://github.com/microsoft/winget-pkgs/pulls/damn-good-b0t)
- [**need attention**](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t+-label%3AAzure-Pipeline-Passed+)

| Package Version Handling| Count|
|----------------------------|---------------------------------------------------------------|
| Script based     | ![Script based Packages](https://img.shields.io/badge/ScriptPackages-23-green) |
| GitHub Release based     | ![GitHub based Packages](https://img.shields.io/badge/GithubPackages-353-blue) |


## Tools:
**[Orca](https://learn.microsoft.com/de-de/windows/win32/msi/orca-exe)**: database table editor for creating and editing Windows Installer packages

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
