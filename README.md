# winget-pkgs-updates
**Submission repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### Fork submissions:
- [**all open PRs**](https://github.com/damn-good-b0t/winget-pkgs/pulls)
- [**need attention**](https://github.com/damn-good-b0t/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t)

| Package Version Handling| Count|
|----------------------------|---------------------------------------------------------------|
| Script based     | ![Script based Packages](https://img.shields.io/badge/ScriptPackages-23-green) |
| GitHub Release based     | ![GitHub based Packages](https://img.shields.io/badge/GithubPackages-344-blue) |


## Tools:
**[Orca](https://learn.microsoft.com/de-de/windows/win32/msi/orca-exe)**: database table editor for creating and editing Windows Installer packages

## Scheduled submission topology

Validated scheduled manifests use `ForkBranch` submission rather than
`wingetcreate submit`. `WINGET_PKGS_FORK_REPO` must name a user-owned fork;
the module verifies that repository is a fork of `microsoft/winget-pkgs`,
creates a disposable branch directly from its default branch, and commits only
the manifest files to that branch. It never syncs or writes the fork default
branch.

Every trigger, including scheduled main-branch runs, opens the pull request
inside the configured fork. Submissions to `microsoft/winget-pkgs` are
disabled. A fine-grained PAT needs Contents write and Pull requests write on
the configured fork; it does not need GitHub Actions workflow scope.

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
