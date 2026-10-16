using System.Runtime.InteropServices;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static bool PreviewError(Exception error) => ManagementError(error) || error is PhotoPreviewEventException or COMException;
    private static SynologyPhotoFailure PreviewFailure(Exception error) => error is PhotoPreviewEventException or COMException
        ? SynologyPhotoFailure.Media : UploadFailure(error);
    private async Task<SynologyPhoto> ValidatePreviewStepAsync(PhotoPreviewTask task, int index, CancellationToken token)
    {
        CheckPreviewOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
        var spaces = task.Record.Items.Select(entry => entry.Original.Id.Space).Distinct().ToArray();
        await FreshManagementAccessAsync(spaces, token).ConfigureAwait(false);
        if (spaces.Length > 1 && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var entry = task.Record.Items[index]; await CheckPreviewLocksAsync(task.Record.Id, entry.Original, token).ConfigureAwait(false);
        var current = await PreviewOriginalAsync(entry.Original, token).ConfigureAwait(false);
        if (entry.Marked || task.Record.Resuming)
            RequireQueuedPreview(entry.Original, await PreviewQueueAsync(entry.Original.Id.Space, token).ConfigureAwait(false));
        RequireGeneration(generation, token); if (task.Stop) throw new OperationCanceledException(token); return current;
    }
    private async Task<SynologyPhotoWriteStatus> PreviewWriteAsync(PhotoPreviewTask task, int index,
        Func<PhotoPreviewEntry, PhotoPreviewEntry> submitting,
        Func<CancellationToken, Task<SynologyPhotoWriteReceipt>> send,
        Func<PhotoPreviewEntry, SynologyPhotoWriteReceipt, PhotoPreviewEntry> result, CancellationToken token)
    {
        var before = task.Record.Items[index]; var sent = false; var generation = Volatile.Read(ref _accessGeneration);
        try
        {
            _ = await ValidatePreviewStepAsync(task, index, token).ConfigureAwait(false);
            await SetPreviewEntryAsync(task, index, submitting(before) with { State = SynologyPhotoChangeState.Submitting, Failure = null }).ConfigureAwait(false);
            _ = await ValidatePreviewStepAsync(task, index, token).ConfigureAwait(false); RequireGeneration(generation, token);
            sent = true; var receipt = await send(token).ConfigureAwait(false);
            await SetPreviewEntryAsync(task, index, result(task.Record.Items[index], receipt) with { Failure = receipt.Failure }).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckPreviewOwner(task.Record); return receipt.Status;
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore();
            if (!sent) await SetPreviewEntryAsync(task, index, before with { State = SynologyPhotoChangeState.Failed, Failure = PreviewFailure(error) }).ConfigureAwait(false);
            throw;
        }
    }
    private async Task<bool> MarkPreviewAsync(PhotoPreviewTask task, int index, CancellationToken token)
    {
        if (task.Record.Items[index].Marked) return true;
        if (task.Record.Resuming)
        {
            _ = await ValidatePreviewStepAsync(task, index, token).ConfigureAwait(false);
            await SetPreviewEntryAsync(task, index, task.Record.Items[index] with { Marked = true }).ConfigureAwait(false); return true;
        }
        var photo = task.Record.Items[index].Original;
        return await PreviewWriteAsync(task, index, entry => entry with { Marking = true },
            ct => _api.WritePhotoAsync(_profile, _session, Capability("RegeneratePreview", 1, photo.Id.Space), 1, "set_regenerating",
                Parameters(("item_id", new[] { photo.Id.ItemId })), ct),
            (entry, receipt) =>
            {
                if (receipt.Status == SynologyPhotoWriteStatus.Accepted)
                {
                    var queue = PreviewQueue(receipt.Data ?? throw Invalid());
                    if (queue.Length != 1) throw Invalid(); RequireQueuedPreview(photo, queue);
                    return entry with { Marked = true, State = SynologyPhotoChangeState.Ready };
                }
                return entry with { MarkRejected = receipt.Status == SynologyPhotoWriteStatus.Rejected,
                    State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview };
            }, token).ConfigureAwait(false) == SynologyPhotoWriteStatus.Accepted;
    }
    private async Task<SynologyPhotoConvertedPreview?> PrepareLocalPreviewAsync(PhotoPreviewTask task, int index, CancellationToken token)
    {
        var photo = task.Record.Items[index].Original;
        if (photo.MediaType is not ("photo" or "video")) return null;
        try { _ = Capability("Upload.ConvertedFile", 3, photo.Id.Space); }
        catch (SynologyPhotoException error) when (error.Failure == SynologyPhotoFailure.Unavailable) { return null; }
        var generation = Volatile.Read(ref _accessGeneration);
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Photos", "Preview", Guid.NewGuid().ToString("N"));
        var extension = Path.GetExtension(photo.Filename);
        if (extension.Length > 12 || extension.Skip(1).Any(character => !char.IsAsciiLetterOrDigit(character))) extension = "";
        var source = Path.Combine(directory, "source" + extension);
        SynologyPhotoConvertedPreview? converted;
        try
        {
            Directory.CreateDirectory(directory);
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("photos.preview.directory-link");
            await DownloadOriginalAsync(photo, source, cancellationToken: token).ConfigureAwait(false);
            converted = await _previewConverter.ConvertAsync(source, photo.MediaType, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            token.ThrowIfCancellationRequested(); RequireGeneration(generation, token); return null;
        }
        finally
        {
            if (File.Exists(source)) File.Delete(source);
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
        _ = await ValidatePreviewStepAsync(task, index, token).ConfigureAwait(false); RequireGeneration(generation, token); return converted;
    }
    private async Task<SynologyPhotoWriteStatus> UploadPreviewAsync(PhotoPreviewTask task, int index, SynologyPhotoConvertedPreview preview, CancellationToken token)
    {
        if (!await MarkPreviewAsync(task, index, token).ConfigureAwait(false)) return SynologyPhotoWriteStatus.Unknown;
        var photo = task.Record.Items[index].Original;
        return await PreviewWriteAsync(task, index, entry => entry with { LocalSubmitted = true },
            ct => _api.UploadPhotoPreviewAsync(_profile, _session, Capability("Upload.ConvertedFile", 3, photo.Id.Space), photo.Id.ItemId, preview, ct),
            (entry, receipt) => entry with { Generated = receipt.Status == SynologyPhotoWriteStatus.Accepted,
                LocalRejected = receipt.Status == SynologyPhotoWriteStatus.Rejected, State = SynologyPhotoChangeState.PendingReview }, token).ConfigureAwait(false);
    }
    private async Task RestorePreviewAsync(PhotoPreviewTask task, int index, CancellationToken token)
    {
        var entry = task.Record.Items[index]; var photo = entry.Original;
        if (entry.Restoring || entry.Generated || !entry.LocalRejected && !entry.NasRejected) return;
        // 恢复标记也是写操作，只在明确转换失败后发送一次；丢失回执随后仅查队列。
        _ = await PreviewWriteAsync(task, index, item => item with { Restoring = true },
            ct => _api.WritePhotoAsync(_profile, _session, Capability("RegeneratePreview", 1, photo.Id.Space), 1, "restore_from_regenerating",
                Parameters(("unit_id", new[] { photo.Id.ItemId })), ct),
            (item, receipt) => item with { Restored = receipt.Status == SynologyPhotoWriteStatus.Accepted,
                State = SynologyPhotoChangeState.PendingReview }, token).ConfigureAwait(false);
        await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false);
    }
    private async Task GeneratePreviewEntryAsync(PhotoPreviewTask task, int index, CancellationToken token)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        var photo = task.Record.Items[index].Original; var localFirst = Path.GetExtension(photo.Filename).Equals(".png", StringComparison.OrdinalIgnoreCase);
        try
        {
            var current = await ValidatePreviewStepAsync(task, index, token).ConfigureAwait(false);
            var initial = task.Record.Items[index];
            if (!initial.Marking && !initial.Marked) await SetPreviewEntryAsync(task, index, initial with { Baseline = current.Thumbnail }).ConfigureAwait(false);
            if (localFirst && await PrepareLocalPreviewAsync(task, index, token).ConfigureAwait(false) is { } local)
            {
                var receipt = await UploadPreviewAsync(task, index, local, token).ConfigureAwait(false);
                if (receipt != SynologyPhotoWriteStatus.Rejected) { await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false); return; }
            }
            ISynologyPhotoPreviewCompletion events;
            try { events = await _api.SubscribePhotoPreviewAsync(_profile, _session, photo.Id.ItemId, token).ConfigureAwait(false); }
            catch (Exception error) when (PreviewError(error))
            {
                token.ThrowIfCancellationRequested();
                if (!localFirst && await PrepareLocalPreviewAsync(task, index, token).ConfigureAwait(false) is { } fallback)
                {
                    var receipt = await UploadPreviewAsync(task, index, fallback, token).ConfigureAwait(false);
                    if (receipt != SynologyPhotoWriteStatus.Rejected) { await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false); return; }
                }
                if (task.Record.Items[index].Marked && task.Record.Items[index].LocalRejected && !task.Record.Resuming)
                    await RestorePreviewAsync(task, index, token).ConfigureAwait(false);
                else await SetPreviewEntryAsync(task, index, task.Record.Items[index] with { State = SynologyPhotoChangeState.Failed, Failure = PreviewFailure(error) }).ConfigureAwait(false);
                return;
            }
            await using (events.ConfigureAwait(false))
            {
                RequireGeneration(generation, token);
                if (!await MarkPreviewAsync(task, index, token).ConfigureAwait(false)) return;
                var receipt = await PreviewWriteAsync(task, index, entry => entry with { NasSubmitted = true },
                    ct => _api.WritePhotoAsync(_profile, _session, Capability("RegeneratePreview", 1, photo.Id.Space), 1, "regenerate_preview_by_nas",
                        Parameters(("unit_id", photo.Id.ItemId)), ct),
                    (entry, accepted) => entry with { NasRejected = accepted.Status == SynologyPhotoWriteStatus.Rejected,
                        State = SynologyPhotoChangeState.PendingReview }, token).ConfigureAwait(false);
                if (receipt == SynologyPhotoWriteStatus.Unknown) { await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false); return; }
                if (receipt == SynologyPhotoWriteStatus.Accepted)
                {
                    var generated = await events.CompletionAsync(token).ConfigureAwait(false);
                    await SetPreviewEntryAsync(task, index, task.Record.Items[index] with { Generated = generated, NasRejected = !generated }).ConfigureAwait(false);
                    RequireGeneration(generation, token);
                    if (generated) { await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false); return; }
                }
            }
            if (!localFirst && await PrepareLocalPreviewAsync(task, index, token).ConfigureAwait(false) is { } converted)
            {
                var receipt = await UploadPreviewAsync(task, index, converted, token).ConfigureAwait(false);
                if (receipt != SynologyPhotoWriteStatus.Rejected) { await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false); return; }
            }
            await RestorePreviewAsync(task, index, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore(); var entry = task.Record.Items[index];
            var pending = entry.Generated || entry.Restoring || entry.Marking && !entry.Marked && !entry.MarkRejected ||
                entry.LocalSubmitted && !entry.LocalRejected || entry.NasSubmitted && !entry.NasRejected;
            await SetPreviewEntryAsync(task, index, entry with { State = pending ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed,
                Failure = PreviewFailure(error) }).ConfigureAwait(false);
        }
    }
    private static bool ChangedPreview(SynologyPhotoThumbnail? before, SynologyPhotoThumbnail? after) =>
        before is not null && after is not null && before.UnitId == after.UnitId && !string.IsNullOrEmpty(before.Revision) &&
        !string.IsNullOrEmpty(after.Revision) && before.Revision != after.Revision;
    private async Task ReviewPreviewCoreAsync(PhotoPreviewTask task, CancellationToken token)
    {
        CheckPreviewOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
        for (var index = 0; index < task.Record.Items.Length; index++)
        {
            var entry = task.Record.Items[index];
            if (entry.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) continue;
            try
            {
                var photo = entry.Original; await FreshManagementAccessAsync([photo.Id.Space], token).ConfigureAwait(false);
                var current = await PreviewOriginalAsync(photo, token).ConfigureAwait(false);
                if (entry.Generated)
                {
                    if (entry.Recovered && !ChangedPreview(entry.Baseline, current.Thumbnail)) continue;
                }
                else
                {
                    var queue = await PreviewQueueAsync(photo.Id.Space, token).ConfigureAwait(false);
                    if (entry.Marking && !entry.Marked && !entry.MarkRejected && !entry.LocalSubmitted && !entry.NasSubmitted)
                    {
                        RequireQueuedPreview(photo, queue); RequireGeneration(generation, token);
                        await SetPreviewEntryAsync(task, index, entry with { Marked = true, State = SynologyPhotoChangeState.Ready, Failure = null }).ConfigureAwait(false); continue;
                    }
                    if (!entry.Restoring && (!entry.LocalSubmitted || entry.LocalRejected) && (!entry.NasSubmitted || entry.NasRejected))
                    {
                        RequireGeneration(generation, token);
                        await SetPreviewEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Failed }).ConfigureAwait(false); continue;
                    }
                    if (queue.Any(item => item.UnitId == photo.Id.ItemId)) continue;
                    if (entry.Restoring)
                    {
                        RequireGeneration(generation, token);
                        await SetPreviewEntryAsync(task, index, entry with { Restored = true, State = SynologyPhotoChangeState.Failed }).ConfigureAwait(false); continue;
                    }
                    if ((!entry.LocalSubmitted && !entry.NasSubmitted) || !ChangedPreview(entry.Baseline, current.Thumbnail)) continue;
                    if ((await PreviewQueueAsync(photo.Id.Space, token).ConfigureAwait(false)).Any(item => item.UnitId == photo.Id.ItemId)) continue;
                    var final = await PreviewOriginalAsync(photo, token).ConfigureAwait(false);
                    if (!ChangedPreview(entry.Baseline, final.Thumbnail) || final.Thumbnail?.UnitId != current.Thumbnail?.UnitId || final.Thumbnail?.Revision != current.Thumbnail?.Revision) continue;
                    current = final; entry = entry with { Generated = true, Recovered = true };
                }
                RequireGeneration(generation, token); CheckPreviewOwner(task.Record);
                task.Updated[photo.Id] = current;
                await SetPreviewEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Completed, Failure = null }).ConfigureAwait(false);
            }
            catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
        }
    }
}
