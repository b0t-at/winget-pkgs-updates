using WingetMaintainer.Dashboard;
using WingetMaintainer.Dashboard.Components;
using WingetMaintainer.Dashboard.Services;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

builder.Services
    .AddOptions<DashboardOptions>()
    .Bind(builder.Configuration.GetSection(DashboardOptions.SectionName));

DashboardOptions dashboardOptions =
    builder.Configuration.GetSection(DashboardOptions.SectionName).Get<DashboardOptions>() ?? new DashboardOptions();

builder.Services.AddHttpClient<WorkerClient>(client =>
{
    client.BaseAddress = new Uri(dashboardOptions.WorkerBaseUrl);
    if (!string.IsNullOrWhiteSpace(dashboardOptions.ApiKey))
    {
        client.DefaultRequestHeaders.Add("X-Api-Key", dashboardOptions.ApiKey);
    }
});

var app = builder.Build();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
    // The default HSTS value is 30 days. You may want to change this for production scenarios, see https://aka.ms/aspnetcore-hsts.
    app.UseHsts();
}

app.UseHttpsRedirection();

app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

app.Run();
