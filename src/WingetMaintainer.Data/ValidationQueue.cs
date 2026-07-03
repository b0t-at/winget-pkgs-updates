using Microsoft.EntityFrameworkCore;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Data.Entities;

namespace WingetMaintainer.Data;

/// <summary>EF Core-backed <see cref="IValidationQueue"/> (single-consumer, oldest-first).</summary>
public sealed class ValidationQueue : IValidationQueue
{
    private readonly WingetMaintainerDbContext dbContext;
    private readonly TimeProvider timeProvider;

    public ValidationQueue(WingetMaintainerDbContext dbContext, TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(dbContext);
        this.dbContext = dbContext;
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<int> EnqueueAsync(
        int packageRunId,
        string packageId,
        string manifestPath,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(packageId);
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestPath);

        ValidationJob job = new()
        {
            PackageRunId = packageRunId,
            PackageIdentifier = packageId,
            ManifestPath = manifestPath,
            Status = ValidationJobStatuses.Pending,
            CreatedAt = timeProvider.GetUtcNow(),
        };

        dbContext.ValidationJobs.Add(job);
        await dbContext.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
        return job.Id;
    }

    public async Task<QueuedJob?> DequeueNextAsync(string host, CancellationToken cancellationToken)
    {
        ValidationJob? job = await dbContext.ValidationJobs
            .Where(candidate => candidate.Status == ValidationJobStatuses.Pending)
            .OrderBy(candidate => candidate.Id)
            .FirstOrDefaultAsync(cancellationToken)
            .ConfigureAwait(false);

        if (job is null)
        {
            return null;
        }

        job.Status = ValidationJobStatuses.InProgress;
        job.Attempts += 1;
        job.Host = host;
        job.StartedAt = timeProvider.GetUtcNow();
        await dbContext.SaveChangesAsync(cancellationToken).ConfigureAwait(false);

        return new QueuedJob
        {
            Id = job.Id,
            PackageRunId = job.PackageRunId,
            PackageId = job.PackageIdentifier,
            ManifestPath = job.ManifestPath,
            Attempts = job.Attempts,
        };
    }

    public async Task CompleteAsync(JobResult result, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(result);

        ValidationJob? job = await dbContext.ValidationJobs
            .FindAsync([result.JobId], cancellationToken)
            .ConfigureAwait(false)
            ?? throw new InvalidOperationException($"Validation job {result.JobId} not found.");

        job.Status = result.Status;
        job.Host = result.Host ?? job.Host;
        job.ExitCode = result.ExitCode;
        job.LogRef = result.LogRef;
        job.CompletedAt = timeProvider.GetUtcNow();

        await dbContext.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
    }
}
