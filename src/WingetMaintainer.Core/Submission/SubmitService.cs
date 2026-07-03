using WingetMaintainer.Core.Process;

namespace WingetMaintainer.Core.Submission;

/// <summary>Submission tool selection.</summary>
public enum SubmissionTool
{
    Komac,
    WinGetCreate,
}

/// <summary>Inputs for submitting a manifest as a winget-pkgs pull request.</summary>
public sealed record SubmitOptions
{
    public required string ManifestPath { get; init; }

    public required string PackageId { get; init; }

    public required string Version { get; init; }

    public required string Token { get; init; }

    public SubmissionTool Tool { get; init; } = SubmissionTool.Komac;

    public string? PrTitle { get; init; }

    /// <summary>Issue number this PR resolves (komac <c>--resolves</c>).</summary>
    public string? Resolves { get; init; }
}

/// <summary>
/// Submits a manifest as a pull request via komac or wingetcreate (ported from
/// <c>Submit-WingetPackage.ps1</c>). Command construction is unit-tested; live submission requires
/// the tools, a token, and network access (not exercised in CI).
/// </summary>
public sealed class SubmitService
{
    private readonly IProcessRunner processRunner;

    public SubmitService(IProcessRunner processRunner)
    {
        ArgumentNullException.ThrowIfNull(processRunner);
        this.processRunner = processRunner;
    }

    /// <summary>Builds the CLI executable + argument list for the selected tool.</summary>
    public static (string FileName, IReadOnlyList<string> Arguments) BuildCommand(SubmitOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.ManifestPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.Token);

        string prTitle = string.IsNullOrWhiteSpace(options.PrTitle)
            ? $"Update version: {options.PackageId} version {options.Version}"
            : options.PrTitle;

        return options.Tool switch
        {
            SubmissionTool.Komac => BuildKomac(options),
            SubmissionTool.WinGetCreate => BuildWinGetCreate(options, prTitle),
            _ => throw new ArgumentOutOfRangeException(nameof(options), options.Tool, "Unknown submission tool."),
        };
    }

    public async Task<ProcessResult> SubmitAsync(SubmitOptions options, CancellationToken cancellationToken)
    {
        (string fileName, IReadOnlyList<string> arguments) = BuildCommand(options);
        return await processRunner
            .RunAsync(fileName, arguments, workingDirectory: null, cancellationToken)
            .ConfigureAwait(false);
    }

    private static (string, IReadOnlyList<string>) BuildKomac(SubmitOptions options)
    {
        List<string> arguments =
        [
            "submit",
            options.ManifestPath,
            "--yes",
            "--token",
            options.Token,
        ];

        if (!string.IsNullOrWhiteSpace(options.Resolves))
        {
            arguments.Add("--resolves");
            arguments.Add(options.Resolves);
        }

        return ("komac", arguments);
    }

    private static (string, IReadOnlyList<string>) BuildWinGetCreate(SubmitOptions options, string prTitle)
    {
        List<string> arguments =
        [
            "submit",
            "--prtitle",
            prTitle,
            "-t",
            options.Token,
            options.ManifestPath,
        ];

        return ("wingetcreate", arguments);
    }
}
