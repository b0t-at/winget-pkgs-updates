namespace WingetMaintainer.Data.Entities;

/// <summary>Catalog entry: a monitored package and how to resolve/build it.</summary>
public sealed class Package
{
    /// <summary>The winget PackageIdentifier (e.g. <c>Publisher.Product</c>).</summary>
    public string Id { get; set; } = string.Empty;

    public string Repo { get; set; } = string.Empty;

    public string Url { get; set; } = string.Empty;

    public string? TagPattern { get; set; }

    /// <summary>Submission tool override (<c>komac</c> or <c>wingetcreate</c>); null = default.</summary>
    public string? With { get; set; }
}
