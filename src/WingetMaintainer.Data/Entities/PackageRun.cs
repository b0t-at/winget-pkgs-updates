namespace WingetMaintainer.Data.Entities;

/// <summary>A single generate/validate/submit run for a package (replaces artifact-name IPC).</summary>
public sealed class PackageRun
{
    public int Id { get; set; }

    public string PackageIdentifier { get; set; } = string.Empty;

    public string Version { get; set; } = string.Empty;

    public string? ManifestHash { get; set; }

    /// <summary>Pipeline phase (e.g. generate, validate, submit).</summary>
    public string Phase { get; set; } = string.Empty;

    /// <summary>Outcome of the phase (e.g. pending, succeeded, failed, skipped).</summary>
    public string Outcome { get; set; } = string.Empty;

    public string? ManifestPath { get; set; }

    public string? Error { get; set; }

    public DateTimeOffset StartedAt { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }

    public ICollection<ValidationJob> ValidationJobs { get; set; } = [];
}
