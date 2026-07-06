using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace WingetMaintainer.Core.Notifications;

/// <summary>An ntfy notification payload (ported from <c>Send-NtfyNotification.ps1</c>).</summary>
public sealed record NtfyNotification
{
    public required string Topic { get; init; }

    public required string Title { get; init; }

    public required string Message { get; init; }

    /// <summary>Priority 1–5 (default 3).</summary>
    public int Priority { get; init; } = 3;

    public IReadOnlyList<string>? Tags { get; init; }

    public string? Click { get; init; }
}

/// <summary>Outcome of a notification send.</summary>
public sealed record NtfyResult(bool Success, string? Error);

/// <summary>Posts notifications to an ntfy server.</summary>
public sealed class NtfyClient
{
    private readonly HttpClient httpClient;

    public NtfyClient(HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        this.httpClient = httpClient;
    }

    public async Task<NtfyResult> SendAsync(
        string ntfyUrl,
        NtfyNotification notification,
        CancellationToken cancellationToken
    )
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ntfyUrl);
        ArgumentNullException.ThrowIfNull(notification);

        if (notification.Priority is < 1 or > 5)
        {
            throw new ArgumentOutOfRangeException(
                nameof(notification),
                notification.Priority,
                "Priority must be between 1 and 5."
            );
        }

        string endpoint = $"{ntfyUrl.TrimEnd('/')}/{notification.Topic}";

        NtfyRequestBody body = new()
        {
            Topic = notification.Topic,
            Title = notification.Title,
            Message = notification.Message,
            Priority = notification.Priority,
            Tags = notification.Tags is { Count: > 0 } tags ? tags : null,
            Click = string.IsNullOrWhiteSpace(notification.Click) ? null : notification.Click,
        };

        try
        {
            using HttpResponseMessage response = await httpClient
                .PostAsJsonAsync(endpoint, body, cancellationToken)
                .ConfigureAwait(false);

            if (!response.IsSuccessStatusCode)
            {
                return new NtfyResult(false, $"ntfy returned HTTP {(int)response.StatusCode}.");
            }

            return new NtfyResult(true, null);
        }
        catch (HttpRequestException exception)
        {
            return new NtfyResult(false, exception.Message);
        }
    }

    private sealed record NtfyRequestBody
    {
        [JsonPropertyName("topic")]
        public required string Topic { get; init; }

        [JsonPropertyName("title")]
        public required string Title { get; init; }

        [JsonPropertyName("message")]
        public required string Message { get; init; }

        [JsonPropertyName("priority")]
        public int Priority { get; init; }

        [JsonPropertyName("tags")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public IReadOnlyList<string>? Tags { get; init; }

        [JsonPropertyName("click")]
        [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
        public string? Click { get; init; }
    }
}
