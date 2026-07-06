using FluentAssertions;
using WingetMaintainer.Core.Observability;
using Xunit;

namespace WingetMaintainer.Core.Tests.Observability;

public sealed class LokiLabelSchemaTests
{
    [Fact]
    public void EnsureLowCardinality_AllowsStandardLabels()
    {
        Action act = () =>
            LokiLabelSchema.EnsureLowCardinality([
                LokiLabelSchema.App,
                LokiLabelSchema.Environment,
                LokiLabelSchema.Host,
                LokiLabelSchema.Phase,
                LokiLabelSchema.Level,
            ]);

        act.Should().NotThrow();
    }

    [Theory]
    [InlineData("package_id")]
    [InlineData("version")]
    [InlineData("run_id")]
    [InlineData("manifest_hash")]
    [InlineData("error")]
    public void EnsureLowCardinality_RejectsHighCardinalityLabels(string forbidden)
    {
        Action act = () => LokiLabelSchema.EnsureLowCardinality([LokiLabelSchema.App, forbidden]);

        act.Should().Throw<InvalidOperationException>().WithMessage($"*{forbidden}*");
    }

    [Fact]
    public void ForbiddenLabels_AreDisjointFromAllowed()
    {
        LokiLabelSchema.AllowedLabels.Should().NotContain("package_id");
        LokiLabelSchema.ForbiddenLabels.Should().Contain("package_id");
        LokiLabelSchema.ForbiddenLabels.Intersect(LokiLabelSchema.AllowedLabels).Should().BeEmpty();
    }
}
