using LanStash.App.Features.Transfers;
using LanStash.Domain;
using System.Diagnostics;
using Windows.Storage;

namespace LanStash.App.Features.Files.Preview;

public interface IFilePreviewArtifact : IAsyncDisposable
{
    StorageFile? File { get; }
    string Path { get; }
}

public sealed class FilePreviewArtifact : IFilePreviewArtifact
{
    private readonly StorageFolder _directory;
    private readonly StorageFile _file;
    private readonly SemaphoreSlim _cleanup = new(1, 1);
    private int _cleanupAttempts;
    private bool _disposed;

    internal FilePreviewArtifact(StorageFolder directory, StorageFile file)
    {
        _directory = directory;
        _file = file;
    }

    public StorageFile? File => _file;
    public string Path => _file.Path;

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }
        await _cleanup.WaitAsync();
        try
        {
            if (_disposed || _cleanupAttempts >= 3)
            {
                return;
            }
            while (!_disposed && _cleanupAttempts < 3)
            {
                _cleanupAttempts++;
                try
                {
                    await _directory.DeleteAsync(StorageDeleteOption.PermanentDelete);
                    _disposed = true;
                }
                catch (FileNotFoundException)
                {
                    _disposed = true;
                }
                catch (Exception cleanupFailure)
                {
                    // 删除失败不抢先宣告已释放；单次关闭会在有界次数内完成重试。
                    Trace.TraceWarning(
                        "Preview artifact cleanup attempt failed with {0}.",
                        cleanupFailure.GetType().FullName ?? cleanupFailure.GetType().Name);
                }
            }
        }
        finally
        {
            _cleanup.Release();
        }
    }
}

internal interface IFilePreviewArtifactStore
{
    Task<IFilePreviewArtifact> PrepareAsync(
        IFileRangeReader repository,
        FileItem item,
        IProgress<ForegroundTransferProgress>? progress,
        CancellationToken cancellationToken);
}

internal sealed class FilePreviewArtifactStore : IFilePreviewArtifactStore
{
    private const string RootName = "LanStashPreviews";
    private readonly SafeFileDownloadService _downloads = new();

    public async Task<IFilePreviewArtifact> PrepareAsync(
        IFileRangeReader repository,
        FileItem item,
        IProgress<ForegroundTransferProgress>? progress,
        CancellationToken cancellationToken)
    {
        var temporary = ApplicationData.Current.TemporaryFolder;
        var root = await temporary.CreateFolderAsync(
            RootName,
            CreationCollisionOption.OpenIfExists);
        var operation = await root.CreateFolderAsync(
            Guid.NewGuid().ToString("N"),
            CreationCollisionOption.FailIfExists);
        var extension = FilePreviewClassifier.SafeExtension(item);
        var fileName = string.IsNullOrEmpty(extension)
            ? Guid.NewGuid().ToString("N")
            : $"{Guid.NewGuid():N}.{extension}";
        var targetPath = Path.Combine(operation.Path, fileName);
        try
        {
            var destination = await WindowsTransactionalDownloadDestination.CreateAsync(targetPath);
            await _downloads.DownloadAsync(
                repository,
                item.Path,
                item.Size,
                destination,
                progress,
                cancellationToken);
            var file = await operation.GetFileAsync(fileName);
            return new FilePreviewArtifact(operation, file);
        }
        catch
        {
            try
            {
                await operation.DeleteAsync(StorageDeleteOption.PermanentDelete);
            }
            catch (FileNotFoundException)
            {
            }
            catch (Exception cleanupFailure)
            {
                Trace.TraceWarning(
                    "Preview artifact cleanup failed with {0}.",
                    cleanupFailure.GetType().FullName ?? cleanupFailure.GetType().Name);
            }
            throw;
        }
    }
}
