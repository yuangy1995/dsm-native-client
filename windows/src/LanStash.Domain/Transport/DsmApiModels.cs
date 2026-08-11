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

    /// <summary>
    /// Chat 专用单附件 multipart 提交；不得以 File Station 上传能力替代。
    /// </summary>
    Task<ChatAttachmentUploadTransportResult> SendChatAttachmentAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        ChatAttachmentUploadRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatAttachmentUploadTransportResult(
            ChatAttachmentUploadTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "chat.attachment-send.unsupported"));

    /// <summary>
    /// Chat 专用附件另存为读取；仅把服务端二进制写入调用方提供的目标流。
    /// </summary>
    Task<ChatAttachmentContentReadResult> ReadChatAttachmentContentAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        ChatAttachmentContentReadRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatAttachmentContentReadResult(
            ChatAttachmentContentReadStatus.Unsupported,
            BytesWritten: 0,
            DestinationWasCleared: false,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "chat.attachment-save.unsupported"));

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

    Task<FileShareLinkTransportResult> DeleteFileShareLinkAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string id,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkTransportResult(
            FileShareLinkTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "file.share.delete.unsupported"));

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

    Task<DownloadTaskFileCreateTransportResult> CreateDownloadTaskFromFileAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        DownloadTaskFileCreateRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskFileCreateTransportResult(
            DownloadTaskFileCreateTransportStatus.Unsupported,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "download-station.create.file.unsupported"));
}

/// <summary>
/// 固定用于 <c>SYNO.Chat.Post.create</c> v5 的单附件上传输入。
/// 调用方拥有并负责关闭 Content；传输层只读取该流一次。
/// </summary>
public sealed record ChatAttachmentUploadRequest(
    string ConversationId,
    string Message,
    string FileName,
    Stream Content,
    long Length);

public enum ChatAttachmentUploadTransportStatus
{
    Accepted,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

/// <summary>
/// 单次 Chat 附件提交的传输事实。Accepted 仍须由仓储回读精确消息确认。
/// </summary>
public sealed record ChatAttachmentUploadTransportResult(
    ChatAttachmentUploadTransportStatus Status,
    string? CandidateMessageId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

/// <summary>
/// 固定用于 <c>SYNO.Chat.Post.File.get</c> v2 的流式读取输入。
/// ExpectedLength 必须来自消息附件元数据；Destination 必须由调用方创建为初始为空的可写、
/// 可定位流，且调用方负责关闭。
/// </summary>
public sealed record ChatAttachmentContentReadRequest(
    string MessageId,
    Stream Destination,
    long ExpectedLength);
