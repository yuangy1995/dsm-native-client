namespace LanStash.Domain;

public sealed record ApiCapability(
    string Name,
    string Path,
    int MinVersion,
    int MaxVersion,
    string RequestFormat)
{
    public int SelectVersion(int preferred) => Math.Clamp(preferred, MinVersion, MaxVersion);
}

public enum DsmErrorKind
{
    Unknown,
    InvalidAddress,
    InsecureAddress,
    InvalidQuickConnectId,
    QuickConnectNotFound,
    QuickConnectOffline,
    QuickConnectDirectUnavailable,
    QuickConnectServiceUnavailable,
    QuickConnectInvalidResponse,
    QuickConnectRelayDisabled,
    QuickConnectRelayUnavailable,
    QuickConnectIdentityMismatch,
}

public static class UserText
{
    public const string ResourcePrefix = "loc:";

    public static string Key(string resourceKey) => $"{ResourcePrefix}{resourceKey}";
}

public sealed class DsmException(
    string message,
    string recovery,
    int? code = null,
    bool authenticationFailure = false,
    DsmErrorKind kind = DsmErrorKind.Unknown) : Exception(message)
{
    public string Recovery { get; } = recovery;
    public int? Code { get; } = code;
    public bool AuthenticationFailure { get; } = authenticationFailure;
    public DsmErrorKind Kind { get; } = kind;
}

public enum DsmBinaryResponseFailure
{
    EmptyBody,
    UnexpectedMediaType,
    ResponseTooLarge,
}

public sealed class DsmBinaryResponseException(
    DsmBinaryResponseFailure failure,
    string message) : Exception(message)
{
    public DsmBinaryResponseFailure Failure { get; } = failure;
}

public sealed record DsmBinaryResponse(
    byte[] Bytes,
    string MediaType);

public sealed class DsmReadContractUnsupportedException() :
    NotSupportedException("The API client does not implement fixed-version read JSON calls.");

public interface IDsmApiClient
{
    Uri GetBaseUri(NasProfile profile);
    Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        CancellationToken cancellationToken = default);
    Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        CancellationToken cancellationToken = default);
    Task LogoutAsync(
        NasProfile profile,
        DsmSession session,
        CancellationToken cancellationToken = default);
    Task<System.Text.Json.Nodes.JsonObject> CallAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string method,
        IReadOnlyDictionary<string, string>? parameters = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// 使用契约指定的固定版本执行只读调用，并要求 DSM 返回严格的对象型 JSON data。
    /// 旧测试替身默认不支持此窄契约，以免在未验证版本和响应形态时静默降级。
    /// </summary>
    Task<System.Text.Json.Nodes.JsonObject> CallReadJsonObjectAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        int requiredVersion,
        string method,
        IReadOnlyDictionary<string, string>? parameters = null,
        CancellationToken cancellationToken = default) =>
        Task.FromException<System.Text.Json.Nodes.JsonObject>(
            new DsmReadContractUnsupportedException());

    Task<FileShareLinkTransportResult> CreateFileShareLinkAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkTransportResult(
            FileShareLinkTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "file.share.create.unsupported"));

    Task<DsmBinaryResponse> ReadBinaryAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        string acceptedMediaTypePrefix,
        int maximumBytes,
        CancellationToken cancellationToken = default) =>
        Task.FromException<DsmBinaryResponse>(
            new NotSupportedException("The API client does not implement bounded binary responses."));
    Task<byte[]> ReadFileRangeAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string remotePath,
        long offset,
        long length,
        CancellationToken cancellationToken = default);

    Task<FileRangeReadResult> ReadFileRangeResultAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string remotePath,
        long offset,
        long length,
        string? expectedContentVersion = null,
        long? expectedTotalLength = null,
        CancellationToken cancellationToken = default) =>
        Task.FromException<FileRangeReadResult>(
            new NotSupportedException("The API client does not implement the strict file range contract."));

    Task<FileUploadTransportResult> UploadFileAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        FileUploadRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileUploadTransportResult(
            FileUploadTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.upload.unsupported"));
}
