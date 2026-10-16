using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoFolderSharingRecord(Guid Id, Guid ProfileId, string Owner, long FolderId, string IdentityHash,
        string[] PathAncestors, string Fingerprint, string CurrentRevision, string OriginalHash, string ExpectedHash, bool ParentIsShared,
        bool PreviousApply, bool Apply, SynologyPhotoFolderSharingStage Stage = SynologyPhotoFolderSharingStage.Permissions,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false,
        bool PermissionsSaved = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoFolderSharingTask(PhotoFolderSharingRecord record)
    {
        internal volatile PhotoFolderSharingRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal SynologyPhotoFolderSharingEdit? Edit;
        internal SynologyPhotoFolderSharing? Result;
        internal volatile bool Running;
    }
    private static string FolderSharingIdentity(SynologyPhotoFolderSharing value) => PhotoTextHash(JsonSerializer.Serialize(new
    { value.ProfileId, value.Folder.Id, value.Folder.ParentId, value.Folder.Path }));
    private static string[] FolderPathHashes(string path)
    {
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return Enumerable.Range(0, parts.Length + 1).Select(count => PhotoTextHash("/" + string.Join('/', parts.Take(count)))).ToArray();
    }
    private PhotoFolderSharingRecord CreateFolderSharingRecord(Guid id, SynologyPhotoFolderSharingEdit edit)
    {
        ValidateFolderSharingEdit(edit); if (id == Guid.Empty) throw Invalid();
        if (edit.Original.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var expected = FolderPermissionHash(ExpectedFolderSharing(edit));
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Original.Revision, expected, edit.AppliesToSubfolders, edit.PasswordChange }));
        return new(id, ProfileId, UploadOwner(), edit.Original.Folder.Id, FolderSharingIdentity(edit.Original), FolderPathHashes(edit.Original.Folder.Path),
            fingerprint, edit.Original.Revision, FolderPermissionHash(edit.Original), expected, edit.Original.ParentIsShared, edit.Original.AppliesToSubfolders, edit.AppliesToSubfolders);
    }
    private static PhotoFolderSharingRecord RestoreFolderSharing(Guid id, PhotoFolderSharingRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || record.FolderId <= 0 || !UploadHash(record.Owner) ||
            !UploadHash(record.IdentityHash) || !UploadHash(record.Fingerprint) || !UploadHash(record.CurrentRevision) || !UploadHash(record.OriginalHash) || !UploadHash(record.ExpectedHash) ||
            record.PathAncestors is not { Length: 2 or 3 } || record.PathAncestors.Any(value => !UploadHash(value)) ||
            !Enum.IsDefined(record.Stage) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.Stage == SynologyPhotoFolderSharingStage.DefaultOption && (!record.PermissionsSaved || record.Apply == record.PreviousApply) ||
            record.Stage == SynologyPhotoFolderSharingStage.Finished != (record.State == SynologyPhotoChangeState.Completed) ||
            record.State == SynologyPhotoChangeState.Completed && !record.PermissionsSaved ||
            record.PathAncestors.Length == 3 && (!record.ParentIsShared || record.Apply != record.PreviousApply)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private void CheckFolderSharingOwner(PhotoFolderSharingRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoFolderSharingTask OwnedFolderSharing(Guid id)
    {
        if (!_changes.FolderSharing.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckFolderSharingOwner(task.Record); return task;
    }
    private Task SaveFolderSharingAsync(PhotoFolderSharingTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, FolderSharing: task.Record));
    private static bool ActiveFolderSharing(PhotoFolderSharingRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static bool FolderSharingNeedsInput(PhotoFolderSharingTask task) => ActiveFolderSharing(task.Record) && task.Edit is null && task.Record.Stage == SynologyPhotoFolderSharingStage.Permissions;
    private static bool FolderSharingCanContinue(PhotoFolderSharingTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed && !FolderSharingNeedsInput(task);
    private static SynologyPhotoFolderSharingChange FolderSharingChangeSnapshot(PhotoFolderSharingTask task) => new(task.Record.Id, task.Record.FolderId,
        task.Record.Stage, task.Record.State, task.Record.Failure, task.Running, !task.Running && FolderSharingCanContinue(task), FolderSharingNeedsInput(task), task.Record.PermissionsSaved, task.Result);
    public async Task<IReadOnlyList<SynologyPhotoFolderSharingChange>> FolderSharingChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.FolderSharing.Values.Where(task => task.Record.Owner == owner).Select(FolderSharingChangeSnapshot).ToArray();
    }
    public async Task PrepareFolderSharingAsync(SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateFolderSharingRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareFolderSharingCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
    }
    private async Task<SynologyPhotoFolderSharing> PrepareFolderSharingCoreAsync(PhotoFolderSharingRecord record, SynologyPhotoFolderSharingEdit? edit, CancellationToken token)
    {
        CheckFolderSharingOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        await FreshManagementAccessAsync([SynologyPhotoSpace.Shared], token).ConfigureAwait(false); RequireFolderSharing();
        if (!SharingSafety.FolderPermissions) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        // 默认选项属于账号；等待核查的其他目录操作也必须排除，不能只依靠短时提交锁。
        if (_changes.FolderSharing.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveFolderSharing(task.Record)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var current = await ReadFolderSharingAsync(record.FolderId, token).ConfigureAwait(false);
        if (FolderSharingIdentity(current) != record.IdentityHash || current.Revision != record.CurrentRevision || current.InheritsManagementOnly ||
            current.ParentIsShared != record.ParentIsShared || current.AppliesToSubfolders != record.PreviousApply ||
            FolderPermissionHash(current) != (record.Stage == SynologyPhotoFolderSharingStage.Permissions ? record.OriginalHash : record.ExpectedHash))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await CheckFolderContentsBusyAsync(current.Folder, record.Owner, token, record.Id).ConfigureAwait(false);
        await CheckFileFolderConflictsAsync(record.FolderId, SynologyPhotoSpace.Shared, null, Guid.Empty, token, true).ConfigureAwait(false);
        if (edit?.Members is { } members)
        {
            if (_currentUserUid is null) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            var original = edit.Original.Members!;
            if (original.SingleOrDefault(item => item.Id == _currentUserUid)?.Role != members.SingleOrDefault(item => item.Id == _currentUserUid)?.Role)
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            var additions = members.Where(member => !original.Any(old => old.Id == member.Id)).ToArray();
            if (additions.Length > 0)
            {
                var candidates = await SharingRecipientsAsync(true, token).ConfigureAwait(false);
                if (additions.Any(member => !candidates.Any(candidate => candidate.Id == member.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            }
        }
        RequireGeneration(generation, token); CheckFolderSharingOwner(record); return current;
    }
    public async Task<SynologyPhotoFolderSharingChange> EditFolderSharingAsync(Guid operationId, SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateFolderSharingRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.FolderSharing.TryGetValue(operationId, out var old))
            {
                CheckFolderSharingOwner(old.Record);
                if (old.Record.Fingerprint != record.Fingerprint || old.Edit is { } previous && previous.Password != edit.Password)
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (!old.Running) old.Edit = edit; existing = true;
            }
            else
            {
                _ = await PrepareFolderSharingCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
                var task = new PhotoFolderSharingTask(record) { Edit = edit };
                await SaveFolderSharingAsync(task).ConfigureAwait(false); _changes.FolderSharing.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewFolderSharingAsync(operationId, cancellationToken).ConfigureAwait(false) : await ContinueFolderSharingAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoFolderSharingChange> ContinueFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderSharing(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FolderSharingChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await ReviewFolderSharingCoreAsync(task, cancellationToken).ConfigureAwait(false);
            for (var count = 0; count < 2 && FolderSharingCanContinue(task); count++)
            {
                await SendFolderSharingStageAsync(task, cancellationToken).ConfigureAwait(false);
                if (task.Record.State != SynologyPhotoChangeState.Ready) break;
            }
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return FolderSharingChangeSnapshot(task);
    }
    public async Task<SynologyPhotoFolderSharingChange> ReviewFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderSharing(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FolderSharingChangeSnapshot(task);
        try { await ReviewFolderSharingCoreAsync(task, cancellationToken).ConfigureAwait(false); return FolderSharingChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoFolderSharingChange> CancelFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderSharing(operationId); await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            { task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled }; task.Edit = null; await SaveFolderSharingAsync(task).ConfigureAwait(false); }
            return FolderSharingChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
    private void CheckFolderSharingLocks(SynologyPhotoFolder folder, Guid except = default, bool includeChildren = false)
    {
        if (folder.Space != SynologyPhotoSpace.Shared) return; var hashes = FolderPathHashes(folder.Path);
        if (_changes.FolderSharing.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveFolderSharing(task.Record) &&
            (hashes.Contains(task.Record.PathAncestors[^1]) || includeChildren && task.Record.PathAncestors.Contains(hashes[^1]))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
}
