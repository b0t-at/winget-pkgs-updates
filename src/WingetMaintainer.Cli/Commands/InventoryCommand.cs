using System.CommandLine;
using System.Text.Json;
using System.Text.Json.Serialization;
using WingetMaintainer.Core.Configuration;

namespace WingetMaintainer.Cli.Commands;

/// <summary>
/// <c>inventory</c> — summarises the monitored packages catalog (totals, tool split,
/// first-letter distribution). Intended to feed the Grafana catalog dashboard.
/// </summary>
internal static class InventoryCommand
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
    };

    public static Command Create()
    {
        Option<FileInfo> configOption = new(
            "--config",
            () => new FileInfo("github-releases-monitored.yml"),
            "Path to the monitored packages YAML file.");
        configOption.AddAlias("-c");

        Option<bool> countOption = new("--count", "Print only the total number of packages.");

        Command command = new("inventory", "Summarise the monitored packages catalog (JSON).")
        {
            configOption,
            countOption,
        };

        command.SetHandler(RunAsync, configOption, countOption);
        return command;
    }

    private static async Task RunAsync(FileInfo config, bool count)
    {
        MonitoredPackagesLoader loader = new();
        IReadOnlyList<MonitoredPackage> packages = await loader.LoadAsync(config.FullName, CancellationToken.None);

        if (count)
        {
            Console.WriteLine(packages.Count);
            return;
        }

        Dictionary<string, int> byTool = packages
            .GroupBy(package => string.IsNullOrWhiteSpace(package.With)
                ? "default"
                : package.With.ToLowerInvariant())
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count());

        Dictionary<string, int> byFirstLetter = packages
            .GroupBy(package => (package.Id.Length > 0 ? char.ToLowerInvariant(package.Id[0]) : '?').ToString())
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count());

        InventorySummary summary = new()
        {
            Total = packages.Count,
            ByTool = byTool,
            ByFirstLetter = byFirstLetter,
        };

        Console.WriteLine(JsonSerializer.Serialize(summary, JsonOptions));
    }

    private sealed record InventorySummary
    {
        [JsonPropertyName("total")]
        public required int Total { get; init; }

        [JsonPropertyName("byTool")]
        public required IReadOnlyDictionary<string, int> ByTool { get; init; }

        [JsonPropertyName("byFirstLetter")]
        public required IReadOnlyDictionary<string, int> ByFirstLetter { get; init; }
    }
}
