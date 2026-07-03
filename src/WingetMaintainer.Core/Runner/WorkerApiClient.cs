using System.Net;
using System.Net.Http.Json;
using WingetMaintainer.Core.Queue;

namespace WingetMaintainer.Core.Runner;

/// <summary>Client the SandboxRunner uses to poll the Worker's internal queue API.</summary>
public interface IWorkerApiClient
{
    /// <summary>Claims the next pending job, or returns null when the queue is empty.</summary>
    Task<QueuedJob?> GetNextJobAsync(string host, CancellationToken cancellationToken);

    /// <summary>Reports a terminal result for a job.</summary>
    Task ReportResultAsync(JobResult result, CancellationToken cancellationToken);
}

/// <summary>
/// HTTP implementation of <see cref="IWorkerApiClient"/>. The <see cref="HttpClient"/> is expected to
/// carry the Worker base address and the <c>X-Api-Key</c> default header (configured at composition).
/// </summary>
public sealed class WorkerApiClient : IWorkerApiClient
{
    private readonly HttpClient httpClient;

    public WorkerApiClient(HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        this.httpClient = httpClient;
    }

    public async Task<QueuedJob?> GetNextJobAsync(string host, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(host);

        using HttpResponseMessage response = await httpClient
            .GetAsync($"api/jobs/next?host={Uri.EscapeDataString(host)}", cancellationToken)
            .ConfigureAwait(false);

        if (response.StatusCode == HttpStatusCode.NoContent)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content
            .ReadFromJsonAsync<QueuedJob>(cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task ReportResultAsync(JobResult result, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(result);

        using HttpResponseMessage response = await httpClient
            .PostAsJsonAsync($"api/jobs/{result.JobId}/result", result, cancellationToken)
            .ConfigureAwait(false);

        response.EnsureSuccessStatusCode();
    }
}
