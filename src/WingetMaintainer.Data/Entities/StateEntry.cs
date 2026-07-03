namespace WingetMaintainer.Data.Entities;

/// <summary>
/// Persisted validation state for a package, mirroring the legacy <c>package-state.json</c> entry.
/// </summary>
public sealed class StateEntry
{
    public string PackageIdentifier { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    public string ManifestHash { get; set; } = string.Empty;

    public string State { get; set; } = string.Empty;

    public int ValidationCount { get; set; }

    public List<string> InstallerHashes { get; set; } = [];

    public string Description { get; set; } = string.Empty;

    public DateTimeOffset LastUpdated { get; set; }
}
