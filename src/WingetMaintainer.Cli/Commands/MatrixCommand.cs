using System.CommandLine;
using System.Text.Json;
using System.Text.Json.Serialization;
using WingetMaintainer.Cli.Matrix;
using WingetMaintainer.Core.Configuration;

namespace WingetMaintainer.Cli.Commands;

/// <summary>
/// <c>matrix</c> — reads the monitored packages config and emits a GitHub Actions matrix
/// (JSON) that downstream jobs fan out over. Replaces the Python workflow generator.
/// </summary>
internal static class MatrixCommand
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false,
    };

    public static Command Create()
    {
        Option<FileInfo> configOption = new(
            "--config",
            () => new FileInfo("github-releases-monitored.yml"),
            "Path to the monitored packages YAML file."
        );
        configOption.AddAlias("-c");

        Option<bool> countOption = new("--count", "Print only the number of packages.");

        Command command = new(
            "matrix",
            "Emit a GitHub Actions matrix (JSON) from the monitored packages config."
        )
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
        IReadOnlyList<MonitoredPackage> packages = await loader.LoadAsync(
            config.FullName,
            CancellationToken.None
        );

        if (count)
        {
            Console.WriteLine(packages.Count);
            return;
        }

        MatrixDocument document = new()
        {
            Include = packages
                .Select(package => new MatrixRow
                {
                    Id = package.Id,
                    Repo = package.Repo,
                    Url = package.Url,
                    TagPattern = string.IsNullOrWhiteSpace(package.TagPattern)
                        ? null
                        : package.TagPattern,
                    With = string.IsNullOrWhiteSpace(package.With) ? null : package.With,
                })
                .ToList(),
        };

        Console.WriteLine(JsonSerializer.Serialize(document, JsonOptions));
    }
}
