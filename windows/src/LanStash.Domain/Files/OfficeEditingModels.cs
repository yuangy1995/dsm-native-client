namespace LanStash.Domain;

public static class OfficeDocumentFormat
{
    public static bool Supports(FileItem item) => !item.IsDirectory && SupportsExtension(Path.GetExtension(item.Name));
    public static bool SupportsExtension(string extension) => extension.ToLowerInvariant() is
        ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx";
}

public sealed record OfficeContentFingerprint(long Length, string Md5, string Sha256);
public sealed record OfficeRemoteSnapshot(FileEntryMetadata Metadata, string Md5);

public enum OfficeEditingState { Ready, Saved, Paused, Conflict, ResultUnavailable, Stopped }

/// <summary>本机副本位置只供原账号恢复；不得写入诊断日志或外部报告。</summary>
public sealed record OfficeEditingSessionInfo(Guid Id, Guid ProfileId, string OwnerId, string LocalPath,
    OfficeRemoteSnapshot Baseline, OfficeContentFingerprint Fingerprint, OfficeEditingState State,
    bool StopRequested = false, DateTimeOffset? SavedAt = null, MutationErrorCategory? Error = null)
{
    public string RemotePath => Baseline.Metadata.Item.Path;
    public override string ToString() => nameof(OfficeEditingSessionInfo);
}

public sealed record OfficeEditingAvailability(bool CanRead, bool CanAutoSave, bool RecoveryAvailable);

/// <summary>复用公开 File Station 读写；恢复操作只读，不重放保存。</summary>
public interface IOfficeEditingRepository : IFileRangeReader
{
    Guid ProfileId { get; }
    string OfficeOwnerId { get; }
    OfficeEditingAvailability OfficeAvailability { get; }
    bool HasOfficeSessionWithin(string path);
    Task<IReadOnlyList<OfficeEditingSessionInfo>> GetOfficeSessionsAsync(CancellationToken token = default);
    Task<OfficeRemoteSnapshot> ReadOfficeRemoteAsync(string path, CancellationToken token = default);
    Task<OfficeEditingSessionInfo> CreateOfficeSessionAsync(Guid id, string localPath,
        OfficeRemoteSnapshot baseline, OfficeContentFingerprint fingerprint, CancellationToken token = default);
    Task<OfficeEditingSessionInfo> SaveOfficeSessionAsync(Guid id, Stream content,
        OfficeContentFingerprint fingerprint, CancellationToken token = default);
    Task<OfficeEditingSessionInfo> ReviewOfficeSessionAsync(Guid id, CancellationToken token = default);
    Task<OfficeEditingSessionInfo> ResumeOfficeSessionAsync(Guid id, CancellationToken token = default);
    Task<OfficeEditingSessionInfo> StopOfficeSessionAsync(Guid id, CancellationToken token = default);
}
