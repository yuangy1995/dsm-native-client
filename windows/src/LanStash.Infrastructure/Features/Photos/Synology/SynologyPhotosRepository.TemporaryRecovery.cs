using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoTemporaryRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint, bool FromCreation,
        bool KeepCopy, string NameHash, string MembersHash, SynologyPhotoIdentity[] Sources, long? AlbumId = null,
        string? IdentityHash = null, string? Revision = null, long? CopyId = null, bool CopyVerified = false,
        SynologyPhotoTemporaryStage Stage = SynologyPhotoTemporaryStage.Create, SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready,
        bool Accepted = false, bool CancelRequested = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoTemporaryTask(PhotoTemporaryRecord record)
    {
        internal volatile PhotoTemporaryRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1), RecordGate = new(1, 1);
        internal string? Name;
        internal IReadOnlyList<SynologyPhoto>? Photos;
        internal SynologyPhotoSharing? Result;
        internal volatile bool Running;
    }
    private static PhotoTemporaryRecord RestoreTemporary(Guid id, PhotoTemporaryRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) ||
            !UploadHash(record.Fingerprint) || !UploadHash(record.NameHash) || !UploadHash(record.MembersHash) ||
            !Enum.IsDefined(record.Stage) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.AlbumId <= 0 || record.CopyId <= 0 || record.CopyId is not null && record.CopyId == record.AlbumId ||
            record.Sources is null || record.Sources.Any(item => item.ProfileId != record.ProfileId || item.ItemId <= 0 || !Enum.IsDefined(item.Space)) ||
            record.IdentityHash is not null && !UploadHash(record.IdentityHash) || record.Revision is not null && !UploadHash(record.Revision) ||
            record.Stage is not (SynologyPhotoTemporaryStage.Create or SynologyPhotoTemporaryStage.Finished) && (record.AlbumId is null || record.IdentityHash is null || record.Revision is null) ||
            record.CopyVerified && (!record.KeepCopy || record.CopyId is null) || record.KeepCopy && record.FromCreation) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private void CheckTemporaryOwner(PhotoTemporaryRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoTemporaryTask OwnedTemporary(Guid id)
    {
        if (!_changes.Temporary.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckTemporaryOwner(task.Record); return task;
    }
    // 取消意图可在网络请求进行中落盘；所有记录变更串行合并，避免迟到回执覆盖取消。
    private async Task UpdateTemporaryAsync(PhotoTemporaryTask task, Func<PhotoTemporaryRecord, PhotoTemporaryRecord> update)
    {
        await task.RecordGate.WaitAsync().ConfigureAwait(false);
        try { task.Record = update(task.Record); await SaveManagementRecordAsync(task.Record.Id, new(1, Temporary: task.Record)).ConfigureAwait(false); }
        finally { task.RecordGate.Release(); }
    }
    private static bool ActiveTemporary(PhotoTemporaryRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static bool TemporaryCanContinue(PhotoTemporaryTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed &&
        task.Record.Stage is not (SynologyPhotoTemporaryStage.Configure or SynologyPhotoTemporaryStage.Finished) &&
        (task.Record.Stage != SynologyPhotoTemporaryStage.Create || task.Name is not null && task.Photos is not null);
    private static SynologyPhotoTemporaryChange TemporarySnapshot(PhotoTemporaryTask task) => new(task.Record.Id, task.Record.AlbumId,
        task.Record.CopyId, task.Record.Stage, task.Record.State, task.Record.Failure, task.Record.FromCreation, task.Record.KeepCopy,
        task.Record.CancelRequested, task.Running, !task.Running && (TemporaryCanContinue(task) || task.Record.CancelRequested &&
            task.Record.Stage == SynologyPhotoTemporaryStage.Configure && task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed), task.Result);
    public async Task<IReadOnlyList<SynologyPhotoTemporaryChange>> TemporarySharingChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Temporary.Values.Where(task => task.Record.Owner == owner).Select(TemporarySnapshot).ToArray();
    }
    private async Task<SynologyPhotoTemporaryChange> RegisterTemporaryAsync(PhotoTemporaryTask task, CancellationToken token)
    {
        await LoadChangesAsync().ConfigureAwait(false); var existing = false; var record = task.Record;
        await _changes.Gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(record.Id) || _changes.Folders.ContainsKey(record.Id) || _changes.Files.ContainsKey(record.Id) ||
                _changes.Albums.ContainsKey(record.Id) || _changes.Sharing.ContainsKey(record.Id) || _changes.Requests.ContainsKey(record.Id) || _changes.FolderSharing.ContainsKey(record.Id) || _changes.Recognition.ContainsKey(record.Id) || _changes.Previews.ContainsKey(record.Id) || _changes.Automatic.ContainsKey(record.Id) || _changes.Settings.ContainsKey(record.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Temporary.TryGetValue(record.Id, out var old))
            { CheckTemporaryOwner(old.Record); if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged); existing = true; }
            else
            {
                await PrepareTemporaryAsync(task, token).ConfigureAwait(false);
                await UpdateTemporaryAsync(task, value => value).ConfigureAwait(false); _changes.Temporary.TryAdd(record.Id, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewTemporarySharingAsync(record.Id, token).ConfigureAwait(false) : await ContinueTemporarySharingAsync(record.Id, token).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoTemporaryChange> ContinueTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedTemporary(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return TemporarySnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var uploads = _uploads.OwnerGates.GetOrAdd(task.Record.Owner, _ => new(1, 1));
        var owns = false; var ownsUploads = false; task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await uploads.WaitAsync(cancellationToken).ConfigureAwait(false); ownsUploads = true;
            await ReviewTemporaryCoreAsync(task, cancellationToken).ConfigureAwait(false);
            await AdvanceTemporaryCancellationAsync(task, cancellationToken).ConfigureAwait(false);
            for (var index = 0; index < 4 && TemporaryCanContinue(task); index++)
            {
                await SendTemporaryStageAsync(task, cancellationToken).ConfigureAwait(false);
                await AdvanceTemporaryCancellationAsync(task, cancellationToken).ConfigureAwait(false);
                if (task.Record.State != SynologyPhotoChangeState.Ready) break;
            }
        }
        finally { task.Running = false; if (ownsUploads) uploads.Release(); if (owns) owner.Release(); task.Gate.Release(); }
        return TemporarySnapshot(task);
    }
    public async Task<SynologyPhotoTemporaryChange> ReviewTemporarySharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedTemporary(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return TemporarySnapshot(task);
        try { await ReviewTemporaryCoreAsync(task, cancellationToken).ConfigureAwait(false); await AdvanceTemporaryCancellationAsync(task, cancellationToken).ConfigureAwait(false); return TemporarySnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoTemporaryChange> CancelTemporaryCreationAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedTemporary(operationId);
        if (!task.Record.FromCreation) throw Invalid();
        if (!ActiveTemporary(task.Record)) return TemporarySnapshot(task);
        await UpdateTemporaryAsync(task, value => value with { CancelRequested = true }).ConfigureAwait(false);
        // 在途写保留原任务；其返回后会观察已持久化的取消意图。
        return await ContinueTemporarySharingAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoTemporaryChange> KeepTemporaryAlbumsAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedTemporary(operationId);
        await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            {
                var completed = task.Record.Stage == SynologyPhotoTemporaryStage.Configure && !task.Record.CancelRequested;
                await UpdateTemporaryAsync(task, value => value with { State = completed ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Cancelled,
                    Stage = SynologyPhotoTemporaryStage.Finished }).ConfigureAwait(false); task.Name = null; task.Photos = null;
            }
            return TemporarySnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
