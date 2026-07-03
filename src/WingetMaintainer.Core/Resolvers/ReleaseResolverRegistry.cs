using WingetMaintainer.Core.Configuration;

namespace WingetMaintainer.Core.Resolvers;

/// <summary>Selects the first registered <see cref="IReleaseResolver"/> that can handle a package.</summary>
public sealed class ReleaseResolverRegistry
{
    private readonly IReadOnlyList<IReleaseResolver> resolvers;

    public ReleaseResolverRegistry(IEnumerable<IReleaseResolver> resolvers)
    {
        ArgumentNullException.ThrowIfNull(resolvers);
        this.resolvers = resolvers.ToList();
    }

    /// <summary>Finds the resolver for a package, or <see langword="null"/> if none matches.</summary>
    public IReleaseResolver? Find(MonitoredPackage package)
    {
        ArgumentNullException.ThrowIfNull(package);
        foreach (IReleaseResolver resolver in resolvers)
        {
            if (resolver.CanResolve(package))
            {
                return resolver;
            }
        }

        return null;
    }
}
