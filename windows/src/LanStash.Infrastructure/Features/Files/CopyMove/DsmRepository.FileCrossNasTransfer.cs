using LanStash.Domain;
using LanStash.Infrastructure.Transport;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private async Task<MutationResult> CopyCrossNasFileAsync(CrossNasTransfer transfer, DsmRepository target, CrossNasTransferItem item,
        long completed, IProgress<long>? progress, CancellationToken token)
    {
        var size = item.Source.Item.Size;
        FileRangeReadResult? first = null;
        try
        {
            if (size > 0)
            {
                first = await ReadFileRangeResultAsync(item.Source.Item.Path, 0, Math.Min(CrossNasChunkSize, size), null, size, token).ConfigureAwait(false);
                EnsureCrossNasRange(first, 0, size);
            }
        }
        catch (OperationCanceledException) { return UploadCancelled(); }
        catch (Exception error)
        {
            return UploadFailure(error is DsmException { AuthenticationFailure: true } ? MutationErrorCategory.Authentication : MutationErrorCategory.Network,
                "file.cross-nas.source-range-invalid");
        }

        using var pipe = new BoundedMemoryStream(CrossNasPipeCapacity);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token);
        long downloaded = 0, uploaded = 0;
        void Report() => progress?.Report(checked(completed + Volatile.Read(ref downloaded) + Volatile.Read(ref uploaded)));
        // 管道带背压，两端均在工作线程消费；目标预检拒绝也必须唤醒源端。
        var uploadTask = Task.Run(async () =>
        {
            try
            {
                using var content = new BoundedMemoryReadStream(pipe);
                var result = await target.UploadFileCoreAsync(new(content, size, MutationParent(item.DestinationPath),
                    item.Source.Item.Name, overwrite: false, item.UploadId),
                    new CrossNasProgress(value => { Interlocked.Exchange(ref uploaded, value); Report(); }), linked.Token, async pending =>
                    { item.Upload = pending; transfer.HasSubmitted = true; await SaveCrossNasAsync(transfer).ConfigureAwait(false); }).ConfigureAwait(false);
                lock (target.ServiceMutations.FileUploads)
                    item.Upload = target.ServiceMutations.FileUploads.GetValueOrDefault((target.ServiceScope(), item.DestinationPath));
                return result;
            }
            finally { pipe.Cancel(); linked.Cancel(); }
        }, CancellationToken.None);
        Exception? sourceError = null;
        try
        {
            await Task.Run(async () =>
            {
                var offset = 0L; var segment = first;
                string? version = first?.ServerContentVersion;
                while (offset < size)
                {
                    linked.Token.ThrowIfCancellationRequested();
                    EnsureCrossNasRange(segment!, offset, size);
                    await pipe.WriteAsync(segment!.Bytes, linked.Token).ConfigureAwait(false);
                    offset += segment.ActualByteCount;
                    Interlocked.Exchange(ref downloaded, offset); Report();
                    if (offset < size)
                    {
                        segment = await ReadFileRangeResultAsync(item.Source.Item.Path, offset, Math.Min(CrossNasChunkSize, size - offset),
                            version, size, linked.Token).ConfigureAwait(false);
                        if (segment.ServerContentVersion != version)
                            throw new InvalidDataException("file.cross-nas.source-version-changed");
                    }
                }
                pipe.CompleteWrite();
            }, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error) { sourceError = error; pipe.Cancel(error); linked.Cancel(); }
        var outcome = await uploadTask.ConfigureAwait(false);
        if (outcome.Status != MutationResultStatus.ConfirmedSuccess) return outcome;
        if (sourceError is not null || !CrossNasSameMetadata(await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false), item.Source))
            return UploadUnverified("file.cross-nas.source-changed", MutationErrorCategory.Conflict);
        Report();
        return outcome;
    }

    private static async Task<IReadOnlyList<CrossNasTreeItem>> LoadCrossNasTreeAsync(DsmRepository repository, string rootPath, CancellationToken token)
    {
        var result = new List<CrossNasTreeItem>();
        var pending = new Queue<(string Path, string Relative, int Depth)>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        pending.Enqueue((rootPath, string.Empty, 0));
        while (pending.TryDequeue(out var current))
        {
            if (current.Depth > CrossNasFolderDepthLimit) throw new InvalidDataException("file.cross-nas.tree-too-deep");
            var children = await LoadCrossNasChildrenAsync(repository, current.Path, token).ConfigureAwait(false);
            foreach (var item in children)
            {
                if (!seen.Add(item.Path) || result.Count >= CrossNasFolderItemLimit || ArchiveContainsRecycleSegment(item.Path))
                    throw new InvalidDataException("file.cross-nas.invalid-tree-item");
                var relative = current.Relative.Length == 0 ? item.Name : current.Relative + "/" + item.Name;
                result.Add(new(item, relative));
                if (item.IsDirectory) pending.Enqueue((item.Path, relative, current.Depth + 1));
            }
        }
        return result;
    }
    private static async Task<IReadOnlyList<FileItem>> LoadCrossNasChildrenAsync(DsmRepository repository, string path, CancellationToken token)
    {
        var result = new List<FileItem>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        int? total = null; var offset = 0;
        while (true)
        {
            var page = await repository.ListFilesAsync(path, offset, CrossNasFolderPageSize, token).ConfigureAwait(false);
            if (page.Offset != offset || page.Total < 0 || total is not null && total != page.Total ||
                page.Items.Count > CrossNasFolderPageSize || page.Items.Count == 0 && offset < page.Total)
                throw new InvalidDataException("file.cross-nas.invalid-tree-page");
            total ??= page.Total;
            foreach (var item in page.Items)
            {
                if (!seen.Add(item.Path) || !ValidMutationItemName(item.Name) || item.Path != JoinMutationPath(path, item.Name))
                    throw new InvalidDataException("file.cross-nas.invalid-tree-item");
                result.Add(item);
            }
            offset = checked(offset + page.Items.Count);
            if (offset >= page.Total) break;
        }
        if (result.Count != total) throw new InvalidDataException("file.cross-nas.invalid-tree-total");
        return result;
    }
    private static void EnsureCrossNasRange(FileRangeReadResult result, long start, long total)
    {
        var length = Math.Min(CrossNasChunkSize, total - start);
        if (result.StatusCode is not (200 or 206) || result.RequestedStart != start || result.RequestedLength != length ||
            result.ResponseStart != start || result.ResponseLength != length || result.TotalLength != total ||
            result.ActualByteCount != length || result.Bytes.LongLength != length ||
            total > length && (!result.CanSafelyReadInSegments || string.IsNullOrEmpty(result.ServerContentVersion)))
            throw new InvalidDataException("file.cross-nas.invalid-range-contract");
    }
    private sealed record CrossNasTreeItem(FileItem Item, string RelativePath);
    private sealed class CrossNasProgress(Action<long> report) : IProgress<long>
    { public void Report(long value) => report(value); }
    private sealed class BoundedMemoryReadStream(BoundedMemoryStream pipe) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => pipe.ReadAsync(buffer.AsMemory(offset, count)).GetAwaiter().GetResult();
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken token) => pipe.ReadAsync(buffer.AsMemory(offset, count), token);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) => new(pipe.ReadAsync(buffer, token));
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
