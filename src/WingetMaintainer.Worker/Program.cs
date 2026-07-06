using Microsoft.EntityFrameworkCore;
using Serilog;
using WingetMaintainer.Core.Observability;
using WingetMaintainer.Core.Queue;
using WingetMaintainer.Core.Security;
using WingetMaintainer.Core.State;
using WingetMaintainer.Data;
using WingetMaintainer.Worker;

WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder
    .Services.AddOptions<WorkerOptions>()
    .Bind(builder.Configuration.GetSection(WorkerOptions.SectionName));

WorkerOptions options =
    builder.Configuration.GetSection(WorkerOptions.SectionName).Get<WorkerOptions>()
    ?? new WorkerOptions();

LoggingOptions loggingOptions = new()
{
    App = "winget-maintainer",
    Environment = options.Environment,
    Phase = "worker",
    LokiUri = string.IsNullOrWhiteSpace(options.LokiUri) ? null : new Uri(options.LokiUri),
    LokiUser = options.LokiUser,
    LokiPassword = options.LokiPassword,
};

Log.Logger = SerilogConfigurator
    .Configure(new LoggerConfiguration(), loggingOptions)
    .CreateLogger();
builder.Host.UseSerilog();

builder.Services.AddDbContext<WingetMaintainerDbContext>(dbOptions =>
    dbOptions.UseSqlite($"Data Source={options.DatabasePath}")
);
builder.Services.AddScoped<IPackageStateStore, EfPackageStateStore>();
builder.Services.AddScoped<IValidationQueue, ValidationQueue>();
builder.Services.AddHostedService<SchedulerService>();

WebApplication app = builder.Build();

using (IServiceScope scope = app.Services.CreateScope())
{
    scope.ServiceProvider.GetRequiredService<WingetMaintainerDbContext>().Database.Migrate();
}

// Internal API guard: every /api request requires a valid X-Api-Key (decision D15).
app.Use(
    async (context, next) =>
    {
        if (context.Request.Path.StartsWithSegments("/api"))
        {
            string? providedKey = context.Request.Headers["X-Api-Key"];
            if (!ApiKeyValidator.IsAuthorized(providedKey, options.ApiKey))
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }
        }

        await next();
    }
);

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet(
    "/api/jobs/next",
    async (string host, IValidationQueue queue, CancellationToken cancellationToken) =>
    {
        QueuedJob? job = await queue.DequeueNextAsync(host, cancellationToken);
        return job is null ? Results.NoContent() : Results.Ok(job);
    }
);

app.MapPost(
    "/api/jobs/{id:int}/result",
    async (int id, JobResult result, IValidationQueue queue, CancellationToken cancellationToken) =>
    {
        await queue.CompleteAsync(result with { JobId = id }, cancellationToken);
        return Results.Ok();
    }
);

app.MapGet(
    "/api/runs",
    async (WingetMaintainerDbContext dbContext, CancellationToken cancellationToken) =>
        Results.Ok(
            await dbContext
                .PackageRuns.OrderByDescending(run => run.Id)
                .Take(50)
                .ToListAsync(cancellationToken)
        )
);

app.MapGet(
    "/api/state/{id}",
    async (string id, IPackageStateStore store, CancellationToken cancellationToken) =>
    {
        PackageState? state = await store.GetAsync(id, cancellationToken);
        return state is null ? Results.NotFound() : Results.Ok(state);
    }
);

app.Run();
