using LanStash.Domain;

namespace LanStash.App.Features.Photos;

public interface IPhotoBrowserDataSource
{
    Guid ProfileId { get; }

    Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken);

    Task<PhotoPage> LoadPageAsync(
        PhotoSpace space,
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken);

    Task<PhotoThumbnail> LoadThumbnailAsync(
        PhotoItem item,
        PhotoThumbnailSize size,
        CancellationToken cancellationToken);
}

public sealed class RepositoryPhotoBrowserDataSource(IPhotoRepository repository)
    : IPhotoBrowserDataSource
{
    public Guid ProfileId => repository.ProfileId;

    public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(
        CancellationToken cancellationToken) =>
        repository.DiscoverSpacesAsync(cancellationToken);

    public Task<PhotoPage> LoadPageAsync(
        PhotoSpace space,
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken) =>
        repository.ListFolderAsync(space, path, offset, limit, cancellationToken);

    public Task<PhotoThumbnail> LoadThumbnailAsync(
        PhotoItem item,
        PhotoThumbnailSize size,
        CancellationToken cancellationToken) =>
        repository.GetThumbnailAsync(item, size, cancellationToken);
}
