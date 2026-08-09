using LanStash.Domain;
using LanStash.App.Features.Photos;

namespace LanStash.App.Features.Photos.Timeline;

public interface IPhotoTimelineDataSource : IPhotoBrowserDataSource
{
    Task<PhotoTimelineSnapshot> LoadAsync(PhotoSpace space, CancellationToken cancellationToken);
}

public sealed class RepositoryPhotoTimelineDataSource(IPhotoRepository repository) : IPhotoTimelineDataSource
{
    public Guid ProfileId => repository.ProfileId;

    public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) =>
        repository.DiscoverSpacesAsync(cancellationToken);

    public Task<PhotoPage> LoadPageAsync(
        PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken) =>
        repository.ListFolderAsync(space, path, offset, limit, cancellationToken);

    public Task<PhotoTimelineSnapshot> LoadAsync(PhotoSpace space, CancellationToken cancellationToken) =>
        repository.LoadTimelineAsync(space, PhotoTimelineLimits.Default, cancellationToken);

    public Task<PhotoThumbnail> LoadThumbnailAsync(
        PhotoItem item,
        PhotoThumbnailSize size,
        CancellationToken cancellationToken) =>
        repository.GetThumbnailAsync(item, size, cancellationToken);
}
