namespace WingetMaintainer.Core.Observability;

/// <summary>
/// Structured log body field names (high-cardinality). These are emitted as JSON properties, never
/// as Loki labels (see <see cref="LokiLabelSchema"/> / decision D9).
/// </summary>
public static class LogFields
{
    public const string Event = "event";
    public const string PackageId = "package_id";
    public const string Version = "version";
    public const string RunId = "run_id";
    public const string ManifestHash = "manifest_hash";
    public const string Error = "error";
}
