namespace WingetMaintainer.Core.State;

/// <summary>Input to record a validation outcome for a package.</summary>
public sealed record PackageStateUpdate
{
    public required string PackageIdentifier { get; init; }

    public required string Version { get; init; }

    public required string ManifestHash { get; init; }

    public required string State { get; init; }

    public IReadOnlyList<string> InstallerHashes { get; init; } = [];

    public string? Description { get; init; }
}
