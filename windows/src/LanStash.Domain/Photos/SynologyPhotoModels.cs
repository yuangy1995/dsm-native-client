namespace LanStash.Domain;

/// <summary>Photos 项目身份不能由文件路径、文件名或缩略图单元推导。</summary>
public enum SynologyPhotoSpace { Personal, Shared }
public sealed record SynologyPhotoIdentity(Guid ProfileId, SynologyPhotoSpace Space, long ItemId);
public enum SynologyPhotoThumbnailType { Unit, Person, Face }
public enum SynologyPhotoThumbnailSize { Small, Medium, Large }
public sealed record SynologyPhotoThumbnail(long UnitId, string Revision)
{
    public SynologyPhotoThumbnailType Type { get; init; }
    public bool NativeSize { get; init; }
    public SynologyPhotoSpace Space { get; init; }
    public long? AlbumId { get; init; }
    public int? FolderCoverSequence { get; init; }
}
/// <summary>原件所有者决定来源；贡献者是相册角色，不能当作原件管理权限。</summary>
public sealed record SynologyPhotoAlbumContext(long AlbumId, long OwnerUserId, long? ProviderUserId);

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
    public SynologyPhotoAlbumContext? AlbumContext { get; init; }
    public SynologyPhotoSimilarGroup? SimilarGroup { get; init; }
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
    public IReadOnlyList<SynologyPhotoChoice>? Tags { get; init; }
    public int? CounterClockwiseOrientation => Orientation is >= 1 and <= 8 ? new[] { 8, 5, 6, 7, 4, 1, 2, 3 }[Orientation.Value - 1] : null;
    public bool SupportsRotation => MediaType is "photo" or "live" or "motion_photo" or "burst" &&
        Path.GetExtension(Filename).ToLowerInvariant() is not (".gif" or ".webp") && CounterClockwiseOrientation is not null;
    public bool SupportsOptimizedJpeg => MediaType != "video" && Path.GetExtension(Filename).ToLowerInvariant() is not (".gif" or ".webp");
    public bool SupportsPreviewGeneration => MediaType is "photo" or "video" or "live" or "motion_photo" or "burst" or "photo360" &&
        Path.GetExtension(Filename).ToLowerInvariant() is not (".gif" or ".webp");
    public bool SupportsOriginalSizeJpeg => Path.GetExtension(Filename).ToLowerInvariant() switch
    {
        ".heic" or ".heif" or ".hif" => MediaType is "photo" or "photo360" or "burst" or "motion_photo" or "live",
        ".tif" or ".tiff" or ".arw" or ".srf" or ".sr2" or ".dcr" or ".k25" or ".kdc" or ".cr2" or ".cr3" or ".crw" or ".nef" or ".mrw" or
        ".ptx" or ".pef" or ".raf" or ".3fr" or ".erf" or ".mef" or ".mos" or ".orf" or ".rw2" or ".dng" or ".x3f" or ".raw" => true,
        _ => false,
    };
    public IReadOnlyList<string> Address { get; init; } = [];
    public double? Latitude { get; init; }
    public double? Longitude { get; init; }

    public bool IsSameDeletionTarget(SynologyPhoto other) =>
        Id == other.Id && Filename == other.Filename && SizeBytes == other.SizeBytes &&
        TakenAt == other.TakenAt && IndexedAt == other.IndexedAt &&
        FolderId == other.FolderId && MediaType == other.MediaType;
}

public sealed record SynologyPhotoAccess(IReadOnlyList<SynologyPhotoSpace> Spaces, string PackageVersion)
{
    public bool CanManageSharedSpace { get; init; }
    public bool IsAdministrator { get; init; }
    public SynologyPhotoDisplaySettings? DisplaySettings { get; init; }
}
public sealed record SynologyPhotoDay(DateOnly Date, int Count);
public sealed record SynologyPhotoPage(IReadOnlyList<SynologyPhoto> Items, int Offset, int NextOffset, bool HasMore);
public sealed record SynologyPhotoCollection(long Id, string Name, long? ParentId = null, int? Count = null)
{
    public SynologyPhotoThumbnail? Thumbnail { get; init; }
    public SynologyPhotoSpace Space { get; init; }
    public string? Path { get; init; }
    public bool IsConditional { get; init; }
    public bool IsFrozen { get; init; }
}
public enum SynologyPhotoCategory { Recent, People, Subjects, Locations, Tags, Videos, Similar }
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
    public SynologyPhotoSpace Space { get; init; }
    public sealed record Timeline(long Start, long End) : SynologyPhotoQuery;
    public sealed record Search(string Keyword, long Start, long End) : SynologyPhotoQuery;
    public sealed record Filtered(SynologyPhotoFilter Filter, long Start, long End) : SynologyPhotoQuery;
    public sealed record Category(SynologyPhotoCategory Kind, long Id, long Start, long End) : SynologyPhotoQuery;
    public sealed record Folder(long Id, SynologyPhotoSort? Sort = null) : SynologyPhotoQuery;
    public sealed record Album(long Id, SynologyPhotoSort? Sort = null) : SynologyPhotoQuery;
    public sealed record Recent : SynologyPhotoQuery;
}

public enum SynologyPhotoFailure
{
    Unavailable, Permission, InvalidResponse, Media, LengthMismatch,
    DeletionUnverified, TargetChanged, DeleteDenied, DeleteFailed, UploadBusy, RecoveryUnavailable, WriteFailed, SessionExpired,
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
    Task<IReadOnlyList<SynologyPhotoBackgroundTask>> BackgroundTasksAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoBackgroundTask>>();
    Task<IReadOnlyList<SynologyPhotoBackgroundError>> BackgroundTaskErrorsAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoBackgroundError>>();
    Task<IReadOnlyList<SynologyPhotoFolder>> BackgroundTaskLocationAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFolder>>();
    Task<SynologyPhotoSettingsChange> ControlBackgroundTasksAsync(Guid operationId, SynologyPhotoBackgroundCommand command,
        bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<IReadOnlyList<SynologyPhotoSettingsChange>> BackgroundChangesAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoSettingsChange>>([]);
    Guid ProfileId { get; }
    bool CanDeleteOriginals => false;
    bool SupportsUploads => false;
    bool SupportsOriginalSizeJpeg => false;
    bool SupportsPreviewGeneration(SynologyPhotoSpace space) => false;
    bool SupportsAutomaticPreview(SynologyPhotoSpace space) => false;
    Task<SynologyPhotoConversionSupport> PreviewConversionSupportAsync(CancellationToken cancellationToken = default) => Task.FromResult(new SynologyPhotoConversionSupport(false, false, false));
    Task<bool> AutomaticPreviewEnabledAsync(CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoDisplaySettings> DisplaySettingsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDisplaySettings>();
    Task<SynologyPhotoDuplicateSettings> DuplicateSettingsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDuplicateSettings>();
    Task<SynologyPhotoRecognitionSettings> RecognitionSettingsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionSettings>();
    SynologyPhotoSettingsSafety SettingsSafety => new();
    Task<SynologyPhotoLibraryMaintenance> LibraryMaintenanceAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoLibraryMaintenance>();
    Task<SynologyPhotoCodecPrompt> CodecPromptAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoCodecPrompt>();
    Task<SynologyPhotoSettingsChange> MaintainLibraryAsync(Guid operationId, SynologyPhotoLibraryMaintenance original, SynologyPhotoMaintenanceAction action,
        bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> RespondToCodecPromptAsync(Guid operationId, SynologyPhotoCodecPrompt original, bool generate,
        bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoGlobalSettings> GlobalSettingsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoGlobalSettings>();
    Task<SynologyPhotoSharedMembers> SharedMembersAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharedMembers>();
    Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharedMemberCandidatesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoShareRecipient>>();
    Task<IReadOnlyList<SynologyPhotoMemberFolder>> SharedMemberFoldersAsync(SynologyPhotoShareIdentity member, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoMemberFolder>>();
    Task<SynologyPhotoSettingsChange> SetSharedMembersAsync(Guid operationId, SynologyPhotoSharedMembers original, IReadOnlyList<SynologyPhotoSharedMember> members,
        IReadOnlyList<SynologyPhotoMemberFolderEdit> edits, bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoConversionCache> ConversionCacheAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoConversionCache>();
    Task<SynologyPhotoSettingsChange> SetGlobalSettingsAsync(Guid operationId, SynologyPhotoGlobalSettings original,
        SynologyPhotoGlobalSettings updated, bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> ClearConversionCacheAsync(Guid operationId, SynologyPhotoConversionCache original,
        bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSharedSettings> SharedSettingsAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharedSettings>();
    Task<SynologyPhotoSettingsChange> SetSharedSettingsAsync(Guid operationId, SynologyPhotoSharedSettings original,
        SynologyPhotoSharedSettings updated, bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> SetSharedEnabledAsync(Guid operationId, SynologyPhotoSharedSettings original,
        bool enabled, bool confirmed = false, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> SetDisplaySettingsAsync(Guid operationId, SynologyPhotoDisplaySettings original,
        SynologyPhotoDisplaySettings updated, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> SetDuplicateSettingsAsync(Guid operationId, SynologyPhotoDuplicateSettings original,
        SynologyPhotoDuplicateSettings updated, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> SetRecognitionSettingsAsync(Guid operationId, SynologyPhotoRecognitionSettings original,
        SynologyPhotoRecognitionSettings updated, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoSettingsChange> SetAutomaticPreviewAsync(Guid operationId, bool original, bool enabled,
        CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<IReadOnlyList<SynologyPhotoSettingsChange>> SettingsChangesAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoSettingsChange>>([]);
    Task<SynologyPhotoSettingsChange> ReviewSettingsChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSettingsChange>();
    Task<SynologyPhotoAutomaticPreview> GenerateAutomaticPreviewAsync(Guid operationId, SynologyPhotoAutomaticCandidate candidate,
        SynologyPhotoConversionSupport support, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAutomaticPreview>();
    Task<IReadOnlyList<SynologyPhotoAutomaticPreview>> AutomaticPreviewsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticPreview>>([]);
    Task<SynologyPhotoAutomaticPreview> ReviewAutomaticPreviewAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAutomaticPreview>();
    Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhotoSpace space, SynologyPhotoConversionSupport support,
        CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoAutomaticCandidate>>();
    Task<IReadOnlyList<SynologyPhotoAutomaticCandidate>> AutomaticPreviewCandidatesAsync(SynologyPhoto photo, SynologyPhotoConversionSupport support,
        CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoAutomaticCandidate>>([]);
    Task<IReadOnlyList<SynologyPhoto>> PendingPreviewGenerationsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhoto>>();
    Task PreparePreviewGenerationAsync(SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoPreviewGeneration> GeneratePreviewsAsync(Guid operationId, SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoPreviewGeneration>();
    Task<IReadOnlyList<SynologyPhotoPreviewGeneration>> PreviewGenerationsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoPreviewGeneration>>([]);
    Task<SynologyPhotoPreviewGeneration> ReviewPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoPreviewGeneration>();
    Task<SynologyPhotoPreviewGeneration> ContinuePreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoPreviewGeneration>();
    Task<SynologyPhotoPreviewGeneration> CancelPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoPreviewGeneration>();
    async Task<SynologyPhotoDownloadResult> DownloadAsync(SynologyPhoto photo, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        if (format != SynologyPhotoDownloadFormat.Original) return await Unsupported<SynologyPhotoDownloadResult>();
        await DownloadOriginalAsync(photo, destination, progress, cancellationToken);
        return new(format, photo.SizeBytes);
    }
    Task<long> DownloadArchiveAsync(SynologyPhotoArchiveTarget target, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default) => Unsupported<long>();
    bool SupportsManagement => false;
    bool SupportsFolderManagement => false;
    bool SupportsFileManagement => false;
    bool SupportsAlbumManagement => false;
    bool SupportsSharingManagement => false;
    bool SupportsFolderSharing => false;
    bool SupportsRecognitionManagement => false;
    bool SupportsSimilarManagement(SynologyPhotoSpace space) => false;
    Task<SynologyPhotoSimilarDetail?> SimilarGroupAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSimilarDetail?>();
    Task<SynologyPhotoSimilarStatus> SimilarStatusAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSimilarStatus>();
    Task<IReadOnlyList<SynologyPhoto>> SimilarCleanupAsync(SynologyPhotoSimilarDetail detail, IReadOnlyList<long> keep, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhoto>>();
    Task<SynologyPhotoRecognitionEdit> SimilarUndoAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionEdit>();
    bool SupportsConceptManagement(SynologyPhotoSpace space) => false;
    Task<IReadOnlyList<SynologyPhotoConcept>> ConceptsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoConcept>>();
    Task<SynologyPhotoConcept> ConceptAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoConcept>();
    SynologyPhotoRecognitionSafety RecognitionSafety => new();
    bool SupportsManualFaceEditing(SynologyPhotoSpace space) => false;
    Task<IReadOnlyList<SynologyPhotoFaceRegion>> PhotoFacesAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFaceRegion>>();
    Task<IReadOnlyList<SynologyPhotoPerson>> PeopleAsync(SynologyPhotoSpace space, bool includeHidden, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoPerson>>();
    Task<byte[]> CategoryImageAsync(SynologyPhotoCategory category, SynologyPhotoCollection item, CancellationToken cancellationToken = default) => Unsupported<byte[]>();
    Task<IReadOnlyList<SynologyPhotoFace>> PersonFacesAsync(long personId, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFace>>();
    Task<byte[]> FaceImageAsync(SynologyPhotoFace face, CancellationToken cancellationToken = default) => Unsupported<byte[]>();
    Task<IReadOnlyList<SynologyPhoto>> RecognitionPhotosAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhoto>>();
    Task PrepareRecognitionAsync(SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoRecognitionChange> EditRecognitionAsync(Guid operationId, SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionChange>();
    Task<IReadOnlyList<SynologyPhotoRecognitionChange>> RecognitionChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoRecognitionChange>>();
    Task<SynologyPhotoRecognitionChange> ReviewRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionChange>();
    Task<SynologyPhotoRecognitionChange> ContinueRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionChange>();
    Task<SynologyPhotoRecognitionChange> CancelRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRecognitionChange>();
    Task<SynologyPhotoFolderSharing> FolderSharingAsync(SynologyPhotoFolder folder, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderSharing>();
    Task PrepareFolderSharingAsync(SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoFolderSharingChange> EditFolderSharingAsync(Guid operationId, SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderSharingChange>();
    Task<IReadOnlyList<SynologyPhotoFolderSharingChange>> FolderSharingChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFolderSharingChange>>();
    Task<SynologyPhotoFolderSharingChange> ReviewFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderSharingChange>();
    Task<SynologyPhotoFolderSharingChange> ContinueFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderSharingChange>();
    Task<SynologyPhotoFolderSharingChange> CancelFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderSharingChange>();
    SynologyPhotoSharingSafety SharingSafety => new();
    bool SupportsRequestManagement => false;
    Task<SynologyPhotoRequest> PhotoRequestAsync(string id, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRequest>();
    Task<IReadOnlyList<SynologyPhotoRequestAlbum>> PhotoRequestAlbumsAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoRequestAlbum>>();
    Task PreparePhotoRequestAsync(SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoRequestChange> EditPhotoRequestAsync(Guid operationId, SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRequestChange>();
    Task<IReadOnlyList<SynologyPhotoRequestChange>> PhotoRequestChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoRequestChange>>();
    Task<SynologyPhotoRequestChange> ReviewPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRequestChange>();
    Task<SynologyPhotoRequestChange> ContinuePhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRequestChange>();
    Task<SynologyPhotoRequestChange> CancelPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoRequestChange>();
    Task<SynologyPhotoTemporaryChange> CreateTemporarySharingAsync(Guid operationId, string name, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<SynologyPhotoTemporaryChange> StopTemporarySharingAsync(Guid operationId, SynologyPhotoSharing original, bool keepCopy, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<IReadOnlyList<SynologyPhotoTemporaryChange>> TemporarySharingChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoTemporaryChange>>();
    Task<SynologyPhotoTemporaryChange> ContinueTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<SynologyPhotoTemporaryChange> ReviewTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<SynologyPhotoTemporaryChange> CancelTemporaryCreationAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<SynologyPhotoTemporaryChange> KeepTemporaryAlbumsAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoTemporaryChange>();
    Task<SynologyPhotoSharing> AlbumSharingAsync(long id, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharing>();
    Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharingRecipientsAsync(bool sharedFolder = false, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoShareRecipient>>();
    Task PrepareSharingAsync(SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoSharingChange> EditSharingAsync(Guid operationId, SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharingChange>();
    Task<IReadOnlyList<SynologyPhotoSharingChange>> SharingChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoSharingChange>>();
    Task<SynologyPhotoSharingChange> ReviewSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharingChange>();
    Task<SynologyPhotoSharingChange> ContinueSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharingChange>();
    Task<SynologyPhotoSharingChange> CancelSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoSharingChange>();
    SynologyPhotoAlbumSafety AlbumSafety => new();
    Task<SynologyPhotoAlbum> AlbumAsync(long id, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbum>();
    Task<SynologyPhotoAlbumListSort> AlbumListSortAsync(SynologyPhotoAlbumListScope scope, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumListSort>();
    Task<SynologyPhotoAlbumDisplay> AlbumDisplayAsync(CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumDisplay>();
    Task PrepareAlbumAsync(SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoConditionSnapshot> AlbumConditionAsync(long id, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoConditionSnapshot>();
    Task<SynologyPhotoFrozenAlbum> FrozenAlbumAsync(long id, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFrozenAlbum>();
    Task<IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>> ConditionSuggestionsAsync(SynologyPhotoSpace space, string keyword, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>>();
    Task<int> ConditionItemCountAsync(SynologyPhotoCondition condition, CancellationToken cancellationToken = default) => Unsupported<int>();
    Task<SynologyPhotoAlbumChange> EditAlbumAsync(Guid operationId, SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumChange>();
    Task<IReadOnlyList<SynologyPhotoAlbumChange>> AlbumChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoAlbumChange>>();
    Task<SynologyPhotoAlbumChange> ReviewAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumChange>();
    Task<SynologyPhotoAlbumChange> ContinueAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumChange>();
    Task<SynologyPhotoAlbumChange> CancelAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoAlbumChange>();
    SynologyPhotoFileSafety FileSafety => new();
    Task PrepareFilesAsync(SynologyPhotoFileCommand command, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoFileChange> ChangeFilesAsync(Guid operationId, SynologyPhotoFileCommand command, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFileChange>();
    Task<IReadOnlyList<SynologyPhotoFileChange>> FileChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFileChange>>();
    Task<SynologyPhotoFileChange> ReviewFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFileChange>();
    Task<SynologyPhotoFileChange> ContinueFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFileChange>();
    Task<SynologyPhotoFileChange> CancelFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFileChange>();
    Task<SynologyPhotoFolder> FolderAsync(long? id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolder>();
    Task<IReadOnlyList<byte[]>> FolderCoverImagesAsync(SynologyPhotoCollection folder, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<byte[]>>();
    Task<SynologyPhotoFolderChange> EditFolderAsync(Guid operationId, SynologyPhotoFolderEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderChange>();
    Task<IReadOnlyList<SynologyPhotoFolderChange>> FolderChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoFolderChange>>();
    Task<SynologyPhotoFolderChange> ReviewFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderChange>();
    Task<SynologyPhotoFolderChange> ContinueFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderChange>();
    Task<SynologyPhotoFolderChange> CancelFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoFolderChange>();
    Task<IReadOnlyList<SynologyPhotoChoice>> TagsAsync(SynologyPhotoSpace space, int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoChoice>>();
    Task PrepareEditAsync(SynologyPhotoEdit edit, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoChange> EditAsync(Guid operationId, SynologyPhotoEdit edit, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoChange>();
    Task<IReadOnlyList<SynologyPhotoChange>> ChangesAsync(CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoChange>>();
    Task<SynologyPhotoChange> ReviewChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoChange>();
    Task<SynologyPhotoChange> ContinueChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoChange>();
    Task<SynologyPhotoChange> CancelChangeAsync(Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoChange>();
    Task<IReadOnlyList<SynologyPhotoCollection>> AddableAlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task PrepareUploadAsync(SynologyPhotoUploadTarget target, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoUploadBatch> QueueUploadAsync(Guid operationId, SynologyPhotoUploadTarget target,
        IReadOnlyList<SynologyPhotoUploadSource> sources, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoUploadBatch>();
    Task<IReadOnlyList<SynologyPhotoUploadBatch>> UploadsAsync(CancellationToken cancellationToken = default) => Task.FromResult<IReadOnlyList<SynologyPhotoUploadBatch>>([]);
    Task<SynologyPhotoUploadBatch> ContinueUploadAsync(Guid batchId, IReadOnlyList<SynologyPhotoUploadSource>? sources = null,
        CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoUploadBatch>();
    Task<SynologyPhotoUploadBatch> ReviewUploadAsync(Guid batchId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoUploadBatch>();
    Task StopUploadAsync(Guid batchId, bool cancelRemaining = false) => Unsupported<bool>();
    Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default);
    Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default);
    Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default);
    Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Unsupported<SynologyPhotoCollection>();
    Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, bool descending, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        descending ? Unsupported<IReadOnlyList<SynologyPhotoCollection>>() : FoldersAsync(parentId, offset, limit, cancellationToken, space);
    Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, SynologyPhotoAlbumDisplay display, SynologyPhotoAlbumListSort sort,
        CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Unsupported<IReadOnlySet<SynologyPhotoCategory>>();
    Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Unsupported<IReadOnlyList<SynologyPhotoCollection>>();
    Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoSharedEntry>>();
    Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, SynologyPhotoAlbumListSort sort,
        CancellationToken cancellationToken = default) => Unsupported<IReadOnlyList<SynologyPhotoSharedEntry>>();
    Task<SynologyPhotoFilterOptions> FilterOptionsAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => Unsupported<SynologyPhotoFilterOptions>();
    Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default) => Unsupported<byte[]>();
    Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<SynologyPhoto>();
    Task<IReadOnlyMediaSource> VideoSourceAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<IReadOnlyMediaSource>();
    Task DownloadOriginalAsync(SynologyPhoto photo, string destination, IProgress<long>? progress = null, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task PrepareDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<bool>();
    Task<SynologyPhotoDeletionResult> DeleteAsync(SynologyPhoto photo, Guid operationId, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDeletionResult>();
    Task<SynologyPhotoDeletionResult> ReviewDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) => Unsupported<SynologyPhotoDeletionResult>();

    private static Task<T> Unsupported<T>() => Task.FromException<T>(new SynologyPhotoException(SynologyPhotoFailure.Unavailable));
}
