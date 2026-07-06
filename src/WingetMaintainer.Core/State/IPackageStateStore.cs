namespace WingetMaintainer.Core.State;

/// <summary>
/// Persistence abstraction for package validation state. Implementations must preserve the
/// legacy semantics: the validation counter increments while version and manifest hash are
/// unchanged, and resets to 1 whenever either changes.
/// </summary>
public interface IPackageStateStore
{
    /// <summary>Returns the current state for a package, or <see langword="null"/> if none exists.</summary>
    Task<PackageState?> GetAsync(string packageIdentifier, CancellationToken cancellationToken);

    /// <summary>
    /// Records a validation outcome. If the version and manifest hash match the existing entry the
    /// validation counter is incremented; otherwise the entry is reset with a counter of 1.
    /// </summary>
    Task<PackageState> SetAsync(PackageStateUpdate update, CancellationToken cancellationToken);

    /// <summary>
    /// Returns <see langword="true"/> when the package should be skipped: same version and manifest
    /// hash, state <see cref="PackageStates.ValidationFailed"/>, and the validation counter has reached
    /// <paramref name="maxFailures"/>.
    /// </summary>
    Task<bool> ShouldSkipAsync(
        string packageIdentifier,
        string version,
        string manifestHash,
        int maxFailures,
        CancellationToken cancellationToken
    );
}
