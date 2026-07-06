using FluentAssertions;
using WingetMaintainer.Core.Configuration;
using Xunit;

namespace WingetMaintainer.Core.Tests.Configuration;

public sealed class MonitoredPackagesLoaderTests
{
    // Mirrors the real file's indented, quoted style.
    private const string SampleYaml = """
          - id: "1zilc.FishingFunds"
            repo: "1zilc/fishing-funds"
            url: "https://host/v{VERSION}/a.exe https://host/v{VERSION}/b.exe"
          - id: "AdaLang.Alire"
            repo: "alire-project/alire"
            url: "https://host/v{VERSION}/alr.exe"
            with: "wingetcreate"
          - id: "MullvadVPN.MullvadVPN"
            repo: "mullvad/mullvadvpn-app"
            url: "https://host/{VERSION}/m.exe"
            tagPattern: "^[0-9]"
        """;

    [Fact]
    public void Parse_ReadsAllEntriesAndOptionalFields()
    {
        MonitoredPackagesLoader loader = new();

        IReadOnlyList<MonitoredPackage> packages = loader.Parse(SampleYaml);

        packages.Should().HaveCount(3);
        packages
            .Select(package => package.Id)
            .Should()
            .Equal("1zilc.FishingFunds", "AdaLang.Alire", "MullvadVPN.MullvadVPN");

        packages[0].With.Should().BeNull();
        packages[0].Repo.Should().Be("1zilc/fishing-funds");

        packages[1].With.Should().Be("wingetcreate");
        packages[2].TagPattern.Should().Be("^[0-9]");
    }

    [Fact]
    public void Parse_EmptyDocument_ReturnsEmpty()
    {
        MonitoredPackagesLoader loader = new();

        IReadOnlyList<MonitoredPackage> packages = loader.Parse("[]");

        packages.Should().BeEmpty();
    }
}
