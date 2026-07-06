using System.CommandLine;
using System.Text.Json;
using WingetMaintainer.Core.Manifests;

namespace WingetMaintainer.Cli.Commands;

/// <summary><c>hash</c> — compute the manifest fingerprint + installer hashes for a manifest folder.</summary>
internal static class HashCommand
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    public static Command Create()
    {
        Option<DirectoryInfo> pathOption = new("--path", "Path to the manifest folder.")
        {
            IsRequired = true,
        };
        pathOption.AddAlias("-p");

        Command command = new(
            "hash",
            "Compute the SHA-256 manifest hash and installer hashes for a folder."
        )
        {
            pathOption,
        };

        command.SetHandler(Run, pathOption);
        return command;
    }

    private static void Run(DirectoryInfo path)
    {
        ManifestHashResult result = ManifestHasher.ComputeFromDirectory(path.FullName);
        Console.WriteLine(
            JsonSerializer.Serialize(
                new { result.ManifestHash, result.InstallerHashes },
                JsonOptions
            )
        );
    }
}
