using Octokit;

namespace WingetMaintainer.Core.Resolvers.GitHub;

/// <summary>Octokit-backed implementation of <see cref="IGitHubReleaseClient"/>.</summary>
public sealed class OctokitGitHubReleaseClient : IGitHubReleaseClient
{
    private readonly IGitHubClient client;

    public OctokitGitHubReleaseClient(IGitHubClient client)
    {
        ArgumentNullException.ThrowIfNull(client);
        this.client = client;
    }

    public async Task<IReadOnlyList<GitHubRelease>> GetReleasesAsync(
        string owner,
        string repository,
        CancellationToken cancellationToken
    )
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<Release> releases = await client.Repository.Release.GetAll(owner, repository);

        return releases
            .Select(release => new GitHubRelease(
                release.TagName,
                release.Draft,
                release.Prerelease,
                release.PublishedAt,
                release.Assets.Select(asset => asset.BrowserDownloadUrl).ToList()
            ))
            .ToList();
    }
}
