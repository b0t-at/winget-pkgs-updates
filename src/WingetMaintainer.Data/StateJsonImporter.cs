using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.EntityFrameworkCore;
using WingetMaintainer.Data.Entities;

namespace WingetMaintainer.Data;

/// <summary>
/// Imports the legacy <c>data/package-state.json</c> (a map of PackageIdentifier → entry) into the
/// <see cref="StateEntry"/> table, preserving version/hash/state/count/installerHashes fields.
/// </summary>
public sealed class StateJsonImporter
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    private readonly WingetMaintainerDbContext dbContext;

    public StateJsonImporter(WingetMaintainerDbContext dbContext)
    {
        ArgumentNullException.ThrowIfNull(dbContext);
        this.dbContext = dbContext;
    }

    /// <summary>Imports from a file path. Returns the number of entries imported.</summary>
    public async Task<int> ImportAsync(string jsonPath, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(jsonPath);
        string json = await File.ReadAllTextAsync(jsonPath, cancellationToken)
            .ConfigureAwait(false);
        return await ImportJsonAsync(json, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Imports from a JSON string. Returns the number of entries imported.</summary>
    public async Task<int> ImportJsonAsync(string json, CancellationToken cancellationToken)
    {
        Dictionary<string, StateJsonEntry>? entries = JsonSerializer.Deserialize<
            Dictionary<string, StateJsonEntry>
        >(json, JsonOptions);

        if (entries is null || entries.Count == 0)
        {
            return 0;
        }

        foreach ((string packageIdentifier, StateJsonEntry source) in entries)
        {
            StateEntry? entry = await dbContext
                .StateEntries.FindAsync([packageIdentifier], cancellationToken)
                .ConfigureAwait(false);

            if (entry is null)
            {
                entry = new StateEntry { PackageIdentifier = packageIdentifier };
                dbContext.StateEntries.Add(entry);
            }

            entry.Version = source.Version;
            entry.ManifestHash = source.ManifestHash;
            entry.State = source.State;
            entry.ValidationCount = source.ValidationCount;
            entry.InstallerHashes = source.InstallerHashes.ToList();
            entry.Description = source.Description;
            entry.LastUpdated = source.LastUpdated;
        }

        await dbContext.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
        return entries.Count;
    }

    private sealed record StateJsonEntry
    {
        [JsonPropertyName("version")]
        public string Version { get; init; } = string.Empty;

        [JsonPropertyName("manifestHash")]
        public string ManifestHash { get; init; } = string.Empty;

        [JsonPropertyName("state")]
        public string State { get; init; } = string.Empty;

        [JsonPropertyName("validationCount")]
        public int ValidationCount { get; init; }

        [JsonPropertyName("installerHashes")]
        public List<string> InstallerHashes { get; init; } = [];

        [JsonPropertyName("description")]
        public string Description { get; init; } = string.Empty;

        [JsonPropertyName("lastUpdated")]
        public DateTimeOffset LastUpdated { get; init; }
    }
}
