namespace LanStash.Domain;

public sealed record FileRangeReadResult(
    int StatusCode,
    long RequestedStart,
    long RequestedLength,
    long ResponseStart,
    long ResponseLength,
    long TotalLength,
    long ActualByteCount,
    byte[] Bytes,
    string? ServerContentVersion,
    bool CanSafelyReadInSegments);

public enum FileRangeContractFailure
{
    UnexpectedStatus,
    MissingContentRange,
    UnexpectedRangeStart,
    UnexpectedRangeLength,
    UnexpectedTotalLength,
    UnexpectedContentLength,
    UnexpectedBodyLength,
    ContentVersionMismatch,
    UnsafeSegmentedRead,
}

public sealed class FileRangeContractException(
    FileRangeContractFailure failure,
    string message,
    int? statusCode = null) : IOException(message)
{
    public FileRangeContractFailure Failure { get; } = failure;
    public int? StatusCode { get; } = statusCode;
}
