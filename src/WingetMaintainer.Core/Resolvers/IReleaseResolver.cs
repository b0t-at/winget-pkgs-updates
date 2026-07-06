using WingetMaintainer.Core.Configuration;

namespace WingetMaintainer.Core.Resolvers;

/// <summary>
/// Resolves the latest release (version + installer URLs) for a monitored package.
/// Implementations are tried in registration order via <see cref="ReleaseResolverRegistry"/>.
/// </summary>
public interface IReleaseResolver
{
    /// <summary>Returns <see langword="true"/> if this resolver handles the given package.</summary>
    bool CanResolve(MonitoredPackage package);

    /// <summary>Resolves the latest release, or <see langword="null"/> if none is available.</summary>
    Task<ResolvedRelease?> ResolveAsync(
        MonitoredPackage package,
        CancellationToken cancellationToken
    );
}
