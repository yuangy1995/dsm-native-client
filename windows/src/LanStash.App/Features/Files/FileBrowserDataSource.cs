using LanStash.Domain;

namespace LanStash.App.Features.Files;

public interface IFileBrowserDataSource
{
    Task<FilePage> LoadPageAsync(
        string path,
        int offset,
        int limit,
        FileListOptions options,
        CancellationToken cancellationToken);
}

public sealed class RepositoryFileBrowserDataSource(IDsmRepository repository) : IFileBrowserDataSource
{
    internal const int SharedRootPageSize = 500;

    public Task<FilePage> LoadPageAsync(
        string path,
        int offset,
        int limit,
        FileListOptions options,
        CancellationToken cancellationToken) =>
        repository.ListFilesAsync(
            path,
            offset,
            string.IsNullOrWhiteSpace(path) ? Math.Max(limit, SharedRootPageSize) : limit,
            options,
            cancellationToken);
}
