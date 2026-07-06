using FluentAssertions;
using WingetMaintainer.Core.Configuration;
using WingetMaintainer.Core.Resolvers;
using WingetMaintainer.Core.Resolvers.GitHub;
using Xunit;

namespace WingetMaintainer.Core.Tests.Resolvers;

public sealed class GitHubReleaseResolverTests
{
    private static MonitoredPackage Package(string? tagPattern = null) =>
        new()
        {
            Id = "Sample.Package",
            Repo = "owner/name",
            Url = "https://host/{TAG}/tool-{VERSION}.zip",
            TagPattern = tagPattern,
        };

    [Fact]
    public async Task ResolveAsync_PicksLatestNonDraftAndStripsPrefix()
    {
        FakeGitHubReleaseClient client = new(
            new GitHubRelease(
                "v1.0.0",
                Draft: false,
                Prerelease: false,
                DateTimeOffset.Parse("2024-01-01T00:00:00Z"),
                []
            ),
            new GitHubRelease(
                "v2.0.0",
                Draft: false,
                Prerelease: false,
                DateTimeOffset.Parse("2024-06-01T00:00:00Z"),
                []
            ),
            new GitHubRelease(
                "v3.0.0",
                Draft: true,
                Prerelease: false,
                DateTimeOffset.Parse("2024-09-01T00:00:00Z"),
                []
            )
        );
        GitHubReleaseResolver resolver = new(client);

        ResolvedRelease? result = await resolver.ResolveAsync(Package(), CancellationToken.None);

        result.Should().NotBeNull();
        result!.Version.Should().Be("2.0.0");
        result.Tag.Should().Be("v2.0.0");
        result.Urls.Should().ContainSingle();
        result.Urls[0].Url.Should().Be("https://host/v2.0.0/tool-2.0.0.zip");
    }

    [Fact]
    public async Task ResolveAsync_AppliesTagPattern()
    {
        FakeGitHubReleaseClient client = new(
            new GitHubRelease(
                "nightly",
                Draft: false,
                Prerelease: true,
                DateTimeOffset.Parse("2024-09-01T00:00:00Z"),
                []
            ),
            new GitHubRelease(
                "1.5.0",
                Draft: false,
                Prerelease: false,
                DateTimeOffset.Parse("2024-06-01T00:00:00Z"),
                []
            )
        );
        GitHubReleaseResolver resolver = new(client);

        ResolvedRelease? result = await resolver.ResolveAsync(
            Package(tagPattern: "^[0-9]"),
            CancellationToken.None
        );

        result.Should().NotBeNull();
        result!.Version.Should().Be("1.5.0");
    }

    [Fact]
    public async Task ResolveAsync_NoCandidates_ReturnsNull()
    {
        FakeGitHubReleaseClient client = new(
            new GitHubRelease(
                "draft-only",
                Draft: true,
                Prerelease: false,
                DateTimeOffset.UtcNow,
                []
            )
        );
        GitHubReleaseResolver resolver = new(client);

        ResolvedRelease? result = await resolver.ResolveAsync(Package(), CancellationToken.None);

        result.Should().BeNull();
    }

    [Fact]
    public void CanResolve_RequiresOwnerSlashName()
    {
        GitHubReleaseResolver resolver = new(new FakeGitHubReleaseClient());

        resolver
            .CanResolve(
                new MonitoredPackage
                {
                    Id = "a",
                    Repo = "owner/name",
                    Url = "u",
                }
            )
            .Should()
            .BeTrue();
        resolver
            .CanResolve(
                new MonitoredPackage
                {
                    Id = "a",
                    Repo = "no-slash",
                    Url = "u",
                }
            )
            .Should()
            .BeFalse();
    }
}
