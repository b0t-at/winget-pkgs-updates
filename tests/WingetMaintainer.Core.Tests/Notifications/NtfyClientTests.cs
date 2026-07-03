using System.Net;
using System.Text.Json;
using FluentAssertions;
using WingetMaintainer.Core.Notifications;
using Xunit;

namespace WingetMaintainer.Core.Tests.Notifications;

public sealed class NtfyClientTests
{
    private sealed class CapturingHandler(HttpStatusCode statusCode) : HttpMessageHandler
    {
        public Uri? RequestUri { get; private set; }

        public string? RequestBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestUri = request.RequestUri;
            RequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(statusCode);
        }
    }

    private static NtfyNotification Notification() => new()
    {
        Topic = "winget",
        Title = "Build failed",
        Message = "Contoso.App failed validation",
        Priority = 4,
        Tags = ["warning"],
    };

    [Fact]
    public async Task SendAsync_PostsToTopicEndpointWithExpectedBody()
    {
        CapturingHandler handler = new(HttpStatusCode.OK);
        NtfyClient client = new(new HttpClient(handler));

        NtfyResult result = await client.SendAsync("https://ntfy.sh/", Notification(), CancellationToken.None);

        result.Success.Should().BeTrue();
        handler.RequestUri.Should().Be(new Uri("https://ntfy.sh/winget"));

        using JsonDocument document = JsonDocument.Parse(handler.RequestBody!);
        JsonElement root = document.RootElement;
        root.GetProperty("topic").GetString().Should().Be("winget");
        root.GetProperty("title").GetString().Should().Be("Build failed");
        root.GetProperty("priority").GetInt32().Should().Be(4);
        root.GetProperty("tags").EnumerateArray().Select(tag => tag.GetString()).Should().Equal("warning");
    }

    [Fact]
    public async Task SendAsync_OmitsOptionalFieldsWhenNotSet()
    {
        CapturingHandler handler = new(HttpStatusCode.OK);
        NtfyClient client = new(new HttpClient(handler));
        NtfyNotification notification = new() { Topic = "t", Title = "x", Message = "y" };

        await client.SendAsync("https://ntfy.sh", notification, CancellationToken.None);

        using JsonDocument document = JsonDocument.Parse(handler.RequestBody!);
        document.RootElement.TryGetProperty("tags", out _).Should().BeFalse();
        document.RootElement.TryGetProperty("click", out _).Should().BeFalse();
    }

    [Fact]
    public async Task SendAsync_NonSuccessStatus_ReturnsError()
    {
        CapturingHandler handler = new(HttpStatusCode.InternalServerError);
        NtfyClient client = new(new HttpClient(handler));

        NtfyResult result = await client.SendAsync("https://ntfy.sh", Notification(), CancellationToken.None);

        result.Success.Should().BeFalse();
        result.Error.Should().Contain("500");
    }

    [Fact]
    public async Task SendAsync_InvalidPriority_Throws()
    {
        NtfyClient client = new(new HttpClient(new CapturingHandler(HttpStatusCode.OK)));
        NtfyNotification notification = new() { Topic = "t", Title = "x", Message = "y", Priority = 9 };

        Func<Task> act = () => client.SendAsync("https://ntfy.sh", notification, CancellationToken.None);

        await act.Should().ThrowAsync<ArgumentOutOfRangeException>();
    }
}
