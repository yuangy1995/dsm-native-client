namespace LanStash.Domain;

public enum FilePreviewKind
{
    Unsupported,
    Text,
    Image,
    Pdf,
    Audio,
    Video,
}

public sealed record FilePreviewTarget(
    Guid ProfileId,
    FileItem Item,
    FilePreviewKind Kind);
