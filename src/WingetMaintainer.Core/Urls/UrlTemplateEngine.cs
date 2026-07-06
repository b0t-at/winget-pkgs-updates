namespace WingetMaintainer.Core.Urls;

/// <summary>
/// Expands the installer-URL mini-DSL used by the monitored-packages config. A template
/// is a whitespace-separated list of URLs; each URL may carry an optional
/// <c>|architecture</c> suffix and may contain the placeholders <c>{VERSION}</c>,
/// <c>{TAG}</c> and <c>{ARPVERSION}</c>.
/// </summary>
public static class UrlTemplateEngine
{
    private const string VersionToken = "{VERSION}";
    private const string TagToken = "{TAG}";
    private const string ArpVersionToken = "{ARPVERSION}";

    /// <summary>Expands a URL template into one or more concrete installer URLs.</summary>
    public static IReadOnlyList<InstallerUrl> Expand(string template, UrlTemplateValues values)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(template);
        ArgumentNullException.ThrowIfNull(values);

        string[] tokens = template.Split(
            ' ',
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries
        );

        List<InstallerUrl> results = new(tokens.Length);
        foreach (string token in tokens)
        {
            string urlPart = token;
            string? architecture = null;

            int pipeIndex = token.LastIndexOf('|');
            if (pipeIndex >= 0)
            {
                architecture = token[(pipeIndex + 1)..];
                urlPart = token[..pipeIndex];
            }

            string expanded = Substitute(urlPart, values);
            results.Add(
                new InstallerUrl(
                    expanded,
                    string.IsNullOrWhiteSpace(architecture) ? null : architecture
                )
            );
        }

        return results;
    }

    private static string Substitute(string url, UrlTemplateValues values)
    {
        string result = ReplaceToken(url, VersionToken, values.Version);
        result = ReplaceToken(result, TagToken, values.Tag);
        result = ReplaceToken(result, ArpVersionToken, values.ArpVersion);
        return result;
    }

    private static string ReplaceToken(string input, string token, string? value)
    {
        if (!input.Contains(token, StringComparison.Ordinal))
        {
            return input;
        }

        if (value is null)
        {
            throw new InvalidOperationException(
                $"URL template uses {token} but no value was supplied."
            );
        }

        return input.Replace(token, value, StringComparison.Ordinal);
    }
}
