namespace WingetMaintainer.Core.Versioning;

/// <summary>
/// Strips common GitHub tag prefixes (port of the legacy <c>Remove-GHTagPrefixes</c>)
/// so a release tag like <c>v1.2.3</c> or <c>release-1.2.3</c> becomes <c>1.2.3</c>.
/// </summary>
public static class TagPrefix
{
    private static readonly string[] TextualPrefixes =
    [
        "releases-",
        "release-",
        "rel-",
        "version-",
        "ver-",
    ];

    /// <summary>Removes known leading prefixes from a release tag.</summary>
    public static string Strip(string tag)
    {
        ArgumentNullException.ThrowIfNull(tag);
        string trimmed = tag.Trim();

        foreach (string prefix in TextualPrefixes)
        {
            if (trimmed.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                trimmed = trimmed[prefix.Length..];
                break;
            }
        }

        // Leading "v"/"V" immediately followed by a digit (v1.2.3 -> 1.2.3).
        if (
            trimmed.Length >= 2
            && (trimmed[0] == 'v' || trimmed[0] == 'V')
            && char.IsDigit(trimmed[1])
        )
        {
            trimmed = trimmed[1..];
        }

        return trimmed;
    }
}
