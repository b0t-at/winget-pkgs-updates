using System.Net;
using System.Text;
using System.Text.Json;
using FluentAssertions;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Core.Runner;
using Xunit;

namespace WingetMaintainer.Core.Tests.Runner;

public sealed class WorkerApiClientTests
{
    private sealed class StubHandler(HttpStatusCode statusCode, string? json) : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }

        public string? LastRequestBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            LastRequest = request;
            LastRequestBody = request.Content is null
                ? null
                : await request.Content.ReadAsStringAsync(cancellationToken);

            HttpResponseMessage response = new(statusCode);
            if (json is not null)
            {
                response.Content = new StringContent(json, Encoding.UTF8, "application/json");
            }

            return response;
        }
    }

    private static HttpClient Client(StubHandler handler) =>
        new(handler) { BaseAddress = new Uri("http://localhost:5099/") };

    [Fact]
    public async Task GetNextJobAsync_ParsesJobFromCamelCaseJson()
    {
        const string json = """
            { "id": 7, "packageRunId": 3, "packageId": "Contoso.App", "manifestPath": "C:/m/1", "attempts": 1 }
            """;
        StubHandler handler = new(HttpStatusCode.OK, json);
        WorkerApiClient client = new(Client(handler));

        QueuedJob? job = await client.GetNextJobAsync("runner-1", CancellationToken.None);

        job.Should().NotBeNull();
        job!.Id.Should().Be(7);
        job.PackageId.Should().Be("Contoso.App");
        job.ManifestPath.Should().Be("C:/m/1");
        handler.LastRequest!.RequestUri!.PathAndQuery.Should().Be("/api/jobs/next?host=runner-1");
    }

    [Fact]
    public async Task GetNextJobAsync_NoContent_ReturnsNull()
    {
        StubHandler handler = new(HttpStatusCode.NoContent, null);
        WorkerApiClient client = new(Client(handler));

        QueuedJob? job = await client.GetNextJobAsync("runner-1", CancellationToken.None);

        job.Should().BeNull();
    }

    [Fact]
    public async Task ReportResultAsync_PostsToResultEndpoint()
    {
        StubHandler handler = new(HttpStatusCode.OK, null);
        WorkerApiClient client = new(Client(handler));
        JobResult result = new() { JobId = 42, Status = ValidationStatus.Passed, Host = "runner-1", ExitCode = 0 };

        await client.ReportResultAsync(result, CancellationToken.None);

        handler.LastRequest!.Method.Should().Be(HttpMethod.Post);
        handler.LastRequest.RequestUri!.PathAndQuery.Should().Be("/api/jobs/42/result");

        using JsonDocument document = JsonDocument.Parse(handler.LastRequestBody!);
        document.RootElement.GetProperty("status").GetString().Should().Be(ValidationStatus.Passed);
    }
}
