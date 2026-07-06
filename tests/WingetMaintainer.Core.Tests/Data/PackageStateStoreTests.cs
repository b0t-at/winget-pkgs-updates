using FluentAssertions;
using WingetMaintainer.Core.State;
using WingetMaintainer.Data;
using WingetMaintainer.Data.Entities;
using Xunit;

namespace WingetMaintainer.Core.Tests.Data;

public sealed class PackageStateStoreTests : IDisposable
{
    private readonly SqliteInMemory database = new();

    public void Dispose() => database.Dispose();

    private EfPackageStateStore CreateStore() => new(database.CreateContext());

    private static PackageStateUpdate Update(
        string state = PackageStates.ValidationFailed,
        string version = "1.0.0",
        string hash = "HASH-A"
    ) =>
        new()
        {
            PackageIdentifier = "Publisher.Product",
            Version = version,
            ManifestHash = hash,
            State = state,
            InstallerHashes = ["INSTALLER-1"],
            Description = "desc",
        };

    [Fact]
    public async Task SetAsync_NewPackage_CreatesEntryWithCountOne()
    {
        PackageState result = await CreateStore().SetAsync(Update(), CancellationToken.None);

        result.ValidationCount.Should().Be(1);
        result.InstallerHashes.Should().Equal("INSTALLER-1");

        PackageState? persisted = await CreateStore()
            .GetAsync("Publisher.Product", CancellationToken.None);
        persisted.Should().NotBeNull();
        persisted!.Version.Should().Be("1.0.0");
    }

    [Fact]
    public async Task SetAsync_SameVersionAndHash_IncrementsCount()
    {
        await CreateStore().SetAsync(Update(), CancellationToken.None);
        await CreateStore().SetAsync(Update(), CancellationToken.None);
        PackageState result = await CreateStore().SetAsync(Update(), CancellationToken.None);

        result.ValidationCount.Should().Be(3);
    }

    [Fact]
    public async Task SetAsync_DifferentVersion_ResetsCount()
    {
        await CreateStore().SetAsync(Update(version: "1.0.0"), CancellationToken.None);
        await CreateStore().SetAsync(Update(version: "1.0.0"), CancellationToken.None);

        PackageState result = await CreateStore()
            .SetAsync(Update(version: "2.0.0"), CancellationToken.None);

        result.ValidationCount.Should().Be(1);
        result.Version.Should().Be("2.0.0");
    }

    [Fact]
    public async Task SetAsync_DifferentHash_ResetsCount()
    {
        await CreateStore().SetAsync(Update(hash: "HASH-A"), CancellationToken.None);
        await CreateStore().SetAsync(Update(hash: "HASH-A"), CancellationToken.None);

        PackageState result = await CreateStore()
            .SetAsync(Update(hash: "HASH-B"), CancellationToken.None);

        result.ValidationCount.Should().Be(1);
    }

    [Theory]
    // matching failed entry at/over threshold -> skip
    [InlineData(PackageStates.ValidationFailed, "1.0.0", "HASH-A", 3, "1.0.0", "HASH-A", 3, true)]
    [InlineData(PackageStates.ValidationFailed, "1.0.0", "HASH-A", 4, "1.0.0", "HASH-A", 3, true)]
    // below threshold -> no skip
    [InlineData(PackageStates.ValidationFailed, "1.0.0", "HASH-A", 2, "1.0.0", "HASH-A", 3, false)]
    // passed state -> no skip
    [InlineData(PackageStates.ValidationPassed, "1.0.0", "HASH-A", 5, "1.0.0", "HASH-A", 3, false)]
    // version/hash mismatch -> no skip
    [InlineData(PackageStates.ValidationFailed, "1.0.0", "HASH-A", 5, "2.0.0", "HASH-A", 3, false)]
    [InlineData(PackageStates.ValidationFailed, "1.0.0", "HASH-A", 5, "1.0.0", "HASH-B", 3, false)]
    public async Task ShouldSkipAsync_MatchesLegacySemantics(
        string storedState,
        string storedVersion,
        string storedHash,
        int storedCount,
        string queryVersion,
        string queryHash,
        int maxFailures,
        bool expected
    )
    {
        using (WingetMaintainerDbContext seed = database.CreateContext())
        {
            seed.StateEntries.Add(
                new StateEntry
                {
                    PackageIdentifier = "Publisher.Product",
                    Version = storedVersion,
                    ManifestHash = storedHash,
                    State = storedState,
                    ValidationCount = storedCount,
                }
            );
            await seed.SaveChangesAsync(CancellationToken.None);
        }

        bool skip = await CreateStore()
            .ShouldSkipAsync(
                "Publisher.Product",
                queryVersion,
                queryHash,
                maxFailures,
                CancellationToken.None
            );

        skip.Should().Be(expected);
    }

    [Fact]
    public async Task ShouldSkipAsync_UnknownPackage_ReturnsFalse()
    {
        bool skip = await CreateStore()
            .ShouldSkipAsync(
                "Missing.Package",
                "1.0.0",
                "HASH",
                PackageStates.DefaultMaxFailures,
                CancellationToken.None
            );

        skip.Should().BeFalse();
    }
}
