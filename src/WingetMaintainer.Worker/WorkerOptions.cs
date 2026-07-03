namespace WingetMaintainer.Worker;

/// <summary>Worker configuration (bound from the <c>Worker</c> configuration section).</summary>
public sealed class WorkerOptions
{
    public const string SectionName = "Worker";

    /// <summary>SQLite database path (single-writer, owned by the Worker — decision D6).</summary>
    public string DatabasePath { get; set; } = "winget-maintainer.db";

    /// <summary>Path to the monitored packages YAML.</summary>
    public string ConfigPath { get; set; } = "github-releases-monitored.yml";

    /// <summary>API key required on the internal API (X-Api-Key header). Empty = API denied.</summary>
    public string? ApiKey { get; set; }

    /// <summary>Cron expression for the scheduled catalog check (default hourly).</summary>
    public string ScheduleCron { get; set; } = "0 * * * *";

    /// <summary>Whether the submit pipeline is enabled (equivalent of the legacy SUBMIT_PR flag).</summary>
    public bool SubmitEnabled { get; set; }

    /// <summary>Failed-validation threshold before a package is skipped (decision D14).</summary>
    public int MaxFailures { get; set; } = 3;

    public string Environment { get; set; } = "Production";

    public string? LokiUri { get; set; }

    public string? LokiUser { get; set; }

    public string? LokiPassword { get; set; }
}
