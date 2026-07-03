namespace WingetMaintainer.Data.Entities;

/// <summary>A queued sandbox-validation job consumed by the single-instance SandboxRunner.</summary>
public sealed class ValidationJob
{
    public int Id { get; set; }

    public int PackageRunId { get; set; }

    public PackageRun? PackageRun { get; set; }

    public string PackageIdentifier { get; set; } = string.Empty;

    public string ManifestPath { get; set; } = string.Empty;

    public string Status { get; set; } = ValidationJobStatuses.Pending;

    public int Attempts { get; set; }

    public string? Host { get; set; }

    public int? ExitCode { get; set; }

    /// <summary>Reference (path/URL) to captured logs or screenshots.</summary>
    public string? LogRef { get; set; }

    public DateTimeOffset CreatedAt { get; set; }

    public DateTimeOffset? StartedAt { get; set; }

    public DateTimeOffset? CompletedAt { get; set; }
}
