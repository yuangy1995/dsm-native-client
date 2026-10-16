using System.Collections.Concurrent;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoPreviewRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint, bool Resuming, PhotoPreviewEntry[] Items);
    private sealed record PhotoPreviewEntry(SynologyPhoto Original, SynologyPhotoThumbnail? Baseline = null,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Marking = false, bool Marked = false, bool MarkRejected = false,
        bool LocalSubmitted = false, bool LocalRejected = false, bool NasSubmitted = false, bool NasRejected = false,
        bool Restoring = false, bool Restored = false, bool Generated = false, bool Recovered = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoPreviewTask(PhotoPreviewRecord record)
    {
        internal volatile PhotoPreviewRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal readonly ConcurrentDictionary<SynologyPhotoIdentity, SynologyPhoto> Updated = new();
        internal volatile bool Running, Stop;
        internal CancellationTokenSource? Work;
    }
    private static bool ActivePreview(PhotoPreviewEntry item) => item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Failed or SynologyPhotoChangeState.Cancelled);
    private static bool PendingPreview(PhotoPreviewRecord record) => record.Items.Any(item => item.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview);
    private bool PreviewPhotoBusy(SynologyPhotoIdentity id, Guid except = default) => AutomaticPhotoBusy(id, except) || _changes.Previews.Values.Any(task =>
        task.Record.Id != except && task.Record.Owner == UploadOwner() && task.Record.Items.Any(item => item.Original.Id == id && ActivePreview(item)));
    private IEnumerable<long> PreviewFolders(SynologyPhotoSpace space, Guid except = default) => _changes.Previews.Values
        .Where(task => task.Record.Id != except && task.Record.Owner == UploadOwner()).SelectMany(task => task.Record.Items)
        .Where(item => item.Original.Id.Space == space && ActivePreview(item)).Select(item => item.Original.FolderId)
        .Concat(_changes.Automatic.Values.Where(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveAutomatic(task.Record) &&
            task.Record.Candidate.Space == space && task.Record.Candidate.SourcePhoto is not null).Select(task => task.Record.Candidate.SourcePhoto!.FolderId)).Distinct();
    private static PhotoPreviewRecord RestorePreview(Guid id, PhotoPreviewRecord record)
    {
        if (id == Guid.Empty || record.Id != id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            record.Items is not { Length: > 0 and <= 100 } || record.Items.DistinctBy(item => item.Original.Id).Count() != record.Items.Length) throw Invalid();
        foreach (var entry in record.Items)
        {
            var photo = entry.Original;
            if (photo.Id.ProfileId != record.ProfileId || !Enum.IsDefined(photo.Id.Space) || photo.Id.ItemId <= 0 || photo.FolderId <= 0 || photo.SizeBytes < 0 ||
                string.IsNullOrWhiteSpace(photo.Filename) || !photo.SupportsPreviewGeneration || !Enum.IsDefined(entry.State) || entry.Failure is { } failure && !Enum.IsDefined(failure) ||
                photo.AlbumContext is { AlbumId: <= 0 } or { OwnerUserId: < 0 } or { ProviderUserId: <= 0 } ||
                entry.Baseline is { UnitId: <= 0 } || entry.Baseline is { } baseline && (!Enum.IsDefined(baseline.Space) || baseline.Type != SynologyPhotoThumbnailType.Unit) ||
                entry.Marked && !entry.Marking && !record.Resuming || entry.MarkRejected && (!entry.Marking || entry.Marked) ||
                (entry.LocalSubmitted || entry.NasSubmitted) && !entry.Marked || entry.LocalRejected && !entry.LocalSubmitted || entry.NasRejected && !entry.NasSubmitted ||
                entry.Restoring && (!entry.LocalRejected && !entry.NasRejected || entry.Generated) || entry.Restored && !entry.Restoring ||
                entry.Generated && !entry.LocalSubmitted && !entry.NasSubmitted || entry.Recovered && !entry.Generated ||
                entry.State == SynologyPhotoChangeState.Completed && !entry.Generated) throw Invalid();
        }
        return record with { Items = record.Items.Select(entry => entry.State == SynologyPhotoChangeState.Submitting
            ? entry with { State = SynologyPhotoChangeState.PendingReview } : entry).ToArray() };
    }
    private void CheckPreviewOwner(PhotoPreviewRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoPreviewTask OwnedPreview(Guid id)
    {
        if (!_changes.Previews.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckPreviewOwner(task.Record); return task;
    }
    private Task SavePreviewAsync(PhotoPreviewTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Preview: task.Record));
    private async Task SetPreviewEntryAsync(PhotoPreviewTask task, int index, PhotoPreviewEntry entry)
    {
        var items = task.Record.Items.ToArray(); items[index] = entry; task.Record = task.Record with { Items = items };
        await SavePreviewAsync(task).ConfigureAwait(false);
    }
    private static SynologyPhotoPreviewGeneration PreviewSnapshot(PhotoPreviewTask task) => new(task.Record.Id, task.Record.Resuming,
        task.Record.Items.Select(entry => new SynologyPhotoPreviewGenerationItem(entry.Original, entry.State,
            task.Updated.GetValueOrDefault(entry.Original.Id), entry.Failure)).ToArray(), task.Running,
        !task.Running && !PendingPreview(task.Record) && task.Record.Items.Any(entry => entry.State == SynologyPhotoChangeState.Ready));
    public async Task PreparePreviewGenerationAsync(SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default)
    {
        var record = PreviewRecord(Guid.NewGuid(), request); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PreparePreviewRecordAsync(record, cancellationToken).ConfigureAwait(false);
    }
    public async Task<IReadOnlyList<SynologyPhotoPreviewGeneration>> PreviewGenerationsAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Previews.Values.Where(task => task.Record.Owner == owner).Select(PreviewSnapshot).ToArray();
    }
    public async Task<SynologyPhotoPreviewGeneration> GeneratePreviewsAsync(Guid operationId, SynologyPhotoPreviewGenerationRequest request, CancellationToken cancellationToken = default)
    {
        var record = PreviewRecord(operationId, request); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) ||
                _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Previews.TryGetValue(operationId, out var previous))
            {
                CheckPreviewOwner(previous.Record);
                if (previous.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing = true;
            }
            else
            {
                var task = new PhotoPreviewTask(await PreparePreviewRecordAsync(record, cancellationToken).ConfigureAwait(false));
                await SavePreviewAsync(task).ConfigureAwait(false); _changes.Previews.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewPreviewGenerationAsync(operationId, cancellationToken).ConfigureAwait(false)
            : await ContinuePreviewGenerationAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoPreviewGeneration> ContinuePreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedPreview(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return PreviewSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; task.Running = true;
        using var work = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        lock (task) { task.Stop = false; task.Work = work; }
        var token = work.Token;
        try
        {
            await owner.WaitAsync(token).ConfigureAwait(false); owns = true;
            await ReviewPreviewCoreAsync(task, token).ConfigureAwait(false);
            if (!PendingPreview(task.Record))
                for (var index = 0; index < task.Record.Items.Length && !task.Stop; index++)
                {
                    if (task.Record.Items[index].State != SynologyPhotoChangeState.Ready) continue;
                    await GeneratePreviewEntryAsync(task, index, token).ConfigureAwait(false);
                    if (PendingPreview(task.Record) || token.IsCancellationRequested) break;
                }
        }
        finally { lock (task) { task.Work = null; } task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return PreviewSnapshot(task);
    }
    public async Task<SynologyPhotoPreviewGeneration> ReviewPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedPreview(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return PreviewSnapshot(task);
        try { await ReviewPreviewCoreAsync(task, cancellationToken).ConfigureAwait(false); return PreviewSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoPreviewGeneration> CancelPreviewGenerationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedPreview(operationId);
        lock (task) { task.Stop = true; task.Work?.Cancel(); }
        await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            task.Record = task.Record with { Items = task.Record.Items.Select(entry => entry.State == SynologyPhotoChangeState.Ready
                ? entry with { State = SynologyPhotoChangeState.Cancelled } : entry).ToArray() };
            await SavePreviewAsync(task).ConfigureAwait(false); return PreviewSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
