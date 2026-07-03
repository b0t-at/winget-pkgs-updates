using System.Net;
using System.Net.Http.Json;
using WingetMaintainer.Dashboard.Models;

namespace WingetMaintainer.Dashboard.Services;

/// <summary>Typed client for the Worker internal API (consumed by the Blazor dashboard).</summary>
public sealed class WorkerClient
{
    private readonly HttpClient httpClient;

    public WorkerClient(HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(httpClient);
        this.httpClient = httpClient;
    }

    public async Task<IReadOnlyList<RunDto>> GetRunsAsync(CancellationToken cancellationToken)
    {
        List<RunDto>? runs = await httpClient
            .GetFromJsonAsync<List<RunDto>>("api/runs", cancellationToken)
            .ConfigureAwait(false);
        return runs ?? [];
    }

    public async Task<PackageStateDto?> GetStateAsync(string packageId, CancellationToken cancellationToken)
    {
        using HttpResponseMessage response = await httpClient
            .GetAsync($"api/state/{Uri.EscapeDataString(packageId)}", cancellationToken)
            .ConfigureAwait(false);

        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content
            .ReadFromJsonAsync<PackageStateDto>(cancellationToken)
            .ConfigureAwait(false);
    }
}
