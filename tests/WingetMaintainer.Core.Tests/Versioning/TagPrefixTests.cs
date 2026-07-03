using FluentAssertions;
using WingetMaintainer.Core.Versioning;
using Xunit;

namespace WingetMaintainer.Core.Tests.Versioning;

public sealed class TagPrefixTests
{
    [Theory]
    [InlineData("v1.2.3", "1.2.3")]
    [InlineData("V2.0", "2.0")]
    [InlineData("1.2.3", "1.2.3")]
    [InlineData("release-1.0.0", "1.0.0")]
    [InlineData("version-4.5", "4.5")]
    [InlineData("2024.1", "2024.1")]
    [InlineData("vscode", "vscode")] // 'v' not followed by a digit is preserved
    public void Strip_RemovesKnownPrefixes(string tag, string expected)
    {
        TagPrefix.Strip(tag).Should().Be(expected);
    }
}
