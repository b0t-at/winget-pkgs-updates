using Serilog.Events;

namespace WingetMaintainer.Core.Observability;

/// <summary>Options that drive Serilog Console + Loki configuration.</summary>
public sealed record LoggingOptions
{
    /// <summary>Value for the <c>app</c> Loki label.</summary>
    public string App { get; init; } = "winget-maintainer";

    /// <summary>Value for the <c>environment</c> Loki label (e.g. Production, Test).</summary>
    public string Environment { get; init; } = "Production";

    /// <summary>Value for the <c>host</c> Loki label.</summary>
    public string Host { get; init; } = System.Environment.MachineName;

    /// <summary>Optional value for the <c>phase</c> Loki label (e.g. generate, validate, submit).</summary>
    public string? Phase { get; init; }

    /// <summary>Loki push endpoint. When null, only the Console sink is configured.</summary>
    public Uri? LokiUri { get; init; }

    /// <summary>Optional Loki basic-auth user (decision D15: authenticated push).</summary>
    public string? LokiUser { get; init; }

    /// <summary>Optional Loki basic-auth password.</summary>
    public string? LokiPassword { get; init; }

    public LogEventLevel MinimumLevel { get; init; } = LogEventLevel.Information;
}
