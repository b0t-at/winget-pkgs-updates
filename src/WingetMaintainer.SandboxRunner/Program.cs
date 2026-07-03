using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Serilog;
using WingetMaintainer.Core.Observability;
using WingetMaintainer.Core.Process;
using WingetMaintainer.Core.Runner;
using WingetMaintainer.Core.Validation;
using WingetMaintainer.SandboxRunner;

HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);

builder.Services
    .AddOptions<RunnerOptions>()
    .Bind(builder.Configuration.GetSection(RunnerOptions.SectionName));

RunnerOptions options =
    builder.Configuration.GetSection(RunnerOptions.SectionName).Get<RunnerOptions>() ?? new RunnerOptions();

LoggingOptions loggingOptions = new()
{
    App = "winget-maintainer",
    Environment = options.Environment,
    Phase = "validate",
    LokiUri = string.IsNullOrWhiteSpace(options.LokiUri) ? null : new Uri(options.LokiUri),
    LokiUser = options.LokiUser,
    LokiPassword = options.LokiPassword,
};

Log.Logger = SerilogConfigurator.Configure(new LoggerConfiguration(), loggingOptions).CreateLogger();
builder.Services.AddSerilog();

builder.Services.AddHttpClient<IWorkerApiClient, WorkerApiClient>(client =>
{
    client.BaseAddress = new Uri(options.WorkerBaseUrl);
    if (!string.IsNullOrWhiteSpace(options.ApiKey))
    {
        client.DefaultRequestHeaders.Add("X-Api-Key", options.ApiKey);
    }
});

builder.Services.AddSingleton<IProcessRunner, ProcessRunner>();
builder.Services.AddSingleton<SandboxValidationService>();
builder.Services.AddHostedService<SandboxRunnerService>();

IHost host = builder.Build();
host.Run();
