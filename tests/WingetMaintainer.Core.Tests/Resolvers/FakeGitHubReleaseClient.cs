using WingetMaintainer.Core.Resolvers.GitHub;

namespace WingetMaintainer.Core.Tests.Resolvers;

/// <summary>In-memory <see cref="IGitHubReleaseClient"/> for resolver unit tests.</summary>
internal sealed class FakeGitHubReleaseClient : IGitHubReleaseClient
{
    private readonly IReadOnlyList<GitHubRelease> releases;

    public FakeGitHubReleaseClient(params GitHubRelease[] releases) => this.releases = releases;

    public Task<IReadOnlyList<GitHubRelease>> GetReleasesAsync(
        string owner,
        string repository,
        CancellationToken cancellationToken
    ) => Task.FromResult(releases);
}
