using WingetMaintainer.Core.Process;

namespace WingetMaintainer.Core.Validation;

/// <summary>Inputs for a sandbox validation run.</summary>
public sealed record SandboxValidationOptions
{
    /// <summary>Path to <c>Test-Manifest-Sandbox.ps1</c>.</summary>
    public required string ScriptPath { get; init; }

    /// <summary>Local manifest folder to validate. Mutually exclusive with <see cref="ManifestUrl"/>.</summary>
    public string? ManifestPath { get; init; }

    /// <summary>Manifest URL to validate. Mutually exclusive with <see cref="ManifestPath"/>.</summary>
    public string? ManifestUrl { get; init; }

    /// <summary>PowerShell host executable (default <c>pwsh</c>).</summary>
    public string PowerShellExecutable { get; init; } = "pwsh";
}

/// <summary>
/// Wraps the existing <c>Test-Manifest-Sandbox.ps1</c> validator (decision D5: reuse the PS sandbox
/// script initially, port later). Command construction is unit-tested; actual sandbox execution
/// requires an interactive Windows session and is not exercised in CI.
/// </summary>
public sealed class SandboxValidationService
{
    private readonly IProcessRunner processRunner;

    public SandboxValidationService(IProcessRunner processRunner)
    {
        ArgumentNullException.ThrowIfNull(processRunner);
        this.processRunner = processRunner;
    }

    public static (string FileName, IReadOnlyList<string> Arguments) BuildCommand(
        SandboxValidationOptions options
    )
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.ScriptPath);

        bool hasPath = !string.IsNullOrWhiteSpace(options.ManifestPath);
        bool hasUrl = !string.IsNullOrWhiteSpace(options.ManifestUrl);

        if (hasPath == hasUrl)
        {
            throw new InvalidOperationException(
                "Exactly one of ManifestPath or ManifestUrl must be provided."
            );
        }

        List<string> arguments =
        [
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            options.ScriptPath,
        ];

        if (hasPath)
        {
            arguments.Add("-ManifestPath");
            arguments.Add(options.ManifestPath!);
        }
        else
        {
            arguments.Add("-ManifestURL");
            arguments.Add(options.ManifestUrl!);
        }

        return (options.PowerShellExecutable, arguments);
    }

    public async Task<ProcessResult> ValidateAsync(
        SandboxValidationOptions options,
        CancellationToken cancellationToken
    )
    {
        (string fileName, IReadOnlyList<string> arguments) = BuildCommand(options);
        return await processRunner
            .RunAsync(fileName, arguments, workingDirectory: null, cancellationToken)
            .ConfigureAwait(false);
    }
}
