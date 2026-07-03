using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.ChangeTracking;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;
using WingetMaintainer.Data.Entities;

namespace WingetMaintainer.Data;

/// <summary>EF Core context for the winget-maintainer store (SQLite).</summary>
public sealed class WingetMaintainerDbContext : DbContext
{
    private static readonly JsonSerializerOptions JsonOptions = new();

    public WingetMaintainerDbContext(DbContextOptions<WingetMaintainerDbContext> options)
        : base(options)
    {
    }

    public DbSet<Package> Packages => Set<Package>();

    public DbSet<StateEntry> StateEntries => Set<StateEntry>();

    public DbSet<PackageRun> PackageRuns => Set<PackageRun>();

    public DbSet<ValidationJob> ValidationJobs => Set<ValidationJob>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        ArgumentNullException.ThrowIfNull(modelBuilder);

        ValueConverter<List<string>, string> hashesConverter = new(
            hashes => JsonSerializer.Serialize(hashes, JsonOptions),
            json => JsonSerializer.Deserialize<List<string>>(json, JsonOptions) ?? new List<string>());

        ValueComparer<List<string>> hashesComparer = new(
            (left, right) => (left ?? new List<string>()).SequenceEqual(right ?? new List<string>()),
            hashes => hashes.Aggregate(0, (accumulated, value) => HashCode.Combine(accumulated, value.GetHashCode(StringComparison.Ordinal))),
            hashes => hashes.ToList());

        modelBuilder.Entity<Package>(entity =>
        {
            entity.HasKey(package => package.Id);
            entity.Property(package => package.Id).HasMaxLength(256);
        });

        modelBuilder.Entity<StateEntry>(entity =>
        {
            entity.HasKey(state => state.PackageIdentifier);
            entity.Property(state => state.PackageIdentifier).HasMaxLength(256);
            entity.Property(state => state.InstallerHashes)
                .HasConversion(hashesConverter, hashesComparer);
        });

        modelBuilder.Entity<PackageRun>(entity =>
        {
            entity.HasKey(run => run.Id);
            entity.HasIndex(run => run.PackageIdentifier);
            entity.HasMany(run => run.ValidationJobs)
                .WithOne(job => job.PackageRun!)
                .HasForeignKey(job => job.PackageRunId)
                .OnDelete(DeleteBehavior.Cascade);
        });

        modelBuilder.Entity<ValidationJob>(entity =>
        {
            entity.HasKey(job => job.Id);
            entity.HasIndex(job => job.Status);
            entity.HasIndex(job => job.PackageIdentifier);
        });
    }
}
