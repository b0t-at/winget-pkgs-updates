namespace WingetMaintainer.Core.Configuration;

/// <summary>
/// One entry from <c>github-releases-monitored.yml</c>. This is a configuration DTO
/// (mutable) so it can be bound by the YAML deserializer.
/// </summary>
public sealed class MonitoredPackage
{
    /// <summary>Winget package identifier, e.g. <c>Ollama.Ollama</c>.</summary>
    public string Id { get; set; } = string.Empty;

    /// <summary>GitHub <c>owner/name</c> the releases are polled from.</summary>
    public string Repo { get; set; } = string.Empty;

    /// <summary>
    /// Space-separated installer URL template(s). Supports the <c>{VERSION}</c>,
    /// <c>{TAG}</c> and <c>{ARPVERSION}</c> placeholders and an optional
    /// <c>|architecture</c> suffix per URL.
    /// </summary>
    public string Url { get; set; } = string.Empty;

    /// <summary>Optional regular expression used to filter candidate release tags.</summary>
    public string? TagPattern { get; set; }

    /// <summary>Optional tool override (<c>komac</c> or <c>wingetcreate</c>).</summary>
    public string? With { get; set; }
}
