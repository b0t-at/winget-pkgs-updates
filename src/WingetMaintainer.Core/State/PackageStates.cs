namespace WingetMaintainer.Core.State;

/// <summary>Well-known package validation state values (preserved from the legacy state file).</summary>
public static class PackageStates
{
    public const string ValidationPassed = "VALIDATION_PASSED";
    public const string ValidationFailed = "VALIDATION_FAILED";

    /// <summary>Default number of failed validations after which a package is skipped (legacy default).</summary>
    public const int DefaultMaxFailures = 3;
}
