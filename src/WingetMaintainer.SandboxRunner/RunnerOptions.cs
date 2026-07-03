namespace WingetMaintainer.SandboxRunner;

/// <summary>SandboxRunner configuration (bound from the <c>Runner</c> section).</summary>
public sealed class RunnerOptions
{
    public const string SectionName = "Runner";

    /// <summary>Base URL of the Worker internal API (must end with '/').</summary>
    public string WorkerBaseUrl { get; set; } = "http://localhost:5099/";

    /// <summary>API key sent as the <c>X-Api-Key</c> header (decision D15).</summary>
    public string? ApiKey { get; set; }

    /// <summary>Host label reported with claimed jobs (defaults to the machine name).</summary>
    public string Host { get; set; } = System.Environment.MachineName;

    /// <summary>Path to <c>Test-Manifest-Sandbox.ps1</c>.</summary>
    public string ScriptPath { get; set; } = "scripts/validation/Test-Manifest-Sandbox.ps1";

    /// <summary>Idle poll interval when the queue is empty.</summary>
    public int PollIntervalSeconds { get; set; } = 15;

    /// <summary>Per-job timeout (decision T6.4: 30 minutes).</summary>
    public int TimeoutMinutes { get; set; } = 30;

    public string Environment { get; set; } = "Production";

    public string? LokiUri { get; set; }

    public string? LokiUser { get; set; }

    public string? LokiPassword { get; set; }
}
