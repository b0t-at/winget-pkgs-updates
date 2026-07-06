using Microsoft.EntityFrameworkCore;
using WingetMaintainer.Core.State;
using WingetMaintainer.Data.Entities;

namespace WingetMaintainer.Data;

/// <summary>EF Core-backed <see cref="IPackageStateStore"/> implementing the legacy counter semantics.</summary>
public sealed class EfPackageStateStore : IPackageStateStore
{
    private readonly WingetMaintainerDbContext dbContext;
    private readonly TimeProvider timeProvider;

    public EfPackageStateStore(
        WingetMaintainerDbContext dbContext,
        TimeProvider? timeProvider = null
    )
    {
        ArgumentNullException.ThrowIfNull(dbContext);
        this.dbContext = dbContext;
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<PackageState?> GetAsync(
        string packageIdentifier,
        CancellationToken cancellationToken
    )
    {
        StateEntry? entry = await dbContext
            .StateEntries.FindAsync([packageIdentifier], cancellationToken)
            .ConfigureAwait(false);

        return entry is null ? null : ToModel(entry);
    }

    public async Task<PackageState> SetAsync(
        PackageStateUpdate update,
        CancellationToken cancellationToken
    )
    {
        ArgumentNullException.ThrowIfNull(update);

        StateEntry? entry = await dbContext
            .StateEntries.FindAsync([update.PackageIdentifier], cancellationToken)
            .ConfigureAwait(false);

        DateTimeOffset now = timeProvider.GetUtcNow();
        bool sameManifest =
            entry is not null
            && entry.Version == update.Version
            && entry.ManifestHash == update.ManifestHash;

        if (entry is null)
        {
            entry = new StateEntry { PackageIdentifier = update.PackageIdentifier };
            dbContext.StateEntries.Add(entry);
        }

        entry.Version = update.Version;
        entry.ManifestHash = update.ManifestHash;
        entry.State = update.State;
        entry.InstallerHashes = update.InstallerHashes.ToList();
        entry.LastUpdated = now;
        entry.ValidationCount = sameManifest ? entry.ValidationCount + 1 : 1;

        if (!sameManifest)
        {
            entry.Description = update.Description ?? string.Empty;
        }
        else if (!string.IsNullOrWhiteSpace(update.Description))
        {
            entry.Description = update.Description;
        }

        await dbContext.SaveChangesAsync(cancellationToken).ConfigureAwait(false);
        return ToModel(entry);
    }

    public async Task<bool> ShouldSkipAsync(
        string packageIdentifier,
        string version,
        string manifestHash,
        int maxFailures,
        CancellationToken cancellationToken
    )
    {
        StateEntry? entry = await dbContext
            .StateEntries.FindAsync([packageIdentifier], cancellationToken)
            .ConfigureAwait(false);

        if (entry is null || entry.Version != version || entry.ManifestHash != manifestHash)
        {
            return false;
        }

        if (entry.State != PackageStates.ValidationFailed)
        {
            return false;
        }

        return entry.ValidationCount >= maxFailures;
    }

    private static PackageState ToModel(StateEntry entry) =>
        new()
        {
            PackageIdentifier = entry.PackageIdentifier,
            Version = entry.Version,
            ManifestHash = entry.ManifestHash,
            State = entry.State,
            ValidationCount = entry.ValidationCount,
            InstallerHashes = entry.InstallerHashes.ToList(),
            Description = entry.Description,
            LastUpdated = entry.LastUpdated,
        };
}
