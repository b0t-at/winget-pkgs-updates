using System.CommandLine;
using WingetMaintainer.Core.Process;
using WingetMaintainer.Core.Submission;

namespace WingetMaintainer.Cli.Commands;

/// <summary><c>submit</c> — submit a manifest as a winget-pkgs pull request via komac/wingetcreate.</summary>
internal static class SubmitCommand
{
    public static Command Create()
    {
        Option<DirectoryInfo> pathOption = new("--path", "Manifest folder to submit.")
        {
            IsRequired = true,
        };
        pathOption.AddAlias("-p");
        Option<string> idOption = new("--id", "PackageIdentifier.") { IsRequired = true };
        Option<string> versionOption = new("--version", "Package version.") { IsRequired = true };
        Option<SubmissionTool> toolOption = new(
            "--tool",
            () => SubmissionTool.Komac,
            "Submission tool."
        );
        Option<string?> tokenOption = new(
            "--token",
            "GitHub token (falls back to GITHUB_TOKEN or WINGET_PAT)."
        );
        Option<string?> resolvesOption = new(
            "--resolves",
            "Issue number this PR resolves (komac)."
        );
        Option<string?> prTitleOption = new("--pr-title", "Custom pull-request title.");

        Command command = new("submit", "Submit a manifest folder as a winget-pkgs pull request.")
        {
            pathOption,
            idOption,
            versionOption,
            toolOption,
            tokenOption,
            resolvesOption,
            prTitleOption,
        };

        command.SetHandler(
            async (context) =>
            {
                DirectoryInfo path = context.ParseResult.GetValueForOption(pathOption)!;
                string id = context.ParseResult.GetValueForOption(idOption)!;
                string version = context.ParseResult.GetValueForOption(versionOption)!;
                SubmissionTool tool = context.ParseResult.GetValueForOption(toolOption);
                string? token = context.ParseResult.GetValueForOption(tokenOption);
                string? resolves = context.ParseResult.GetValueForOption(resolvesOption);
                string? prTitle = context.ParseResult.GetValueForOption(prTitleOption);

                token = ResolveToken(token);
                if (string.IsNullOrWhiteSpace(token))
                {
                    await Console.Error.WriteLineAsync(
                        "No GitHub token provided. Pass --token or set GITHUB_TOKEN / WINGET_PAT."
                    );
                    context.ExitCode = 1;
                    return;
                }

                SubmitOptions options = new()
                {
                    ManifestPath = path.FullName,
                    PackageId = id,
                    Version = version,
                    Token = token,
                    Tool = tool,
                    Resolves = resolves,
                    PrTitle = prTitle,
                };

                SubmitService service = new(new ProcessRunner());
                ProcessResult result = await service.SubmitAsync(
                    options,
                    context.GetCancellationToken()
                );

                if (result.StandardOutput.Length > 0)
                {
                    Console.WriteLine(result.StandardOutput);
                }

                if (!result.Succeeded)
                {
                    await Console.Error.WriteLineAsync(result.StandardError);
                    context.ExitCode = result.ExitCode == 0 ? 1 : result.ExitCode;
                }
            }
        );

        return command;
    }

    private static string? ResolveToken(string? token)
    {
        if (!string.IsNullOrWhiteSpace(token))
        {
            return token;
        }

        string? fromEnv = Environment.GetEnvironmentVariable("GITHUB_TOKEN");
        return string.IsNullOrWhiteSpace(fromEnv)
            ? Environment.GetEnvironmentVariable("WINGET_PAT")
            : fromEnv;
    }
}
