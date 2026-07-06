using System.Text.RegularExpressions;
using WingetMaintainer.Core.Configuration;
using WingetMaintainer.Core.Urls;
using WingetMaintainer.Core.Versioning;

namespace WingetMaintainer.Core.Resolvers.GitHub;

/// <summary>
/// Resolves the latest GitHub release for a monitored package: it applies the optional
/// tag pattern, strips tag prefixes to derive the version, and expands the URL template.
/// </summary>
public sealed class GitHubReleaseResolver : IReleaseResolver
{
    private static readonly TimeSpan RegexTimeout = TimeSpan.FromSeconds(2);
    private readonly IGitHubReleaseClient client;

    public GitHubReleaseResolver(IGitHubReleaseClient client)
    {
        ArgumentNullException.ThrowIfNull(client);
        this.client = client;
    }

    public bool CanResolve(MonitoredPackage package)
    {
        ArgumentNullException.ThrowIfNull(package);
        return package.Repo.Contains('/', StringComparison.Ordinal);
    }

    public async Task<ResolvedRelease?> ResolveAsync(
        MonitoredPackage package,
        CancellationToken cancellationToken
    )
    {
        ArgumentNullException.ThrowIfNull(package);

        (string owner, string repository) = SplitRepo(package.Repo);
        IReadOnlyList<GitHubRelease> releases = await client.GetReleasesAsync(
            owner,
            repository,
            cancellationToken
        );

        IEnumerable<GitHubRelease> candidates = releases.Where(release => !release.Draft);
        if (!string.IsNullOrWhiteSpace(package.TagPattern))
        {
            Regex pattern = new(package.TagPattern, RegexOptions.None, RegexTimeout);
            candidates = candidates.Where(release => pattern.IsMatch(release.TagName));
        }

        GitHubRelease? latest = candidates
            .OrderByDescending(release => release.PublishedAt ?? DateTimeOffset.MinValue)
            .FirstOrDefault();

        if (latest is null)
        {
            return null;
        }

        string version = TagPrefix.Strip(latest.TagName);
        // Best-effort ARP fallback; a dedicated ARP extractor is introduced in a later phase.
        UrlTemplateValues values = new(version, latest.TagName, version);
        IReadOnlyList<InstallerUrl> urls = UrlTemplateEngine.Expand(package.Url, values);
        return new ResolvedRelease(version, urls, latest.TagName);
    }

    private static (string Owner, string Repository) SplitRepo(string repo)
    {
        string[] parts = repo.Split('/', 2, StringSplitOptions.TrimEntries);
        if (parts.Length != 2 || parts[0].Length == 0 || parts[1].Length == 0)
        {
            throw new ArgumentException(
                $"Invalid GitHub repo '{repo}'; expected 'owner/name'.",
                nameof(repo)
            );
        }

        return (parts[0], parts[1]);
    }
}
