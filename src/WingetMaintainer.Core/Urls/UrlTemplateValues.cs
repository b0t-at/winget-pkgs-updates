namespace WingetMaintainer.Core.Urls;

/// <summary>Values substituted into a URL template by <see cref="UrlTemplateEngine"/>.</summary>
/// <param name="Version">The winget package version (always required).</param>
/// <param name="Tag">The upstream release tag, used for the <c>{TAG}</c> placeholder.</param>
/// <param name="ArpVersion">The ARP/product version, used for the <c>{ARPVERSION}</c> placeholder.</param>
public sealed record UrlTemplateValues(string Version, string? Tag = null, string? ArpVersion = null);
