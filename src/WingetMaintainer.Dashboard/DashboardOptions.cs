namespace WingetMaintainer.Dashboard;

/// <summary>Dashboard configuration (bound from the <c>Dashboard</c> section).</summary>
public sealed class DashboardOptions
{
    public const string SectionName = "Dashboard";

    /// <summary>Worker internal API base URL (must end with '/').</summary>
    public string WorkerBaseUrl { get; set; } = "http://localhost:5099/";

    /// <summary>API key sent as <c>X-Api-Key</c> to the Worker.</summary>
    public string? ApiKey { get; set; }

    /// <summary>Base URL of Grafana for embedded panels (optional).</summary>
    public string? GrafanaBaseUrl { get; set; }
}
