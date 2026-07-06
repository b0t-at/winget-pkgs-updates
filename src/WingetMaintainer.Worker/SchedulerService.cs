using Cronos;
using Microsoft.Extensions.Options;

namespace WingetMaintainer.Worker;

/// <summary>
/// Cron-driven background scheduler (decision D4: scheduling moves into the Worker). On each tick it
/// triggers a catalog check. The generate/submit pipeline is invoked here once live resolvers/tools
/// are available; for now it emits a structured scheduled-check event.
/// </summary>
public sealed class SchedulerService : BackgroundService
{
    private readonly ILogger<SchedulerService> logger;
    private readonly WorkerOptions options;

    public SchedulerService(ILogger<SchedulerService> logger, IOptions<WorkerOptions> options)
    {
        ArgumentNullException.ThrowIfNull(logger);
        ArgumentNullException.ThrowIfNull(options);
        this.logger = logger;
        this.options = options.Value;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        CronExpression cron;
        try
        {
            cron = CronExpression.Parse(options.ScheduleCron);
        }
        catch (CronFormatException exception)
        {
            logger.LogError(
                exception,
                "Invalid schedule cron expression '{Cron}'.",
                options.ScheduleCron
            );
            return;
        }

        logger.LogInformation("Scheduler started with cron '{Cron}'.", options.ScheduleCron);

        while (!stoppingToken.IsCancellationRequested)
        {
            DateTime? next = cron.GetNextOccurrence(DateTime.UtcNow);
            if (next is null)
            {
                logger.LogWarning(
                    "Cron '{Cron}' has no future occurrences; scheduler stopping.",
                    options.ScheduleCron
                );
                return;
            }

            TimeSpan delay = next.Value - DateTime.UtcNow;
            if (delay > TimeSpan.Zero)
            {
                try
                {
                    await Task.Delay(delay, stoppingToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
            }

            try
            {
                logger.LogInformation(
                    "Scheduled catalog check triggered ({Event}).",
                    "scheduled_check"
                );
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                logger.LogError(exception, "Scheduled catalog check failed.");
            }
        }
    }
}
