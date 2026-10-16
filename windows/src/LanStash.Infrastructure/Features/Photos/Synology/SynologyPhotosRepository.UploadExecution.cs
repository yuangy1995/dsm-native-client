using System.Security.Cryptography;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<SynologyPhotoUploadBatch> ContinueUploadAsync(Guid batchId,
        IReadOnlyList<SynologyPhotoUploadSource>? sources = null, CancellationToken cancellationToken = default)
    {
        await LoadUploadsAsync().ConfigureAwait(false); var task = OwnedUpload(batchId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return UploadSnapshot(task);
        task.Running = true; task.Stop = false; task.CancelRemaining = false;
        var ownerGate = _uploads.OwnerGates.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var ownsExecution = false;
        try
        {
            // 同一账号的队列顺序执行；目录与相册成员检查不会被本客户端的另一批次穿插。
            await ownerGate.WaitAsync(cancellationToken).ConfigureAwait(false); ownsExecution = true;
            if (sources is not null) await RebindUploadSourcesAsync(task, sources, cancellationToken).ConfigureAwait(false);
            await ReviewUploadCoreAsync(task, cancellationToken).ConfigureAwait(false);
            for (var index = 0; index < task.Record.Items.Length && !task.Stop && !task.Record.Items.Any(item => item.State == SynologyPhotoUploadState.PendingReview); index++)
            {
                var entry = task.Record.Items[index];
                if (entry.State is SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled) continue;
                try
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    _ = await CheckUploadTargetAsync(task, cancellationToken).ConfigureAwait(false);
                    if (entry.Photo is null)
                    {
                        if (!task.Sources.ContainsKey(entry.Id)) continue;
                        if (!await ResolveUploadDirectoriesAsync(task, index, cancellationToken).ConfigureAwait(false)) break;
                        if (task.Stop) break;
                        await SendUploadItemAsync(task, index, cancellationToken).ConfigureAwait(false);
                    }
                    entry = task.Record.Items[index];
                    if (entry.State == SynologyPhotoUploadState.PendingReview) break;
                    if (!task.Stop && entry.Photo is not null && task.Record.Target is { DirectToAlbum: false, AlbumId: not null } &&
                        entry.State is SynologyPhotoUploadState.Uploaded or SynologyPhotoUploadState.Failed)
                        await AddUploadedItemAsync(task, index, cancellationToken).ConfigureAwait(false);
                    if (task.Record.Items[index].State == SynologyPhotoUploadState.PendingReview) break;
                }
                catch (OperationCanceledException)
                {
                    entry = task.Record.Items[index];
                    if (entry.State is SynologyPhotoUploadState.Uploading or SynologyPhotoUploadState.PreparingFolders or SynologyPhotoUploadState.AddingToAlbum)
                        await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.PendingReview }).ConfigureAwait(false);
                    break;
                }
                catch (Exception error) when (error is SynologyPhotoException or DsmException or IOException or UnauthorizedAccessException or HttpRequestException or ObjectDisposedException)
                {
                    RequireUploadStore();
                    entry = task.Record.Items[index];
                    if (entry.State is SynologyPhotoUploadState.Uploading or SynologyPhotoUploadState.PreparingFolders or SynologyPhotoUploadState.AddingToAlbum)
                        await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.PendingReview }).ConfigureAwait(false);
                    else if (entry.State != SynologyPhotoUploadState.PendingReview)
                        await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Failed,
                            Failure = UploadFailure(error) }).ConfigureAwait(false);
                    if (task.Record.Items[index].State == SynologyPhotoUploadState.PendingReview) break;
                }
            }
        }
        finally
        {
            try { if (task.CancelRemaining) await CancelUnstartedUploadItemsAsync(task).ConfigureAwait(false); }
            finally { task.Running = false; if (ownsExecution) ownerGate.Release(); task.Gate.Release(); }
        }
        return UploadSnapshot(task);
    }

    public async Task StopUploadAsync(Guid batchId, bool cancelRemaining = false)
    {
        await LoadUploadsAsync().ConfigureAwait(false); var task = OwnedUpload(batchId);
        task.Stop = true; task.CancelRemaining = cancelRemaining;
        // 上传中的一次请求不中途重放或假装取消；当前项目结束后停止。
        if (!await task.Gate.WaitAsync(0).ConfigureAwait(false)) return;
        try { if (cancelRemaining) await CancelUnstartedUploadItemsAsync(task).ConfigureAwait(false); }
        finally { task.Gate.Release(); }
    }
    private async Task CancelUnstartedUploadItemsAsync(PhotoUploadTask task)
    {
        task.Record = task.Record with { Items = task.Record.Items.Select(item => item.State is
            SynologyPhotoUploadState.Queued or SynologyPhotoUploadState.Uploaded or SynologyPhotoUploadState.Failed
                ? item with { State = SynologyPhotoUploadState.Cancelled } : item).ToArray() };
        await SaveUploadAsync(task).ConfigureAwait(false);
    }
    private static async Task RebindUploadSourcesAsync(PhotoUploadTask task, IReadOnlyList<SynologyPhotoUploadSource> sources, CancellationToken token)
    {
        var bindings = new Dictionary<Guid, string>();
        foreach (var source in sources)
        {
            var file = await ReadUploadSourceAsync(source, token).ConfigureAwait(false);
            var matches = task.Record.Items.Where(item => item.File.Name == file.Name &&
                item.File.Length == file.Length && item.File.ModifiedAt == file.ModifiedAt && item.File.Sha256 == file.Sha256 &&
                (file.Directories.Count == 0 || item.File.Directories.SequenceEqual(file.Directories))).ToArray();
            if (matches.Length != 1) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (matches[0].Photo is not null || matches[0].State == SynologyPhotoUploadState.Cancelled) continue;
            if (!bindings.TryAdd(matches[0].Id, Path.GetFullPath(source.Path)))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        foreach (var (id, path) in bindings) task.Sources[id] = path;
    }
    private async Task<bool> ResolveUploadDirectoriesAsync(PhotoUploadTask task, int index, CancellationToken token)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        var entry = task.Record.Items[index];
        if (entry.File.Directories.Count == 0)
        {
            await SetUploadEntryAsync(task, index, entry with { FolderId = task.Record.Target.FolderId }).ConfigureAwait(false); return true;
        }
        var parent = task.Record.Root?.Id ?? throw Invalid();
        _ = Capability("Browse.Folder", 1, task.Record.Target.Space);
        foreach (var name in entry.File.Directories)
        {
            await CheckManagedFolderConflictsAsync(parent, task.Record.Target.Space, name, token).ConfigureAwait(false);
            if (task.Stop) return false;
            if (_uploads.Tasks.Values.Where(other => other.Record.Id != task.Record.Id && other.Record.Owner == task.Record.Owner && other.Record.Target.Space == task.Record.Target.Space)
                .SelectMany(other => other.Record.Items).Any(item => item.Step == SynologyPhotoUploadStep.CreateFolder &&
                    item.State == SynologyPhotoUploadState.PendingReview && item.FolderParent == parent && item.FolderName == name))
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var cached = task.Record.Folders.SingleOrDefault(folder => folder.Parent == parent && folder.Name == name);
            if (cached is not null)
            {
                var fresh = await WritableUploadFolderAsync(cached.Id, task.Record.Target.Space, token).ConfigureAwait(false);
                if (fresh.ParentId != parent || fresh.Name != name) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                parent = cached.Id; continue;
            }
            _ = await WritableUploadFolderAsync(parent, task.Record.Target.Space, token).ConfigureAwait(false);
            SynologyPhotoCollection? found = null; var seen = new HashSet<long>();
            for (var offset = 0; ; offset = checked(offset + 100))
            {
                var page = await FoldersAsync(parent, offset, 100, token, task.Record.Target.Space).ConfigureAwait(false);
                foreach (var folder in page)
                {
                    if (!seen.Add(folder.Id)) throw Invalid();
                    if (folder.Name != name) continue;
                    if (found is not null) throw Invalid(); found = folder;
                }
                if (page.Count < 100) break;
            }
            if (found is not null)
            {
                var fresh = await WritableUploadFolderAsync(found.Id, task.Record.Target.Space, token).ConfigureAwait(false);
                if (fresh.ParentId != parent || fresh.Name != name) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                task.Record = task.Record with { Folders = [.. task.Record.Folders, new(parent, name, found.Id)] };
                await SaveUploadAsync(task).ConfigureAwait(false); parent = found.Id; continue;
            }
            RequireGeneration(generation, token); RequireAccess(task.Record.Target.Space); if (task.Stop) return false;
            entry = task.Record.Items[index] with { State = SynologyPhotoUploadState.PreparingFolders, Step = SynologyPhotoUploadStep.CreateFolder,
                FolderParent = parent, FolderName = name, ReceiptId = null, Accepted = false, Rejected = false, Failure = null };
            await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
            if (generation != Volatile.Read(ref _accessGeneration) || token.IsCancellationRequested || task.Stop)
            {
                await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Queued, Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false);
                return false;
            }
            var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Browse.Folder", 1, task.Record.Target.Space), 1, "create",
                Parameters(("target_id", parent), ("name", name)), token).ConfigureAwait(false);
            entry = entry with { State = SynologyPhotoUploadState.PendingReview, Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted };
            if (receipt.Status == SynologyPhotoWriteStatus.Rejected)
            {
                await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Failed, Rejected = true, Failure = receipt.Failure }).ConfigureAwait(false);
                return false;
            }
            if (entry.Accepted)
            {
                try { entry = entry with { ReceiptId = Positive(Object(receipt.Data?["folder"]), "id") }; }
                catch (SynologyPhotoException) { /* 丢失有效编号时保留未知，不按名称重建。 */ }
            }
            await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
            await ReviewUploadEntryAsync(task, index, token).ConfigureAwait(false);
            if (task.Record.Items[index].State == SynologyPhotoUploadState.PendingReview) return false;
            parent = task.Record.Items[index].FolderId ?? throw Invalid();
        }
        await SetUploadEntryAsync(task, index, task.Record.Items[index] with { FolderId = parent, State = SynologyPhotoUploadState.Queued, Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false);
        return true;
    }

    private async Task SendUploadItemAsync(PhotoUploadTask task, int index, CancellationToken token)
    {
        var entry = task.Record.Items[index]; var target = task.Record.Target;
        var generation = Volatile.Read(ref _accessGeneration);
        var rights = await CheckUploadTargetAsync(task, token).ConfigureAwait(false);
        if (entry.FolderId is { } folder) _ = await WritableUploadFolderAsync(folder, target.Space, token).ConfigureAwait(false);
        if (!task.Sources.TryGetValue(entry.Id, out var path)) return;
        var info = new FileInfo(path);
        if (!info.Exists || (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length != entry.File.Length ||
            new DateTimeOffset(info.LastWriteTimeUtc) != entry.File.ModifiedAt) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await using var source = OpenUploadFile(path);
        if (source.Length != entry.File.Length || Convert.ToHexString(await SHA256.HashDataAsync(source, token).ConfigureAwait(false)) != entry.File.Sha256)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        source.Position = 0;
        RequireGeneration(generation, token); if (task.Stop) return;
        entry = entry with { State = SynologyPhotoUploadState.Uploading, Step = SynologyPhotoUploadStep.Upload,
            ReceiptId = null, Accepted = false, Rejected = false, UploadAction = null, Failure = null };
        await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
        if (generation != Volatile.Read(ref _accessGeneration) || token.IsCancellationRequested || task.Stop)
        {
            await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Queued, Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false); return;
        }
        var transport = new SynologyPhotoUploadTransport(entry.File.Name, entry.File.Length, entry.File.ModifiedAt, target.Duplicate,
            target.DirectToAlbum ? null : entry.FolderId, target.DirectToAlbum && rights?.Passphrase is null ? target.AlbumId : null,
            target.DirectToAlbum ? rights?.Passphrase : null);
        var receipt = await _api.UploadPhotoAsync(_profile, _session, Capability("Upload.Item", 1, target.DirectToAlbum ? null : target.Space),
            transport, source, new PhotoUploadProgress(value => task.Progress[entry.Id] = Math.Clamp(value, 0, entry.File.Length)), token).ConfigureAwait(false);
        entry = entry with { State = SynologyPhotoUploadState.PendingReview, Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted };
        if (receipt.Status == SynologyPhotoWriteStatus.Rejected)
            entry = entry with { State = SynologyPhotoUploadState.Failed, Rejected = true, Failure = receipt.Failure };
        else if (entry.Accepted)
        {
            try
            {
                var id = Positive(receipt.Data ?? throw Invalid(), "id"); var action = OptionalText(receipt.Data!, "action");
                if (action == "ignore" && target.Duplicate != SynologyPhotoDuplicatePolicy.Skip) throw Invalid();
                entry = entry with { ReceiptId = id, UploadAction = action };
            }
            catch (SynologyPhotoException) { /* 成功包络缺少合法回执仍属未知，不可再次发送文件。 */ }
        }
        await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
        if (entry.State == SynologyPhotoUploadState.PendingReview) await ReviewUploadEntryAsync(task, index, token).ConfigureAwait(false);
    }
    private async Task AddUploadedItemAsync(PhotoUploadTask task, int index, CancellationToken token)
    {
        var entry = task.Record.Items[index]; var photo = entry.Photo ?? throw Invalid(); var albumId = task.Record.Target.AlbumId ?? throw Invalid();
        var generation = Volatile.Read(ref _accessGeneration);
        var rights = await CheckUploadTargetAsync(task, token).ConfigureAwait(false) ?? throw Invalid();
        var current = await DetailsAsync(photo, token).ConfigureAwait(false);
        if (!current.IsSameDeletionTarget(photo) || current.AlbumContext != photo.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (await UploadAlbumContainsAsync(albumId, photo, token).ConfigureAwait(false))
        {
            await SetUploadEntryAsync(task, index, entry with { State = UploadCompletedState(entry), Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false); return;
        }
        RequireGeneration(generation, token); if (task.Stop) return;
        entry = entry with { State = SynologyPhotoUploadState.AddingToAlbum, Step = SynologyPhotoUploadStep.AddToAlbum,
            Accepted = false, Rejected = false, Failure = null };
        await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
        if (generation != Volatile.Read(ref _accessGeneration) || token.IsCancellationRequested || task.Stop)
        {
            await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Uploaded, Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false); return;
        }
        var fields = Parameters(("item", new[] { photo.Id.ItemId }));
        Add(fields, rights.Passphrase is { } passphrase ? Parameters(("passphrase", passphrase)) : Parameters(("id", albumId)));
        var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Browse.NormalAlbum", 1, null), 1, "add_item", fields, token).ConfigureAwait(false);
        entry = entry with { State = SynologyPhotoUploadState.PendingReview, Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted };
        if (receipt.Status == SynologyPhotoWriteStatus.Rejected)
            entry = entry with { State = SynologyPhotoUploadState.Failed, Rejected = true, Failure = receipt.Failure };
        else if (entry.Accepted && receipt.Data?["error_list"] is { } errors)
        {
            if (errors is not System.Text.Json.Nodes.JsonArray array || array.Count > 1) entry = entry with { Accepted = false };
            else entry = entry with { Rejected = array.Count > 0 };
        }
        await SetUploadEntryAsync(task, index, entry).ConfigureAwait(false);
        if (entry.State == SynologyPhotoUploadState.PendingReview) await ReviewUploadEntryAsync(task, index, token).ConfigureAwait(false);
    }
    private static SynologyPhotoUploadState UploadCompletedState(PhotoUploadEntry entry) => entry.UploadAction == "ignore"
        ? SynologyPhotoUploadState.Skipped : SynologyPhotoUploadState.Completed;
    private static SynologyPhotoFailure UploadFailure(Exception error) => error switch
    {
        SynologyPhotoException photo => photo.Failure,
        DsmException { AuthenticationFailure: true } => SynologyPhotoFailure.SessionExpired,
        DsmException { Code: 105 } => SynologyPhotoFailure.Permission,
        FileNotFoundException or DirectoryNotFoundException or UnauthorizedAccessException => SynologyPhotoFailure.TargetChanged,
        _ => SynologyPhotoFailure.WriteFailed,
    };
    private sealed class PhotoUploadProgress(Action<long> report) : IProgress<long> { public void Report(long value) => report(value); }
}
