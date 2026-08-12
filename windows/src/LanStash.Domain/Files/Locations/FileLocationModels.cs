using System.Text.Json.Nodes;

namespace LanStash.Domain;

public enum FileLocationCompletion
{
    Complete,
    Truncated,
}

public enum FileLocationSectionStatus
{
    Available,
    Unavailable,
    Failed,
}

public sealed record FileLocationsAvailability(
    bool Favorites,
    bool RecycleBins,
    bool RemoteLocations);

public sealed record FileFavoriteLocation(
    Guid ProfileId,
    string Name,
    string Path);

public sealed record FileFavoriteSnapshot(
    IReadOnlyList<FileFavoriteLocation> Items,
    int Total,
    int SourceItemCount,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public sealed record FileRecycleLocation(
    Guid ProfileId,
    string ShareName,
    string SharePath,
    string RecyclePath);

public sealed record FileRecycleSnapshot(
    IReadOnlyList<FileRecycleLocation> Items,
    int AttemptedShareCount,
    int NotFoundShareCount,
    int PermissionDeniedShareCount,
    bool IsPartial,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public enum FileRemoteProtocol
{
    Cifs,
    Nfs,
    Iso,
}

public sealed record FileRemoteLocation(
    Guid ProfileId,
    string Id,
    string Name,
    string Path,
    FileRemoteProtocol Protocol,
    bool IsReadOnly);

public sealed record FileRemoteSnapshot(
    IReadOnlyList<FileRemoteLocation> Items,
    int Total,
    int SourceItemCount,
    IReadOnlyList<FileRemoteProtocol> UnavailableProtocols,
    bool IsPartial,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public sealed record FileLocationsSnapshot(
    Guid ProfileId,
    FileLocationsAvailability Availability,
    FileFavoriteSnapshot Favorites,
    FileRecycleSnapshot RecycleBins,
    FileRemoteSnapshot RemoteLocations);

/// <summary>
/// Files Locations 写请求类型。每个值只对应一次 DSM 提交，禁止由调用方重放。
/// </summary>
public enum FileLocationMutationKind
{
    AddFavorite,
    RemoveFavorite,
    CreateRemoteMount,
    UpdateRemoteMount,
    DeleteRemoteMount,
}

/// <summary>
/// Locations 专用 transport 的提交边界结果。
/// ResponseData 必须是生产 envelope 的 data 对象，不是包含 success 的外层 envelope。
/// </summary>
public enum FileLocationMutationTransportStatus
{
    ResponseReceived,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

public sealed record FileLocationMutationRequest(
    FileLocationMutationKind Kind,
    string Method,
    IReadOnlyDictionary<string, string> Parameters);

public sealed record FileLocationMutationTransportResult(
    FileLocationMutationTransportStatus Status,
    JsonObject? ResponseData = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

/// <summary>
/// Locations 写 transport。通用 JSON transport 不得通过转换或扩展方法伪装成此契约。
/// </summary>
public interface IFileLocationMutationTransport
{
    Task<FileLocationMutationTransportResult> SendFileLocationMutationAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        FileLocationMutationRequest request,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// 用于创建或编辑操作的远程挂载配置。
/// 密码只保存在内存中，不得持久化或写入日志。
/// </summary>
public sealed record RemoteMountConfiguration(
    string Server,
    string RemotePath,
    string MountPoint,
    string? Username,
    string? Password,
    string? Domain,
    bool ReadOnly,
    FileRemoteProtocol Protocol);

/// <summary>
/// 用于创建或编辑远程挂载并执行校验的草稿。
/// </summary>
public sealed record RemoteMountDraft
{
    public RemoteMountDraft(
        string server,
        string remotePath,
        string mountPoint,
        string? username,
        string? password,
        string? domain,
        bool readOnly,
        FileRemoteProtocol protocol,
        string? existingMountPoint = null)
    {
        Server = server?.Trim() ?? string.Empty;
        RemotePath = remotePath?.Trim() ?? string.Empty;
        MountPoint = mountPoint?.Trim() ?? string.Empty;
        Username = username?.Trim();
        Password = password; // deliberately not trimmed — password may contain leading/trailing whitespace
        Domain = domain?.Trim();
        ReadOnly = readOnly;
        Protocol = protocol;
        ExistingMountPoint = existingMountPoint?.Trim();
    }

    public string Server { get; }
    public string RemotePath { get; }
    public string MountPoint { get; }
    public string? Username { get; }
    public string? Password { get; }
    public string? Domain { get; }
    public bool ReadOnly { get; }
    public FileRemoteProtocol Protocol { get; }
    public string? ExistingMountPoint { get; }

    public bool IsValidForSubmission =>
        !string.IsNullOrWhiteSpace(Server) &&
        Server.Length <= 256 &&
        !string.IsNullOrWhiteSpace(RemotePath) &&
        RemotePath.Length <= 4096 &&
        !string.IsNullOrWhiteSpace(MountPoint) &&
        MountPoint.StartsWith('/') &&
        MountPoint.Length <= 4096 &&
        !MountPoint.EndsWith('/') &&
        !MountPoint.Contains("//") &&
        !MountPoint.Contains('\\') &&
        Enum.IsDefined(Protocol) &&
        (Username is null || Username.Length <= 128) &&
        (Domain is null || Domain.Length <= 128);
}
