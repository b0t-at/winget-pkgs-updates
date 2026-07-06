using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace WingetMaintainer.Data;

/// <summary>
/// Design-time factory so <c>dotnet ef</c> can create/apply migrations without a running host.
/// </summary>
public sealed class WingetMaintainerDbContextFactory
    : IDesignTimeDbContextFactory<WingetMaintainerDbContext>
{
    public WingetMaintainerDbContext CreateDbContext(string[] args)
    {
        DbContextOptionsBuilder<WingetMaintainerDbContext> builder = new();
        builder.UseSqlite("Data Source=winget-maintainer.db");
        return new WingetMaintainerDbContext(builder.Options);
    }
}
