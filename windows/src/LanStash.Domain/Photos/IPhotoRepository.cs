namespace LanStash.Domain;

/// <summary>
/// 仅使用公开 File Station API 的只读文件系统照片契约。
/// </summary>
public interface IPhotoRepository
{
    Guid ProfileId { get; }

    Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(
        CancellationToken cancellationToken = default);

    Task<PhotoPage> ListFolderAsync(
        PhotoSpace space,
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken = default);

    Task<PhotoTimelineSnapshot> LoadTimelineAsync(
        PhotoSpace space,
        PhotoTimelineLimits? limits = null,
        CancellationToken cancellationToken = default) =>
        Task.FromException<PhotoTimelineSnapshot>(
            new NotSupportedException("The repository does not implement a bounded photo timeline."));

    Task<PhotoThumbnail> GetThumbnailAsync(
        PhotoItem item,
        PhotoThumbnailSize size,
        CancellationToken cancellationToken = default);
}
