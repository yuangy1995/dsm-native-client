namespace LanStash.Domain;

public sealed record FileMD5Availability(
    bool CanCalculate,
    int? Version = null)
{
    public bool IsAvailable => CanCalculate;
}

public enum FileMD5Failure
{
    InvalidPath,
    Unsupported,
    AlreadyRunning,
    InvalidResponse,
    Timeout,
    PollingFailed,
}

public sealed class FileMD5Exception(FileMD5Failure failure) :
    Exception(MessageFor(failure))
{
    public FileMD5Failure Failure { get; } = failure;

    private static string MessageFor(FileMD5Failure failure) => failure switch
    {
        FileMD5Failure.InvalidPath => "An absolute file path is required.",
        FileMD5Failure.Unsupported => "MD5 calculation is unavailable.",
        FileMD5Failure.AlreadyRunning => "MD5 calculation is already running.",
        FileMD5Failure.InvalidResponse => "MD5 calculation returned an invalid response.",
        FileMD5Failure.Timeout => "MD5 calculation timed out.",
        _ => "MD5 calculation could not be completed.",
    };
}
