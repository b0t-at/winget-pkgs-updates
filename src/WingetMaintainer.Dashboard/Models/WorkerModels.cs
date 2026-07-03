namespace WingetMaintainer.Dashboard.Models;

/// <summary>A package run row as returned by the Worker <c>/api/runs</c> endpoint.</summary>
public sealed record RunDto
{
    public int Id { get; init; }

    public string PackageIdentifier { get; init; } = string.Empty;

    public string Version { get; init; } = string.Empty;

    public string? ManifestHash { get; init; }

    public string Phase { get; init; } = string.Empty;

    public string Outcome { get; init; } = string.Empty;

    public DateTimeOffset StartedAt { get; init; }

    public DateTimeOffset? CompletedAt { get; init; }
}

/// <summary>Package validation state as returned by the Worker <c>/api/state/{id}</c> endpoint.</summary>
public sealed record PackageStateDto
{
    public string PackageIdentifier { get; init; } = string.Empty;

    public string Version { get; init; } = string.Empty;

    public string ManifestHash { get; init; } = string.Empty;

    public string State { get; init; } = string.Empty;

    public int ValidationCount { get; init; }

    public IReadOnlyList<string> InstallerHashes { get; init; } = [];

    public DateTimeOffset LastUpdated { get; init; }
}
