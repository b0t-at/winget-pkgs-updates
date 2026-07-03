namespace WingetMaintainer.Core.Queue;

/// <summary>A validation job handed to the SandboxRunner (DTO, decoupled from the EF entity).</summary>
public sealed record QueuedJob
{
    public required int Id { get; init; }

    public required int PackageRunId { get; init; }

    public required string PackageId { get; init; }

    public required string ManifestPath { get; init; }

    public int Attempts { get; init; }
}
