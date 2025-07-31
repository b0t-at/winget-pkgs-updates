# winget-pkgs-updates
**PR repo:** [winget-pkgs](https://github.com/microsoft/winget-pkgs.git)  
**Fork repo:** [damn-good-b0t/winget-pkgs](https://github.com/damn-good-b0t/winget-pkgs)

### PRs:
- [**all open PRs**](https://github.com/microsoft/winget-pkgs/pulls/damn-good-b0t)
- [**need attention**](https://github.com/microsoft/winget-pkgs/pulls?q=is%3Aopen+is%3Apr+author%3Adamn-good-b0t+-label%3AAzure-Pipeline-Passed+)

| Package Version Handling| Count|
|----------------------------|---------------------------------------------------------------|
| Script based     | ![Script based Packages](https://img.shields.io/badge/ScriptPackages-26-green) |
| GitHub Release based     | ![GitHub based Packages](https://img.shields.io/badge/GithubPackages-371-blue) |

## New Feature: Package Manifest Overrides

🎉 **NEW**: Customize Komac-generated manifests with override files! 

The override system allows you to:
- **Drop** unwanted fields (e.g., ReleaseDate)
- **Override** existing values (e.g., Tags, Description)
- **Add** new fields with placeholders (e.g., ReleaseNotes with {VERSION})
- **Apply different rules** for different manifest types

[📖 **See Documentation**](docs/PackageManifestOverrides.md) for complete usage guide.

### Quick Example

Create `overrides/{PackageId}/locale.yaml`:
```yaml
Override:
  Tags:
    - database
    - server
Add:
  ReleaseNotes: |
    Release {VERSION} of {PACKAGE_ID}
    Released: {CURRENT_DATE}
Drop:
  - ReleaseDate
```

## Tools:
**[Orca](https://learn.microsoft.com/de-de/windows/win32/msi/orca-exe)**: database table editor for creating and editing Windows Installer packages
