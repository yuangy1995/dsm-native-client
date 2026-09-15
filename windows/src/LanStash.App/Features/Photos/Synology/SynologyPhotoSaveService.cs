using System.Buffers;
using System.Diagnostics;
using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

/// <summary>原件先在私有临时文件中完成验证，再通过现有事务目标原子提升；不扫描文件夹。</summary>
internal sealed class SynologyPhotoSaveService
{
    public async Task SaveAsync(ISynologyPhotosRepository repository, SynologyPhoto photo,
        string temporaryDirectory, Func<Task<ITransactionalDownloadDestination>> destinationFactory,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        if (photo.Id.ProfileId != repository.ProfileId || photo.Id.Space != SynologyPhotoSpace.Personal)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(temporaryDirectory);
        var temporary = Path.Combine(temporaryDirectory, $"{Guid.NewGuid():N}.photos-original");
        try
        {
            await repository.DownloadOriginalAsync(photo, temporary, progress, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (new FileInfo(temporary).Length != photo.SizeBytes) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
            await using var destination = await destinationFactory().ConfigureAwait(false);
            var committed = false;
            var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
            try
            {
                await using var input = new FileStream(temporary, FileMode.Open, FileAccess.Read, FileShare.Read,
                    64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
                long copied = 0;
                while (true)
                {
                    var count = await input.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                    if (count == 0) break;
                    copied = checked(copied + count);
                    if (copied > photo.SizeBytes) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                    await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                }
                if (copied != photo.SizeBytes) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                cancellationToken.ThrowIfCancellationRequested();
                await destination.CommitAsync(cancellationToken).ConfigureAwait(false); committed = true;
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
                if (!committed) await destination.AbortAsync(CancellationToken.None).ConfigureAwait(false);
            }
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { Trace.TraceWarning("photos.original.cleanup: {0}", error.GetType().Name); }
        }
    }
}
