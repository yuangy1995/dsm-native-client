using System.Text.Json.Nodes;

namespace LanStash.Domain;

public enum SynologyPhotoDuplicatePolicy { Skip, KeepBoth }
public enum SynologyPhotoUploadState
{
    Queued, PreparingFolders, Uploading, Uploaded, AddingToAlbum, Completed, Skipped,
    Failed, PendingReview, Cancelled,
}
public enum SynologyPhotoUploadStep { None, CreateFolder, Upload, AddToAlbum }

/// <summary>原目标在入队时固定；直接相册上传不再执行一次加入相册。</summary>
public sealed record SynologyPhotoUploadTarget(SynologyPhotoSpace Space, long? FolderId = null,
    long? AlbumId = null, bool DirectToAlbum = false, SynologyPhotoDuplicatePolicy Duplicate = SynologyPhotoDuplicatePolicy.Skip);
/// <summary>本机路径仅活在内存；恢复记录只保存描述与内容摘要。</summary>
public sealed record SynologyPhotoUploadSource(string Path, IReadOnlyList<string> Directories);
public sealed record SynologyPhotoUploadFile(string Name, long Length, DateTimeOffset ModifiedAt,
    string Sha256, IReadOnlyList<string> Directories);
public sealed record SynologyPhotoUploadItem(Guid Id, SynologyPhotoUploadFile File, SynologyPhotoUploadState State,
    SynologyPhotoUploadStep Step, long BytesSent, SynologyPhoto? UploadedPhoto, bool SourceAvailable,
    SynologyPhotoFailure? Failure = null);
public sealed record SynologyPhotoUploadBatch(Guid Id, Guid ProfileId, SynologyPhotoUploadTarget Target,
    IReadOnlyList<SynologyPhotoUploadItem> Items, bool IsRunning, bool StopRequested)
{
    public bool NeedsReview => Items.Any(item => item.State == SynologyPhotoUploadState.PendingReview);
    public bool CanContinue => !IsRunning && !NeedsReview && Items.Any(item =>
        (item.SourceAvailable || item.UploadedPhoto is not null) && item.State is
            SynologyPhotoUploadState.Queued or SynologyPhotoUploadState.Uploaded or SynologyPhotoUploadState.Failed);
}

public enum SynologyPhotoWriteStatus { Accepted, Rejected, Unknown }
public sealed record SynologyPhotoWriteReceipt(SynologyPhotoWriteStatus Status, JsonObject? Data = null,
    SynologyPhotoFailure? Failure = null);
public sealed record SynologyPhotoUploadTransport(string Name, long Length, DateTimeOffset ModifiedAt,
    SynologyPhotoDuplicatePolicy Duplicate, long? FolderId = null, long? AlbumId = null, string? AlbumPassphrase = null);
