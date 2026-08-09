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
    Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default) =>
        DiscoverAsync(profile, cancellationToken);
    Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        CancellationToken cancellationToken = default);
    Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default) =>
        LoginAsync(profile, password, otp, cancellationToken);
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

    Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string folderPath, string name,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FilePermissionTransportResult(
            FilePermissionTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.mutation.permission.unsupported"));

    Task<FileMutationTransportResult> CreateFolderMutationAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string parentPath, string name,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileMutationTransportResult(
            FileMutationTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.create-folder.unsupported"));

    Task<FileMutationTransportResult> RenameFileMutationAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string path, string newName,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileMutationTransportResult(
            FileMutationTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.rename.unsupported"));

    Task<FileCopyMoveStartTransportResult> StartFileCopyMoveAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string sourcePath,
        string destinationDirectoryPath,
        bool removeSource,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileCopyMoveStartTransportResult(
            FileMutationTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "file.copy-move.unsupported"));

    Task<FileCopyMoveTaskTransportResult> ReadFileCopyMoveStatusAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string taskId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileCopyMoveTaskTransportResult(
            FileCopyMoveTaskTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.copy-move.status-unsupported"));

    Task<FileRecycleStartTransportResult> StartMoveToRecycleAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string sourcePath,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileRecycleStartTransportResult(
            FileMutationTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "file.recycle.move.unsupported"));

    Task<FileRecycleTaskTransportResult> ReadFileRecycleStatusAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string taskId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileRecycleTaskTransportResult(
            FileRecycleTaskTransportStatus.Unsupported,
            MutationErrorCategory.Unsupported,
            "file.recycle.status-unsupported"));

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
