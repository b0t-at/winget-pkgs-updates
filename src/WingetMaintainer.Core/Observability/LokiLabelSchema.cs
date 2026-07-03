namespace WingetMaintainer.Core.Observability;

/// <summary>
/// Loki label policy (decision D9): only a fixed set of LOW-cardinality labels are permitted.
/// High-cardinality values (package id, version, run id, manifest hash, error) MUST live in the
/// structured JSON log body and be queried via LogQL <c>| json</c> — never as labels.
/// </summary>
public static class LokiLabelSchema
{
    public const string App = "app";
    public const string Environment = "environment";
    public const string Phase = "phase";
    public const string Host = "host";
    public const string Level = "level";

    /// <summary>The only label keys allowed on Loki streams.</summary>
    public static readonly IReadOnlySet<string> AllowedLabels =
        new HashSet<string>(StringComparer.Ordinal) { App, Environment, Phase, Host, Level };

    /// <summary>Well-known high-cardinality fields that must never be used as labels.</summary>
    public static readonly IReadOnlySet<string> ForbiddenLabels =
        new HashSet<string>(StringComparer.Ordinal) { "package_id", "version", "run_id", "manifest_hash", "error" };

    /// <summary>Throws if any of the supplied label keys is not in <see cref="AllowedLabels"/>.</summary>
    public static void EnsureLowCardinality(IEnumerable<string> labelKeys)
    {
        ArgumentNullException.ThrowIfNull(labelKeys);

        foreach (string key in labelKeys)
        {
            if (!AllowedLabels.Contains(key))
            {
                throw new InvalidOperationException(
                    $"Loki label '{key}' is not permitted. Allowed labels: {string.Join(", ", AllowedLabels)}. " +
                    "High-cardinality values must go in the JSON log body, not labels (see decision D9).");
            }
        }
    }
}
