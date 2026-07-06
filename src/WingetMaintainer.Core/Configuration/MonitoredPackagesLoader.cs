using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace WingetMaintainer.Core.Configuration;

/// <summary>
/// Loads the monitored-packages configuration (<c>github-releases-monitored.yml</c>),
/// which is a YAML sequence of <see cref="MonitoredPackage"/> entries.
/// </summary>
public sealed class MonitoredPackagesLoader
{
    private static readonly IDeserializer Deserializer = new DeserializerBuilder()
        .WithNamingConvention(CamelCaseNamingConvention.Instance)
        .IgnoreUnmatchedProperties()
        .Build();

    /// <summary>Parses monitored packages from a YAML string.</summary>
    public IReadOnlyList<MonitoredPackage> Parse(string yaml)
    {
        ArgumentNullException.ThrowIfNull(yaml);
        List<MonitoredPackage>? packages = Deserializer.Deserialize<List<MonitoredPackage>>(yaml);
        return packages ?? [];
    }

    /// <summary>Loads and parses monitored packages from a YAML file.</summary>
    public async Task<IReadOnlyList<MonitoredPackage>> LoadAsync(
        string path,
        CancellationToken cancellationToken
    )
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Monitored packages file not found: {path}", path);
        }

        string yaml = await File.ReadAllTextAsync(path, cancellationToken);
        return Parse(yaml);
    }
}
