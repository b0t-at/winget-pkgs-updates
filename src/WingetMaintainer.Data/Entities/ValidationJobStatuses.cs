namespace WingetMaintainer.Data.Entities;

/// <summary>Well-known <see cref="ValidationJob.Status"/> values.</summary>
public static class ValidationJobStatuses
{
    public const string Pending = "pending";
    public const string InProgress = "in_progress";
    public const string Passed = "passed";
    public const string Failed = "failed";
    public const string TimedOut = "timed_out";
}
