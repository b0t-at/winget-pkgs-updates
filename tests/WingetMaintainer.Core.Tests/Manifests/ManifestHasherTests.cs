using FluentAssertions;
using WingetMaintainer.Core.Manifests;
using Xunit;

namespace WingetMaintainer.Core.Tests.Manifests;

public sealed class ManifestHasherTests
{
    // Golden value produced by the legacy Get-ManifestHash.ps1 on the committed fixtures.
    private const string GoldenHash =
        "6D6213A5C1D122CFBCA69B15C99641AB6ED129895AAA6FDAA7C6042361CD3210";

    private static string FixtureDirectory =>
        Path.Combine(AppContext.BaseDirectory, "Fixtures", "Manifests", "Contoso.App", "1.0.0");

    [Fact]
    public void ComputeFromDirectory_MatchesLegacyPowerShellHash()
    {
        ManifestHashResult result = ManifestHasher.ComputeFromDirectory(FixtureDirectory);

        result.ManifestHash.Should().Be(GoldenHash);
    }

    [Fact]
    public void ComputeFromDirectory_ExtractsDistinctInstallerHashesInOrder()
    {
        ManifestHashResult result = ManifestHasher.ComputeFromDirectory(FixtureDirectory);

        result
            .InstallerHashes.Should()
            .Equal(
                "1111111111111111111111111111111111111111111111111111111111111111",
                "2222222222222222222222222222222222222222222222222222222222222222"
            );
    }

    [Fact]
    public void ComputeFromDirectory_EmptyDirectory_Throws()
    {
        string empty = Path.Combine(Path.GetTempPath(), "wm-empty-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(empty);
        try
        {
            Action act = () => ManifestHasher.ComputeFromDirectory(empty);
            act.Should().Throw<InvalidOperationException>();
        }
        finally
        {
            Directory.Delete(empty, recursive: true);
        }
    }

    [Fact]
    public void ComputeFromDirectory_MissingDirectory_Throws()
    {
        Action act = () =>
            ManifestHasher.ComputeFromDirectory(
                Path.Combine(Path.GetTempPath(), "wm-missing-" + Guid.NewGuid().ToString("N"))
            );

        act.Should().Throw<DirectoryNotFoundException>();
    }
}
