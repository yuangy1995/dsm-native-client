using System.Buffers;
using System.Diagnostics;
using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

/// <summary>媒体或完整归档先在私有临时文件验证，再通过现有事务目标原子提升；不扫描文件夹。</summary>
internal sealed class SynologyPhotoSaveService
{
    public async Task SaveAsync(ISynologyPhotosRepository repository, SynologyPhoto photo,
        string temporaryDirectory, Func<Task<ITransactionalDownloadDestination>> destinationFactory,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        => _ = await SaveAsync(repository, photo, SynologyPhotoDownloadFormat.Original, temporaryDirectory,
            _ => destinationFactory(), progress, cancellationToken).ConfigureAwait(false);

    public Task<SynologyPhotoDownloadResult> SaveAsync(ISynologyPhotosRepository repository, SynologyPhoto photo, SynologyPhotoDownloadFormat format,
        string temporaryDirectory, Func<SynologyPhotoDownloadResult, Task<ITransactionalDownloadDestination>> destinationFactory,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        if (photo.Id.ProfileId != repository.ProfileId || !Enum.IsDefined(photo.Id.Space))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SaveCoreAsync(path => repository.DownloadAsync(photo, format, path, progress, cancellationToken), temporaryDirectory, destinationFactory, cancellationToken);
    }

    public Task<SynologyPhotoDownloadResult> SaveArchiveAsync(ISynologyPhotosRepository repository, SynologyPhotoArchiveTarget target, SynologyPhotoDownloadFormat format,
        string temporaryDirectory, Func<Task<ITransactionalDownloadDestination>> destinationFactory,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default) =>
        SaveCoreAsync(async path => new(format, await repository.DownloadArchiveAsync(target, format, path, progress, cancellationToken).ConfigureAwait(false)),
            temporaryDirectory, _ => destinationFactory(), cancellationToken);

    private static async Task<SynologyPhotoDownloadResult> SaveCoreAsync(Func<string, Task<SynologyPhotoDownloadResult>> download, string temporaryDirectory,
        Func<SynologyPhotoDownloadResult, Task<ITransactionalDownloadDestination>> destinationFactory, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(temporaryDirectory);
        var temporary = Path.Combine(temporaryDirectory, $"{Guid.NewGuid():N}.photos-original");
        try
        {
            var result = await download(temporary).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (result.Length <= 0 || new FileInfo(temporary).Length != result.Length) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
            await using var destination = await destinationFactory(result).ConfigureAwait(false);
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
                    if (copied > result.Length) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                    await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                }
                if (copied != result.Length) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                cancellationToken.ThrowIfCancellationRequested();
                await destination.CommitAsync(cancellationToken).ConfigureAwait(false); committed = true;
                return result;
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

    internal static async Task<IReadOnlyList<SynologyPhoto>> ExpandSelectionAsync(ISynologyPhotosRepository repository,
        IReadOnlyList<SynologyPhoto> selection, CancellationToken token)
    {
        var result = new List<SynologyPhoto>(); var photos = new Dictionary<SynologyPhotoIdentity, SynologyPhoto>();
        var groups = new HashSet<(SynologyPhotoSpace, long)>();
        foreach (var photo in selection)
        {
            token.ThrowIfCancellationRequested();
            if (photo.Id.ProfileId != repository.ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            if (photo.SimilarGroup is { } group)
            {
                if (!groups.Add((photo.Id.Space, group.Id))) continue;
                var detail = await repository.SimilarGroupAsync(group.Id, photo.Id.Space, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (detail is null || detail.Group.Id != group.Id || detail.Group.Space != photo.Id.Space ||
                    detail.Photos.Count != detail.Group.Count || !detail.Group.PhotoIds.ToHashSet().SetEquals(detail.Photos.Select(value => value.Id.ItemId)) ||
                    detail.Photos.DistinctBy(value => value.Id).Count() != detail.Photos.Count ||
                    detail.Photos.Any(value => value.Id.ProfileId != repository.ProfileId || value.Id.Space != photo.Id.Space))
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                foreach (var member in detail.Photos) Add(member);
            }
            else Add(photo);
        }
        return result;
        void Add(SynologyPhoto photo)
        {
            if (photos.TryGetValue(photo.Id, out var existing))
            { if (!existing.IsSameDeletionTarget(photo) || existing.AlbumContext != photo.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged); }
            else { photos.Add(photo.Id, photo); result.Add(photo); }
        }
    }

    internal static string AvailablePath(string directory, string originalName, SynologyPhotoDownloadFormat actualFormat)
    {
        if (!BoundedFileDownloadBatch.IsValidLocalName(originalName)) throw new IOException("photos.invalid-local-name");
        var name = actualFormat == SynologyPhotoDownloadFormat.Original ? originalName : Path.ChangeExtension(originalName, ".jpg");
        var stem = Path.GetFileNameWithoutExtension(name); var extension = Path.GetExtension(name); var index = 0;
        string path;
        do { path = ForegroundDownloadDirectoryLease.Resolve(directory, index == 0 ? name : $"{stem} ({index}){extension}"); index++; }
        while (File.Exists(path) || Directory.Exists(path));
        return path;
    }
}
