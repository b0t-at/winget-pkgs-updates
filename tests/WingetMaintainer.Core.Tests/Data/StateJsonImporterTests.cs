using FluentAssertions;
using WingetMaintainer.Data;
using WingetMaintainer.Data.Entities;
using Xunit;

namespace WingetMaintainer.Core.Tests.Data;

public sealed class StateJsonImporterTests : IDisposable
{
    private readonly SqliteInMemory database = new();

    public void Dispose() => database.Dispose();

    private const string SampleJson =
        """
        {
          "stuncloud.uwscr": {
            "description": "",
            "manifestHash": "AAA",
            "state": "VALIDATION_FAILED",
            "installerHashes": [ "H1" ],
            "version": "1.1.9",
            "lastUpdated": "2026-05-11T15:42:46.9311925Z",
            "validationCount": 3
          },
          "SVGExplorerExtension.SVGExplorerExtension": {
            "lastUpdated": "2026-05-17T17:14:09.0079925Z",
            "version": "1.1.0",
            "state": "VALIDATION_FAILED",
            "validationCount": 2,
            "manifestHash": "BBB",
            "installerHashes": [ "H2", "H3" ],
            "description": "an ext"
          }
        }
        """;

    [Fact]
    public async Task ImportJsonAsync_ImportsAllEntriesWithFields()
    {
        int imported = await new StateJsonImporter(database.CreateContext())
            .ImportJsonAsync(SampleJson, CancellationToken.None);

        imported.Should().Be(2);

        using WingetMaintainerDbContext context = database.CreateContext();
        context.StateEntries.Should().HaveCount(2);

        StateEntry svg = context.StateEntries.Single(entry =>
            entry.PackageIdentifier == "SVGExplorerExtension.SVGExplorerExtension");
        svg.Version.Should().Be("1.1.0");
        svg.ManifestHash.Should().Be("BBB");
        svg.ValidationCount.Should().Be(2);
        svg.InstallerHashes.Should().Equal("H2", "H3");
        svg.Description.Should().Be("an ext");
    }

    [Fact]
    public async Task ImportJsonAsync_RerunUpdatesExistingEntries()
    {
        await new StateJsonImporter(database.CreateContext()).ImportJsonAsync(SampleJson, CancellationToken.None);
        await new StateJsonImporter(database.CreateContext()).ImportJsonAsync(SampleJson, CancellationToken.None);

        using WingetMaintainerDbContext context = database.CreateContext();
        context.StateEntries.Should().HaveCount(2);
    }

    [Fact]
    public async Task ImportJsonAsync_EmptyDocument_ImportsNothing()
    {
        int imported = await new StateJsonImporter(database.CreateContext())
            .ImportJsonAsync("{}", CancellationToken.None);

        imported.Should().Be(0);
    }
}
