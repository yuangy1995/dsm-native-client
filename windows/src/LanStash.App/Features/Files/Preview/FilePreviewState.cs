using LanStash.Domain;

namespace LanStash.App.Features.Files.Preview;

public enum FilePreviewPhase
{
    Inactive,
    Preparing,
    Ready,
    DetailsOnly,
    Failed,
    Cancelled,
}

public enum FilePreviewUnavailableReason
{
    None,
    Unsupported,
    UnknownSize,
    Empty,
    TooLarge,
}

public sealed record FilePreviewMediaMetadata(
    long? PixelWidth = null,
    long? PixelHeight = null,
    DateTimeOffset? CapturedAt = null,
    string? CameraManufacturer = null,
    string? CameraModel = null,
    TimeSpan? Duration = null);

public sealed record FilePreviewSnapshot(
    Guid? ProfileId = null,
    FileItem? Item = null,
    FilePreviewKind Kind = FilePreviewKind.Unsupported,
    FilePreviewPhase Phase = FilePreviewPhase.Inactive,
    FilePreviewUnavailableReason UnavailableReason = FilePreviewUnavailableReason.None,
    string? Text = null,
    bool IsTextTruncated = false,
    IFilePreviewArtifact? Artifact = null,
    StrictRangeMediaSource? Media = null,
    FilePreviewMediaMetadata? MediaMetadata = null,
    long CompletedBytes = 0,
    long? TotalBytes = null);

public sealed record FilePreviewSaveCopyTarget(Guid ProfileId, FileItem Item);
