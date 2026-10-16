namespace LanStash.Domain;

public enum SynologyPhotoDownloadFormat { Original, OptimizedJpeg, OriginalSizeJpeg }
public sealed record SynologyPhotoDownloadResult(SynologyPhotoDownloadFormat Format, long Length);
public sealed record SynologyPhotoBinaryResult(string ContentType, long Length);

/// <summary>完整集合导出使用固定对象快照，不能用已加载的一页替代完整目标。</summary>
public abstract record SynologyPhotoArchiveTarget
{
    public sealed record Album(SynologyPhotoAlbum Value) : SynologyPhotoArchiveTarget;
    public sealed record Folder(SynologyPhotoFolder Value) : SynologyPhotoArchiveTarget;
    public sealed record Selection(IReadOnlyList<SynologyPhoto> Photos, IReadOnlyList<SynologyPhotoFolder> Folders) : SynologyPhotoArchiveTarget;
}
