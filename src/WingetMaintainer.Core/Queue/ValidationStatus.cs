namespace WingetMaintainer.Core.Queue;

/// <summary>Canonical validation job status values (shared by Worker, queue, and runner).</summary>
public static class ValidationStatus
{
    public const string Pending = "pending";
    public const string InProgress = "in_progress";
    public const string Passed = "passed";
    public const string Failed = "failed";
    public const string TimedOut = "timed_out";
}
