namespace WingetMaintainer.Core.Runner;

/// <summary>Maps a sandbox validation process outcome to a terminal job status.</summary>
public static class ValidationOutcome
{
    public static string FromProcess(int exitCode, bool timedOut)
    {
        if (timedOut)
        {
            return Queue.ValidationStatus.TimedOut;
        }

        return exitCode == 0 ? Queue.ValidationStatus.Passed : Queue.ValidationStatus.Failed;
    }
}
