using WingetMaintainer.Core.Urls;

namespace WingetMaintainer.Core.Resolvers;

/// <summary>The outcome of resolving the latest release for a monitored package.</summary>
/// <param name="Version">The winget package version (tag with prefixes stripped).</param>
/// <param name="Urls">The expanded installer URLs.</param>
/// <param name="Tag">The raw upstream release tag, if applicable.</param>
/// <param name="ReleaseNotes">Optional release notes text.</param>
public sealed record ResolvedRelease(
    string Version,
    IReadOnlyList<InstallerUrl> Urls,
    string? Tag = null,
    string? ReleaseNotes = null);
