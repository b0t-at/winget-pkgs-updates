using FluentAssertions;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Core.Runner;
using Xunit;

namespace WingetMaintainer.Core.Tests.Runner;

public sealed class ValidationOutcomeTests
{
    [Theory]
    [InlineData(0, false, ValidationStatus.Passed)]
    [InlineData(1, false, ValidationStatus.Failed)]
    [InlineData(-1, false, ValidationStatus.Failed)]
    [InlineData(0, true, ValidationStatus.TimedOut)]
    [InlineData(5, true, ValidationStatus.TimedOut)]
    public void FromProcess_MapsExitCodeAndTimeout(int exitCode, bool timedOut, string expected)
    {
        ValidationOutcome.FromProcess(exitCode, timedOut).Should().Be(expected);
    }
}
