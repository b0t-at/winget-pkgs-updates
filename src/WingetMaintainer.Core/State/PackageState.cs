namespace WingetMaintainer.Core.State;

/// <summary>
/// Immutable snapshot of a package's validation state, mirroring the legacy
/// <c>data/package-state.json</c> entry shape.
/// </summary>
public sealed record PackageState
{
    public required string PackageIdentifier { get; init; }

    public required string Version { get; init; }

    public required string ManifestHash { get; init; }

    public required string State { get; init; }

    public int ValidationCount { get; init; }

    public IReadOnlyList<string> InstallerHashes { get; init; } = [];

    public string Description { get; init; } = string.Empty;

    public DateTimeOffset LastUpdated { get; init; }
}
