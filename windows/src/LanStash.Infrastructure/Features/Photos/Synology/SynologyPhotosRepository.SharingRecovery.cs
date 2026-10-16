using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoSharingRecord(Guid Id, Guid ProfileId, string Owner, long AlbumId, string IdentityHash,
        string Fingerprint, string OriginalRevision, string CurrentRevision, string OriginalConfig, string ExpectedConfig,
        SynologyPhotoLinkAccess Access, SynologyPhotoLinkAccess OriginalAccess, bool Configure, bool Expands,
        SynologyPhotoSharingStage Stage = SynologyPhotoSharingStage.Close,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoSharingTask(PhotoSharingRecord record)
    {
        internal volatile PhotoSharingRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal SynologyPhotoSharingEdit? Edit;
        internal SynologyPhotoSharing? Result;
        internal string? Passphrase;
        internal volatile bool Running;
    }
    private static string ShareAlbumIdentity(SynologyPhotoSharing value) => PhotoTextHash(JsonSerializer.Serialize(new
    { value.Album.Id, value.Album.OwnerUserId, value.Album.CurrentUserId, value.Album.Name, value.Album.Conditional, value.Album.Frozen, value.Temporary }));
    private static string SharingFingerprint(SynologyPhotoSharingEdit edit) => PhotoTextHash(JsonSerializer.Serialize(new
    { edit.Original.Album.Id, edit.Original.Revision, OriginalAccess = edit.Original.Access, OriginalConfig = ShareConfigHash(edit.Original), edit.Access, Members = ShareMembersHash(edit.Members), edit.Expiration, edit.PasswordChange }));
    private PhotoSharingRecord CreateSharingRecord(Guid id, SynologyPhotoSharingEdit edit)
    {
        ValidateSharingEdit(edit); if (id == Guid.Empty) throw Invalid();
        if (edit.Original.Album.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(id, ProfileId, UploadOwner(), edit.Original.Album.Id, ShareAlbumIdentity(edit.Original), SharingFingerprint(edit),
            edit.Original.Revision, edit.Original.Revision, ShareConfigHash(edit.Original), ShareConfigHash(ExpectedSharing(edit)),
            edit.Access, edit.Original.Access, SharingConfigChanged(edit) || SharingMemberDelta(edit).Count > 0, edit.ExpandsAccess);
    }
    private static PhotoSharingRecord RestoreSharing(Guid id, PhotoSharingRecord record)
    {
        if (record.Id != id || id == Guid.Empty || record.ProfileId == Guid.Empty || record.AlbumId <= 0 ||
            !UploadHash(record.Owner) || !UploadHash(record.IdentityHash) || !UploadHash(record.Fingerprint) || !UploadHash(record.OriginalRevision) ||
            !UploadHash(record.CurrentRevision) || !UploadHash(record.OriginalConfig) || !UploadHash(record.ExpectedConfig) ||
            !Enum.IsDefined(record.Access) || !Enum.IsDefined(record.OriginalAccess) || !Enum.IsDefined(record.Stage) || !Enum.IsDefined(record.State) ||
            record.Failure is { } failure && !Enum.IsDefined(failure) || record.Stage == SynologyPhotoSharingStage.Configure && !record.Configure ||
            record.Stage == SynologyPhotoSharingStage.Open && record.Access == SynologyPhotoLinkAccess.Disabled ||
            record.State == SynologyPhotoChangeState.Completed != (record.Stage == SynologyPhotoSharingStage.Finished)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private void CheckSharingOwner(PhotoSharingRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoSharingTask OwnedSharing(Guid id)
    {
        if (!_changes.Sharing.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckSharingOwner(task.Record); return task;
    }
    private Task SaveSharingAsync(PhotoSharingTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Sharing: task.Record));
    private static bool ActiveSharing(PhotoSharingRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static bool SharingNeedsInput(PhotoSharingTask task) => ActiveSharing(task.Record) && task.Edit is null && task.Record.Configure && task.Record.Stage is SynologyPhotoSharingStage.Close or SynologyPhotoSharingStage.Configure;
    private static bool SharingCanContinue(PhotoSharingTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed && !SharingNeedsInput(task);
    private static SynologyPhotoSharingChange SharingChangeSnapshot(PhotoSharingTask task) => new(task.Record.Id, task.Record.AlbumId,
        task.Record.Access, task.Record.Stage, task.Record.State, task.Record.Failure, task.Running, !task.Running && SharingCanContinue(task), SharingNeedsInput(task), task.Result);
    public async Task<IReadOnlyList<SynologyPhotoSharingChange>> SharingChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Sharing.Values.Where(task => task.Record.Owner == owner).Select(SharingChangeSnapshot).ToArray();
    }
    public async Task PrepareSharingAsync(SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateSharingRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareSharingCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
    }
    private async Task<SynologyPhotoSharing> PrepareSharingCoreAsync(PhotoSharingRecord record, SynologyPhotoSharingEdit? edit, CancellationToken token)
    {
        CheckSharingOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        await FreshManagementAccessAsync([SynologyPhotoSpace.Personal], token).ConfigureAwait(false);
        if (record.Expands && !SharingSafety.Publish) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        _ = Capability("Sharing.Passphrase", 1, null);
        await CheckAlbumBusyAsync(record.AlbumId, token, record.Id).ConfigureAwait(false);
        await CheckAlbumContentBusyAsync(record.AlbumId, record.Owner, token).ConfigureAwait(false);
        var current = await AlbumSharingAsync(record.AlbumId, token).ConfigureAwait(false);
        if (ShareAlbumIdentity(current) != record.IdentityHash || current.Revision != record.CurrentRevision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (record.Stage == SynologyPhotoSharingStage.Close && (current.Access != record.OriginalAccess || ShareConfigHash(current) != record.OriginalConfig))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (edit?.Members is { } members)
        {
            if (_currentUserUid is null) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            var original = edit.Original.Members!;
            if (original.SingleOrDefault(item => item.Id == _currentUserUid)?.Role != members.SingleOrDefault(item => item.Id == _currentUserUid)?.Role)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            var candidates = await SharingRecipientsAsync(cancellationToken: token).ConfigureAwait(false);
            if (members.Where(member => !original.Any(old => old.Id == member.Id)).Any(member => !candidates.Any(candidate => candidate.Id == member.Id)))
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        RequireGeneration(generation, token); CheckSharingOwner(record); return current;
    }
    public async Task<SynologyPhotoSharingChange> EditSharingAsync(Guid operationId, SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateSharingRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) || _changes.Albums.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Sharing.TryGetValue(operationId, out var old))
            {
                CheckSharingOwner(old.Record);
                if (old.Record.Fingerprint != record.Fingerprint || old.Edit is { } previous && previous.Password != edit.Password)
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (!old.Running) old.Edit = edit; existing = true;
            }
            else
            {
                _ = await PrepareSharingCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
                var task = new PhotoSharingTask(record) { Edit = edit };
                await SaveSharingAsync(task).ConfigureAwait(false); _changes.Sharing.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewSharingChangeAsync(operationId, cancellationToken).ConfigureAwait(false) : await ContinueSharingChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoSharingChange> ContinueSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedSharing(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return SharingChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await ReviewSharingCoreAsync(task, cancellationToken).ConfigureAwait(false);
            // 每次继续至多经历三个明确阶段；只读刷新永不进入写入。
            for (var count = 0; count < 3 && SharingCanContinue(task); count++)
            {
                await SendSharingStageAsync(task, cancellationToken).ConfigureAwait(false);
                if (task.Record.State != SynologyPhotoChangeState.Ready) break;
            }
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SharingChangeSnapshot(task);
    }
    public async Task<SynologyPhotoSharingChange> ReviewSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedSharing(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return SharingChangeSnapshot(task);
        try { await ReviewSharingCoreAsync(task, cancellationToken).ConfigureAwait(false); return SharingChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoSharingChange> CancelSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedSharing(operationId); await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            {
                task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled }; task.Edit = null; task.Passphrase = null;
                await SaveSharingAsync(task).ConfigureAwait(false);
            }
            return SharingChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
