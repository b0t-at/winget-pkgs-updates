namespace WingetMaintainer.Core.Queue;

/// <summary>Outcome reported by the SandboxRunner for a validation job.</summary>
public sealed record JobResult
{
    public required int JobId { get; init; }

    /// <summary>Terminal status (e.g. passed, failed, timed_out).</summary>
    public required string Status { get; init; }

    public string? Host { get; init; }

    public int? ExitCode { get; init; }

    public string? LogRef { get; init; }
}

/// <summary>
/// Single-consumer validation queue backed by the database (decision D5/D7). The SandboxRunner is
/// the only consumer (MaxConcurrency=1) and reports results back through this abstraction.
/// </summary>
public interface IValidationQueue
{
    /// <summary>Enqueues a new pending validation job and returns its id.</summary>
    Task<int> EnqueueAsync(int packageRunId, string packageId, string manifestPath, CancellationToken cancellationToken);

    /// <summary>Atomically claims the oldest pending job (marks it in-progress) or returns null.</summary>
    Task<QueuedJob?> DequeueNextAsync(string host, CancellationToken cancellationToken);

    /// <summary>Records a terminal result for a previously claimed job.</summary>
    Task CompleteAsync(JobResult result, CancellationToken cancellationToken);
}
