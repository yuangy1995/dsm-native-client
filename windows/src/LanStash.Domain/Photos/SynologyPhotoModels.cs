namespace LanStash.Domain;

/// <summary>Photos 项目身份不能由文件路径、文件名或缩略图单元推导。</summary>
public enum SynologyPhotoSpace { Personal, Shared }
public sealed record SynologyPhotoIdentity(Guid ProfileId, SynologyPhotoSpace Space, long ItemId);
public sealed record SynologyPhotoThumbnail(long UnitId, string Revision);

public sealed record SynologyPhoto(
    SynologyPhotoIdentity Id,
    string Filename,
    long SizeBytes,
    DateTimeOffset TakenAt,
    DateTimeOffset IndexedAt,
    long FolderId,
    string MediaType)
{
    public SynologyPhotoThumbnail? Thumbnail { get; init; }
    public int? Width { get; init; }
    public int? Height { get; init; }
    public int? Orientation { get; init; }
    public string? Description { get; init; }
    public string? Camera { get; init; }
    public string? Lens { get; init; }
    public string? Aperture { get; init; }
    public string? ExposureTime { get; init; }
    public string? FocalLength { get; init; }
    public string? Iso { get; init; }
    public double? Duration { get; init; }
    public int? Rating { get; init; }
    public IReadOnlyList<string> Address { get; init; } = [];
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }

    public bool IsSameDeletionTarget(SynologyPhoto other) =>
        Id == other.Id && Filename == other.Filename && SizeBytes == other.SizeBytes &&
        TakenAt == other.TakenAt && IndexedAt == other.IndexedAt &&
        FolderId == other.FolderId && MediaType == other.MediaType;
}

public sealed record SynologyPhotoAccess(IReadOnlyList<SynologyPhotoSpace> Spaces, string PackageVersion);
public sealed record SynologyPhotoDay(DateOnly Date, int Count);
public sealed record SynologyPhotoPage(IReadOnlyList<SynologyPhoto> Items, int Offset, int NextOffset, bool HasMore);
public sealed record SynologyPhotoCollection(long Id, string Name, long? ParentId = null, int? Count = null);
public enum SynologyPhotoCategory { Recent, People, Subjects, Locations, Tags, Videos }
public enum SynologyPhotoShareScope { WithMe, WithOthers, Requests }
public sealed record SynologyPhotoSharedEntry(string Id, string Title, long? AlbumId = null, Uri? Url = null);
public sealed record SynologyPhotoChoice(long Id, string Name);
public sealed record SynologyPhotoLocation(long Id, string Name, int Level, IReadOnlyList<SynologyPhotoLocation> Children);
public sealed record SynologyPhotoFocalRange(int Start, int End);
public sealed record SynologyPhotoFraction(int Num, int Den);
public sealed record SynologyPhotoExposureRange(SynologyPhotoFraction Start, SynologyPhotoFraction End);

public sealed record SynologyPhotoFilter
{
    public int? MediaType { get; init; }
    public long? StartTime { get; init; }
    public long? EndTime { get; init; }
    public long? PersonId { get; init; }
    public long? LocationId { get; init; }
    public long? TagId { get; init; }
    public int? Rating { get; init; }
    public long? CameraId { get; init; }
    public long? LensId { get; init; }
    public long? IsoId { get; init; }
    public long? ApertureId { get; init; }
    public SynologyPhotoFocalRange? FocalRange { get; init; }
    public SynologyPhotoExposureRange? ExposureRange { get; init; }
    public bool IsActive => this != new SynologyPhotoFilter();
}

public sealed record SynologyPhotoFilterOptions
{
    public IReadOnlyList<SynologyPhotoChoice> People { get; init; } = [];
    public IReadOnlyList<SynologyPhotoLocation> Locations { get; init; } = [];
    public IReadOnlyList<SynologyPhotoChoice> Tags { get; init; } = [];
    public IReadOnlyList<SynologyPhotoChoice> Cameras { get; init; } = [];
    public IReadOnlyList<SynologyPhotoChoice> Lenses { get; init; } = [];
    public IReadOnlyList<SynologyPhotoChoice> Iso { get; init; } = [];
    public IReadOnlyList<SynologyPhotoChoice> Apertures { get; init; } = [];
    public IReadOnlyList<SynologyPhotoFocalRange> FocalRanges { get; init; } = [];
    public IReadOnlyList<SynologyPhotoExposureRange> ExposureRanges { get; init; } = [];
}

public abstract record SynologyPhotoQuery
{
    public sealed record Timeline(long Start, long End) : SynologyPhotoQuery;
    public sealed record Search(string Keyword, long Start, long End) : SynologyPhotoQuery;
    public sealed record Filtered(SynologyPhotoFilter Filter, long Start, long End) : SynologyPhotoQuery;
    public sealed record Category(SynologyPhotoCategory Kind, long Id, long Start, long End) : SynologyPhotoQuery;
    public sealed record Folder(long Id) : SynologyPhotoQuery;
    public sealed record Album(long Id) : SynologyPhotoQuery;
    public sealed record Recent : SynologyPhotoQuery;
}

public enum SynologyPhotoFailure
{
    Unavailable, Permission, InvalidResponse, Media, LengthMismatch,
    DeletionUnverified, TargetChanged, DeleteDenied, DeleteFailed,
}
public sealed class SynologyPhotoException(SynologyPhotoFailure failure) : Exception($"photos.{failure}")
{
    public SynologyPhotoFailure Failure { get; } = failure;
}
public enum SynologyPhotoDeletionResult { Confirmed, PendingReview }

/// <summary>播放器只拿到有界读取能力；凭据、远端 URL 和具体 HTTP 路由留在传输层。</summary>
public interface IReadOnlyMediaSource : IDisposable
{
    long Length { get; }
    string ContentType { get; }
    Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancellationToken = default);
}

public sealed record SynologyPhotoMediaRequest(
    ApiCapability Capability, string Method, IReadOnlyDictionary<string, string> Parameters);

public interface ISynologyPhotosProvider
{
    ISynologyPhotosRepository SynologyPhotos { get; }
}

/// <summary>内部 Photos 契约，不提供 File Station 降级或路径转换。</summary>
public interface ISynologyPhotosRepository
{
    Guid ProfileId { get; }
    bool CanDeleteOriginals => false;
    Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default);
    Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default);
    Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoCollection>();
    Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlySet<SynologyPhotoCategory>>();
    Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category, int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoSharedEntry>>();
    Task<SynologyPhotoFilterOptions> FilterOptionsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFilterOptions>();
    Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default) => Unsupported<byte[]>();
    Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<SynologyPhoto>();
    Task<IReadOnlyMediaSource> VideoSourceAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyMediaSource>();
    Task DownloadOriginalAsync(SynologyPhoto photo, string destination, IProgress<long>? progress = null, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task PrepareDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoDeletionResult> DeleteAsync(SynologyPhoto photo, Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDeletionResult>();
    Task<SynologyPhotoDeletionResult> ReviewDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDeletionResult>();

    private static Task<T> Unsupported<T>() => Task.FromException<T>(new SynologyPhotoException(SynologyPhotoFailure.Unavailable));
}
