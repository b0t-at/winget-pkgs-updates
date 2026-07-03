using System.Text.Json.Serialization;

namespace WingetMaintainer.Cli.Matrix;

/// <summary>One row of a GitHub Actions <c>matrix.include</c> entry.</summary>
internal sealed record MatrixRow
{
    [JsonPropertyName("id")]
    public required string Id { get; init; }

    [JsonPropertyName("repo")]
    public required string Repo { get; init; }

    [JsonPropertyName("url")]
    public required string Url { get; init; }

    [JsonPropertyName("tagPattern")]
    public string? TagPattern { get; init; }

    [JsonPropertyName("With")]
    public string? With { get; init; }
}

/// <summary>A GitHub Actions matrix document: <c>{ "include": [ ... ] }</c>.</summary>
internal sealed record MatrixDocument
{
    [JsonPropertyName("include")]
    public required IReadOnlyList<MatrixRow> Include { get; init; }
}
