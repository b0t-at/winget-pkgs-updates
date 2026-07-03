using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using WingetMaintainer.Data;

namespace WingetMaintainer.Core.Tests.Data;

/// <summary>
/// Owns an open in-memory SQLite connection so multiple <see cref="WingetMaintainerDbContext"/>
/// instances can share the same database within a test.
/// </summary>
internal sealed class SqliteInMemory : IDisposable
{
    private readonly SqliteConnection connection;
    private readonly DbContextOptions<WingetMaintainerDbContext> options;

    public SqliteInMemory()
    {
        connection = new SqliteConnection("Data Source=:memory:");
        connection.Open();
        options = new DbContextOptionsBuilder<WingetMaintainerDbContext>()
            .UseSqlite(connection)
            .Options;

        using WingetMaintainerDbContext context = CreateContext();
        context.Database.EnsureCreated();
    }

    public WingetMaintainerDbContext CreateContext() => new(options);

    public void Dispose() => connection.Dispose();
}
