using FluentAssertions;
using WingetMaintainer.Core.Security;
using Xunit;

namespace WingetMaintainer.Core.Tests.Security;

public sealed class ApiKeyValidatorTests
{
    [Fact]
    public void IsAuthorized_MatchingKeys_ReturnsTrue()
    {
        ApiKeyValidator.IsAuthorized("s3cret", "s3cret").Should().BeTrue();
    }

    [Theory]
    [InlineData("wrong", "s3cret")]
    [InlineData("", "s3cret")]
    [InlineData(null, "s3cret")]
    [InlineData("s3cret", "")]
    [InlineData("s3cret", null)]
    [InlineData(null, null)]
    public void IsAuthorized_MismatchOrMissing_ReturnsFalse(string? provided, string? expected)
    {
        ApiKeyValidator.IsAuthorized(provided, expected).Should().BeFalse();
    }
}
