using WingetMaintainer.Core.Configuration;

namespace WingetMaintainer.Core.Resolvers.PowerShell;

/// <summary>
/// Bridges to the legacy per-package PowerShell scrapers under <c>scripts/Packages</c>
/// during the migration. In this phase it only reports which packages are script-based
/// (via <see cref="CanResolve"/>); live execution of the scrapers is wired up in a later
/// phase once the manifest-generation services exist.
/// </summary>
public sealed class PowerShellShimResolver : IReleaseResolver
{
    private readonly string packagesScriptDirectory;

    public PowerShellShimResolver(string packagesScriptDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packagesScriptDirectory);
        this.packagesScriptDirectory = packagesScriptDirectory;
    }

    /// <summary>Returns the expected per-package script path for a package id.</summary>
    public string GetScriptPath(MonitoredPackage package)
    {
        ArgumentNullException.ThrowIfNull(package);
        return Path.Combine(packagesScriptDirectory, $"Update-{package.Id}.ps1");
    }

    public bool CanResolve(MonitoredPackage package) => File.Exists(GetScriptPath(package));

    public Task<ResolvedRelease?> ResolveAsync(MonitoredPackage package, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(package);
        throw new NotSupportedException(
            "Live execution of the PowerShell scraper shim is implemented in a later phase " +
            "(it depends on the manifest-generation services). Use CanResolve to detect script-based packages.");
    }
}
