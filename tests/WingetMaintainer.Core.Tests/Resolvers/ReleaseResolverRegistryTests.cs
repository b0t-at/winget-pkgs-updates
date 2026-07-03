using FluentAssertions;
using WingetMaintainer.Core.Configuration;
using WingetMaintainer.Core.Resolvers;
using Xunit;

namespace WingetMaintainer.Core.Tests.Resolvers;

public sealed class ReleaseResolverRegistryTests
{
    private sealed class StubResolver(bool canResolve, string name) : IReleaseResolver
    {
        public string Name { get; } = name;

        public bool CanResolve(MonitoredPackage package) => canResolve;

        public Task<ResolvedRelease?> ResolveAsync(MonitoredPackage package, CancellationToken cancellationToken) =>
            Task.FromResult<ResolvedRelease?>(null);
    }

    [Fact]
    public void Find_ReturnsFirstMatchingResolverInOrder()
    {
        StubResolver first = new(canResolve: false, name: "first");
        StubResolver second = new(canResolve: true, name: "second");
        StubResolver third = new(canResolve: true, name: "third");
        ReleaseResolverRegistry registry = new([first, second, third]);

        IReleaseResolver? found = registry.Find(new MonitoredPackage { Id = "x", Repo = "o/r", Url = "u" });

        found.Should().BeSameAs(second);
    }

    [Fact]
    public void Find_NoMatch_ReturnsNull()
    {
        ReleaseResolverRegistry registry = new([new StubResolver(canResolve: false, name: "none")]);

        registry.Find(new MonitoredPackage { Id = "x", Repo = "o/r", Url = "u" }).Should().BeNull();
    }
}
