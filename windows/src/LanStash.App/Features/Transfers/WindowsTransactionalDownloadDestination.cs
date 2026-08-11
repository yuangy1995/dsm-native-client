using Windows.Storage;
using Windows.Storage.Streams;

namespace LanStash.App.Features.Transfers;

internal sealed class WindowsTransactionalDownloadDestination : ITransactionalDownloadDestination
{
    private readonly StorageFolder _targetFolder;
    private readonly string _targetName;
    private readonly StorageFile _stagingFile;
    private readonly StorageStreamTransaction _transaction;
    private readonly bool _allowReplaceExisting;
    private readonly bool _validateZipArchive;
    private ulong _position;
    private bool _transactionClosed;
    private bool _committed;
    private bool _disposed;

    private WindowsTransactionalDownloadDestination(
        StorageFolder targetFolder,
        string targetName,
        StorageFile stagingFile,
        StorageStreamTransaction transaction,
        bool allowReplaceExisting,
        bool validateZipArchive)
    {
        _targetFolder = targetFolder;
        _targetName = targetName;
        _stagingFile = stagingFile;
        _transaction = transaction;
        _allowReplaceExisting = allowReplaceExisting;
        _validateZipArchive = validateZipArchive;
        _transaction.Stream.Size = 0;
    }

    public static async Task<WindowsTransactionalDownloadDestination> CreateAsync(
        string targetPath,
        bool allowReplaceExisting = true,
        bool validateZipArchive = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetPath);
        var directory = Path.GetDirectoryName(targetPath);
        var targetName = Path.GetFileName(targetPath);
        if (string.IsNullOrWhiteSpace(directory) || string.IsNullOrWhiteSpace(targetName))
        {
            throw new ArgumentException("The selected target path is incomplete.", nameof(targetPath));
        }

        var folder = await StorageFolder.GetFolderFromPathAsync(directory);
        var staging = await folder.CreateFileAsync(
            $".lanstash-{Guid.NewGuid():N}.download",
            CreationCollisionOption.FailIfExists);
        StorageStreamTransaction? transaction = null;
        try
        {
            transaction = await staging.OpenTransactedWriteAsync();
            return new WindowsTransactionalDownloadDestination(
                folder,
                targetName,
                staging,
                transaction,
                allowReplaceExisting,
                validateZipArchive);
        }
        catch
        {
            transaction?.Dispose();
            await staging.DeleteAsync(StorageDeleteOption.PermanentDelete);
            throw;
        }
    }

    public async ValueTask WriteAsync(
        ReadOnlyMemory<byte> bytes,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();

        using var output = _transaction.Stream.GetOutputStreamAt(_position);
        using var writer = new DataWriter(output);
        writer.WriteBytes(bytes.ToArray());
        await writer.StoreAsync().AsTask(cancellationToken);
        await writer.FlushAsync().AsTask(cancellationToken);
        writer.DetachStream();
        _position += checked((ulong)bytes.Length);
    }

    public async ValueTask CommitAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        _transaction.Stream.Size = _position;
        await _transaction.CommitAsync();
        CloseTransaction();
        if (_validateZipArchive)
        {
            await ValidateZipArchiveAsync(_stagingFile, cancellationToken);
        }

        if (!_allowReplaceExisting)
        {
            await _stagingFile.MoveAsync(
                _targetFolder,
                _targetName,
                NameCollisionOption.FailIfExists);
        }
        else
        {
            var target = await _targetFolder.TryGetItemAsync(_targetName) as StorageFile;
            if (target is null)
            {
                await _stagingFile.MoveAsync(
                    _targetFolder,
                    _targetName,
                    NameCollisionOption.FailIfExists);
            }
            else
            {
                await _stagingFile.MoveAndReplaceAsync(target);
            }
        }
        _committed = true;
    }

    private static async Task ValidateZipArchiveAsync(
        StorageFile stagingFile,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        await using var stream = await stagingFile.OpenStreamForReadAsync();
        FolderArchiveValidator.Validate(stream);
        cancellationToken.ThrowIfCancellationRequested();
    }

    public ValueTask AbortAsync(CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        CloseTransaction();
        return ValueTask.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        CloseTransaction();
        if (!_committed)
        {
            await _stagingFile.DeleteAsync(StorageDeleteOption.PermanentDelete);
        }
    }

    private void CloseTransaction()
    {
        if (_transactionClosed)
        {
            return;
        }
        _transactionClosed = true;
        _transaction.Dispose();
    }
}
