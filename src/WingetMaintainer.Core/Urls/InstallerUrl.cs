namespace WingetMaintainer.Core.Urls;

/// <summary>A resolved installer URL and its optional winget architecture (e.g. x86/x64/arm64).</summary>
public sealed record InstallerUrl(string Url, string? Architecture);
