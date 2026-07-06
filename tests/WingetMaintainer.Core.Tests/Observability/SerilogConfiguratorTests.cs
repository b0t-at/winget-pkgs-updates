using FluentAssertions;
using Serilog;
using WingetMaintainer.Core.Observability;
using Xunit;

namespace WingetMaintainer.Core.Tests.Observability;

public sealed class SerilogConfiguratorTests
{
    [Fact]
    public void BuildLabels_IncludesAppEnvironmentHost()
    {
        LoggingOptions options = new()
        {
            App = "winget-maintainer",
            Environment = "Test",
            Host = "runner-1",
        };

        IReadOnlyList<Serilog.Sinks.Grafana.Loki.LokiLabel> labels =
            SerilogConfigurator.BuildLabels(options);

        labels
            .Select(label => label.Key)
            .Should()
            .BeEquivalentTo([
                LokiLabelSchema.App,
                LokiLabelSchema.Environment,
                LokiLabelSchema.Host,
            ]);
        labels.Single(label => label.Key == LokiLabelSchema.Environment).Value.Should().Be("Test");
    }

    [Fact]
    public void BuildLabels_IncludesPhaseWhenProvided()
    {
        LoggingOptions options = new() { Phase = "validate" };

        IReadOnlyList<Serilog.Sinks.Grafana.Loki.LokiLabel> labels =
            SerilogConfigurator.BuildLabels(options);

        labels.Select(label => label.Key).Should().Contain(LokiLabelSchema.Phase);
    }

    [Fact]
    public void BuildLabels_OnlyContainsAllowedKeys()
    {
        LoggingOptions options = new() { Phase = "generate" };

        IReadOnlyList<Serilog.Sinks.Grafana.Loki.LokiLabel> labels =
            SerilogConfigurator.BuildLabels(options);

        labels
            .Select(label => label.Key)
            .Should()
            .OnlyContain(key => LokiLabelSchema.AllowedLabels.Contains(key));
    }

    [Fact]
    public void CreateLogger_WithoutLoki_ProducesUsableLogger()
    {
        LoggingOptions options = new() { LokiUri = null };

        ILogger logger = SerilogConfigurator.CreateLogger(options);

        logger.Should().NotBeNull();
        Action act = () => logger.Information("test {value}", 1);
        act.Should().NotThrow();
    }
}
