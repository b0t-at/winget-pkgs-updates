using FluentAssertions;
using WingetMaintainer.Core.Manifests;
using Xunit;

namespace WingetMaintainer.Core.Tests.Manifests;

public sealed class ManifestHasherTests
{
    // Golden value produced by the legacy Get-ManifestHash.ps1 on the committed fixtures.
    // Fixtures are pinned to CRLF via `.gitattributes` (tests/**/Fixtures/** -text) so this is
    // byte-stable across platforms/checkouts.
    private const string GoldenHash =
        "36579E5C6E4F7F3529B5C3E421408FEA7E30EADC0CCE021D2FDE2443CDDF2F2C";

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
