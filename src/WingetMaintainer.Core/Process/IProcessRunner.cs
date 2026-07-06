namespace WingetMaintainer.Core.Process;

/// <summary>Result of running an external process.</summary>
public sealed record ProcessResult(int ExitCode, string StandardOutput, string StandardError)
{
    public bool Succeeded => ExitCode == 0;
}

/// <summary>Abstraction over launching external CLI tools (komac, wingetcreate, pwsh).</summary>
public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        string? workingDirectory,
        CancellationToken cancellationToken
    );
}
