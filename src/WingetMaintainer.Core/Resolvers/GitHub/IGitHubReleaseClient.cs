namespace WingetMaintainer.Core.Resolvers.GitHub;

/// <summary>A GitHub release, reduced to the fields the resolver needs.</summary>
public sealed record GitHubRelease(
    string TagName,
    bool Draft,
    bool Prerelease,
    DateTimeOffset? PublishedAt,
    IReadOnlyList<string> AssetUrls
);

/// <summary>
/// Abstraction over the GitHub releases API. Kept separate from Octokit so the resolver
/// can be unit-tested without network access.
/// </summary>
public interface IGitHubReleaseClient
{
    Task<IReadOnlyList<GitHubRelease>> GetReleasesAsync(
        string owner,
        string repository,
        CancellationToken cancellationToken
    );
}
