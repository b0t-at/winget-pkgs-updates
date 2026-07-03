using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using WingetMaintainer.Core.Process;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Core.Runner;
using WingetMaintainer.Core.Validation;

namespace WingetMaintainer.SandboxRunner;

/// <summary>
/// Single-consumer sandbox validation loop (decision D5, T6.1/T6.4): polls the Worker for the next
/// job, runs the sandbox validator with a hard timeout, and reports the outcome. Concurrency is 1 by
/// construction (one sequential loop). Actual sandbox execution requires an interactive Windows
/// session and is not exercised in CI.
/// </summary>
public sealed class SandboxRunnerService : BackgroundService
{
    private readonly ILogger<SandboxRunnerService> logger;
    private readonly IWorkerApiClient apiClient;
    private readonly SandboxValidationService validationService;
    private readonly RunnerOptions options;

    public SandboxRunnerService(
        ILogger<SandboxRunnerService> logger,
        IWorkerApiClient apiClient,
        SandboxValidationService validationService,
        IOptions<RunnerOptions> options)
    {
        ArgumentNullException.ThrowIfNull(logger);
        ArgumentNullException.ThrowIfNull(apiClient);
        ArgumentNullException.ThrowIfNull(validationService);
        ArgumentNullException.ThrowIfNull(options);
        this.logger = logger;
        this.apiClient = apiClient;
        this.validationService = validationService;
        this.options = options.Value;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("SandboxRunner started (host={Host}, timeout={Timeout}m).", options.Host, options.TimeoutMinutes);
        TimeSpan pollInterval = TimeSpan.FromSeconds(options.PollIntervalSeconds);

        while (!stoppingToken.IsCancellationRequested)
        {
            QueuedJob? job;
            try
            {
                job = await apiClient.GetNextJobAsync(options.Host, stoppingToken).ConfigureAwait(false);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                logger.LogError(exception, "Failed to poll for the next job.");
                await DelayAsync(pollInterval, stoppingToken).ConfigureAwait(false);
                continue;
            }

            if (job is null)
            {
                await DelayAsync(pollInterval, stoppingToken).ConfigureAwait(false);
                continue;
            }

            await ProcessJobAsync(job, stoppingToken).ConfigureAwait(false);
        }
    }

    private async Task ProcessJobAsync(QueuedJob job, CancellationToken stoppingToken)
    {
        logger.LogInformation(
            "Validating job {JobId} for {PackageId} (attempt {Attempt}).", job.Id, job.PackageId, job.Attempts);

        bool timedOut = false;
        int exitCode = -1;
        string? logRef = null;

        using CancellationTokenSource timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        timeoutSource.CancelAfter(TimeSpan.FromMinutes(options.TimeoutMinutes));

        try
        {
            SandboxValidationOptions validationOptions = new()
            {
                ScriptPath = options.ScriptPath,
                ManifestPath = job.ManifestPath,
            };

            ProcessResult result = await validationService
                .ValidateAsync(validationOptions, timeoutSource.Token)
                .ConfigureAwait(false);

            exitCode = result.ExitCode;
        }
        catch (OperationCanceledException) when (timeoutSource.IsCancellationRequested && !stoppingToken.IsCancellationRequested)
        {
            timedOut = true;
            logger.LogWarning("Job {JobId} timed out after {Timeout} minutes.", job.Id, options.TimeoutMinutes);
        }
        catch (OperationCanceledException)
        {
            return; // shutting down
        }
        catch (Exception exception)
        {
            logger.LogError(exception, "Job {JobId} validation failed to execute.", job.Id);
        }

        string status = ValidationOutcome.FromProcess(exitCode, timedOut);
        JobResult jobResult = new()
        {
            JobId = job.Id,
            Status = status,
            Host = options.Host,
            ExitCode = timedOut ? null : exitCode,
            LogRef = logRef,
        };

        try
        {
            await apiClient.ReportResultAsync(jobResult, stoppingToken).ConfigureAwait(false);
            logger.LogInformation("Reported job {JobId} as {Status}.", job.Id, status);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            logger.LogError(exception, "Failed to report result for job {JobId}.", job.Id);
        }
    }

    private static async Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // shutting down
        }
    }
}
