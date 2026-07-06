using Serilog;
using Serilog.Formatting.Json;
using Serilog.Sinks.Grafana.Loki;

namespace WingetMaintainer.Core.Observability;

/// <summary>
/// Configures Serilog with a JSON Console sink (keeps Actions/console logs working) and, when a Loki
/// endpoint is supplied, a Grafana Loki sink using the low-cardinality label schema (decision D9).
/// </summary>
public static class SerilogConfigurator
{
    /// <summary>Builds the Loki labels from <paramref name="options"/> and validates cardinality.</summary>
    public static IReadOnlyList<LokiLabel> BuildLabels(LoggingOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        List<LokiLabel> labels =
        [
            new LokiLabel { Key = LokiLabelSchema.App, Value = options.App },
            new LokiLabel { Key = LokiLabelSchema.Environment, Value = options.Environment },
            new LokiLabel { Key = LokiLabelSchema.Host, Value = options.Host },
        ];

        if (!string.IsNullOrWhiteSpace(options.Phase))
        {
            labels.Add(new LokiLabel { Key = LokiLabelSchema.Phase, Value = options.Phase });
        }

        LokiLabelSchema.EnsureLowCardinality(labels.Select(label => label.Key));
        return labels;
    }

    /// <summary>Applies Console (+ optional Loki) sinks to the supplied configuration.</summary>
    public static LoggerConfiguration Configure(
        LoggerConfiguration configuration,
        LoggingOptions options
    )
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(options);

        configuration
            .MinimumLevel.Is(options.MinimumLevel)
            .Enrich.FromLogContext()
            .WriteTo.Console(new JsonFormatter());

        if (options.LokiUri is not null)
        {
            LokiCredentials? credentials = string.IsNullOrWhiteSpace(options.LokiUser)
                ? null
                : new LokiCredentials
                {
                    Login = options.LokiUser,
                    Password = options.LokiPassword ?? string.Empty,
                };

            configuration.WriteTo.GrafanaLoki(
                options.LokiUri.ToString(),
                labels: BuildLabels(options),
                credentials: credentials
            );
        }

        return configuration;
    }

    /// <summary>Convenience: build a ready-to-use logger from <paramref name="options"/>.</summary>
    public static ILogger CreateLogger(LoggingOptions options) =>
        Configure(new LoggerConfiguration(), options).CreateLogger();
}
