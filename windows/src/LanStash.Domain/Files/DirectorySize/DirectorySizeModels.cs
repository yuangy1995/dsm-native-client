namespace LanStash.Domain;

public sealed record DirectorySizeAvailability(
    bool CanCalculate,
    int? Version = null)
{
    public bool IsAvailable => CanCalculate;
}

public sealed record DirectorySizeResult(
    long TotalBytes,
    long FileCount,
    long DirectoryCount);

public enum DirectorySizeFailure
{
    InvalidPath,
    Unsupported,
    AlreadyRunning,
    InvalidResponse,
    Timeout,
    PollingFailed,
}

public sealed class DirectorySizeException(DirectorySizeFailure failure) :
    Exception(MessageFor(failure))
{
    public DirectorySizeFailure Failure { get; } = failure;

    private static string MessageFor(DirectorySizeFailure failure) => failure switch
    {
        DirectorySizeFailure.InvalidPath => "An absolute directory path is required.",
        DirectorySizeFailure.Unsupported => "Directory size calculation is unavailable.",
        DirectorySizeFailure.AlreadyRunning =>
            "Directory size calculation is already running.",
        DirectorySizeFailure.InvalidResponse =>
            "Directory size calculation returned an invalid response.",
        DirectorySizeFailure.Timeout => "Directory size calculation timed out.",
        _ => "Directory size calculation could not be completed.",
    };
}
