# winget-pkgs-updates
**PR repo:** [winget-pkgs](https://github.com/microsoft/winget-pkgs.git)
**Fork repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### Pull requests:
- [**all open PRs**](https://github.com/microsoft/winget-pkgs/pulls/damn-good-b0t)
- [**need attention**](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t)

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
from the configured fork branch to `microsoft/winget-pkgs`. The submission
flow never directly pushes or commits content to `microsoft/winget-pkgs`.

Upstream duplicate and base-ref reads use a tiered credential chain. The
classic `WINGET_PAT` (`public_repo` scope, 5,000 requests/hour) is passed as
`WINGET_UPSTREAM_READ_TOKEN` and used first. Each generation and submission
job also probes `${{ github.token }}` with one read-only
`GET /repos/microsoft/winget-pkgs` request; when the probe succeeds, that
Actions token is passed as `WINGET_UPSTREAM_READ_FALLBACK_TOKEN` (1,000
requests/hour). Administrators may optionally configure
`WINGET_PUBLIC_READ_TOKEN` as a separate public-read credential for the
fallback slot when the probe fails; the repository does not create or require
that secret. If an upstream read fails with HTTP 401, 403, 404, or 429, the
module retries the same request with the next tier, ending with anonymous
public access, so a rate-limited or misbehaving credential can never block a
submission. Read tokens are never used for fork writes or PR creation; fork
writes and the cross-repository PR POST always use `WINGET_PAT`.

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
