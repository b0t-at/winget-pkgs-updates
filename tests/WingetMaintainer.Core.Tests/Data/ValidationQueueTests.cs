using FluentAssertions;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Data;
using WingetMaintainer.Data.Entities;
using Xunit;

namespace WingetMaintainer.Core.Tests.Data;

public sealed class ValidationQueueTests : IDisposable
{
    private readonly SqliteInMemory database = new();

    public void Dispose() => database.Dispose();

    private async Task<int> SeedRunAsync()
    {
        using WingetMaintainerDbContext context = database.CreateContext();
        PackageRun run = new()
        {
            PackageIdentifier = "Contoso.App",
            Version = "1.0.0",
            Phase = "generate",
            Outcome = "succeeded",
            StartedAt = DateTimeOffset.UtcNow,
        };
        context.PackageRuns.Add(run);
        await context.SaveChangesAsync(CancellationToken.None);
        return run.Id;
    }

    [Fact]
    public async Task DequeueNextAsync_ReturnsOldestPendingAndMarksInProgress()
    {
        int runId = await SeedRunAsync();
        ValidationQueue queue = new(database.CreateContext());

        int firstId = await queue.EnqueueAsync(
            runId,
            "Contoso.App",
            @"C:\m\1",
            CancellationToken.None
        );
        await queue.EnqueueAsync(runId, "Contoso.App", @"C:\m\2", CancellationToken.None);

        QueuedJob? job = await new ValidationQueue(database.CreateContext()).DequeueNextAsync(
            "runner-1",
            CancellationToken.None
        );

        job.Should().NotBeNull();
        job!.Id.Should().Be(firstId);
        job.ManifestPath.Should().Be(@"C:\m\1");
        job.Attempts.Should().Be(1);

        using WingetMaintainerDbContext context = database.CreateContext();
        ValidationJob persisted = context.ValidationJobs.Single(candidate =>
            candidate.Id == firstId
        );
        persisted.Status.Should().Be(ValidationJobStatuses.InProgress);
        persisted.Host.Should().Be("runner-1");
    }

    [Fact]
    public async Task DequeueNextAsync_EmptyQueue_ReturnsNull()
    {
        QueuedJob? job = await new ValidationQueue(database.CreateContext()).DequeueNextAsync(
            "runner-1",
            CancellationToken.None
        );

        job.Should().BeNull();
    }

    [Fact]
    public async Task CompleteAsync_SetsTerminalStatusAndResultFields()
    {
        int runId = await SeedRunAsync();
        int jobId = await new ValidationQueue(database.CreateContext()).EnqueueAsync(
            runId,
            "Contoso.App",
            @"C:\m\1",
            CancellationToken.None
        );
        await new ValidationQueue(database.CreateContext()).DequeueNextAsync(
            "runner-1",
            CancellationToken.None
        );

        await new ValidationQueue(database.CreateContext()).CompleteAsync(
            new JobResult
            {
                JobId = jobId,
                Status = ValidationJobStatuses.Passed,
                Host = "runner-1",
                ExitCode = 0,
                LogRef = "log://x",
            },
            CancellationToken.None
        );

        using WingetMaintainerDbContext context = database.CreateContext();
        ValidationJob persisted = context.ValidationJobs.Single(candidate => candidate.Id == jobId);
        persisted.Status.Should().Be(ValidationJobStatuses.Passed);
        persisted.ExitCode.Should().Be(0);
        persisted.LogRef.Should().Be("log://x");
        persisted.CompletedAt.Should().NotBeNull();
    }

    [Fact]
    public async Task CompleteAsync_UnknownJob_Throws()
    {
        Func<Task> act = () =>
            new ValidationQueue(database.CreateContext()).CompleteAsync(
                new JobResult { JobId = 999, Status = ValidationJobStatuses.Failed },
                CancellationToken.None
            );

        await act.Should().ThrowAsync<InvalidOperationException>();
    }
}
