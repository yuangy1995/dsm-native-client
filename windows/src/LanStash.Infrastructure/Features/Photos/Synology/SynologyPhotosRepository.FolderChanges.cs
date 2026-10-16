using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoFolderChangeRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint,
        SynologyPhotoFolderEdit Edit, SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready,
        bool Accepted = false, long? CreatedId = null, SynologyPhotoFolder? Result = null, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoFolderChangeTask(PhotoFolderChangeRecord record)
    {
        internal volatile PhotoFolderChangeRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal volatile bool Running;
    }
    private static PhotoFolderChangeRecord RestoreFolderChange(Guid id, PhotoFolderChangeRecord record)
    {
        if (id == Guid.Empty || record.Id != id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.State) || record.CreatedId <= 0 || record.Failure is { } failure && !Enum.IsDefined(failure)) throw Invalid();
        ValidateFolderEdit(record.Edit);
        if (record.Edit.Photo is { } photo && photo.Id.ProfileId != record.ProfileId) throw Invalid();
        if (record.Fingerprint != PhotoTextHash(JsonSerializer.Serialize(record.Edit))) throw Invalid();
        if (record.Result is { } result) ValidatePhotoFolder(result);
        return record.State == SynologyPhotoChangeState.Submitting ? record with { State = SynologyPhotoChangeState.PendingReview } : record;
    }
    private void CheckFolderOwner(PhotoFolderChangeRecord record)
    {
        RequireManagementStore(); RequireAccess(record.Edit.Folder.Space);
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoFolderChangeTask OwnedFolderChange(Guid id)
    {
        if (!_changes.Folders.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckFolderOwner(task.Record); return task;
    }
    private Task SaveFolderChangeAsync(PhotoFolderChangeTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Folder: task.Record));
    private static SynologyPhotoFolderChange FolderChangeSnapshot(PhotoFolderChangeTask task) => new(task.Record.Id, task.Record.Edit,
        task.Record.State, task.Record.Result, task.Record.Failure, task.Running,
        !task.Running && task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
    private static bool ActiveFolderChange(PhotoFolderChangeRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    public async Task<IReadOnlyList<SynologyPhotoFolderChange>> FolderChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Folders.Values.Where(task => task.Record.Owner == owner).Select(FolderChangeSnapshot).ToArray();
    }
    public async Task<SynologyPhotoFolderChange> EditFolderAsync(Guid operationId, SynologyPhotoFolderEdit edit, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty) throw Invalid(); ValidateFolderEdit(edit);
        if (edit.Photo is { } cover) edit = edit with { Photo = MinimalManagedPhoto(cover) };
        var record = new PhotoFolderChangeRecord(operationId, ProfileId, UploadOwner(), PhotoTextHash(JsonSerializer.Serialize(edit)), edit);
        await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) || _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Folders.TryGetValue(operationId, out var old))
            {
                CheckFolderOwner(old.Record);
                if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing = true;
            }
            else
            {
                if (_changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) &&
                    task.Record.Edit.Folder.Space == edit.Folder.Space &&
                    (task.Record.Edit.Folder.Id == edit.Folder.Id && (task.Record.Edit.Kind != SynologyPhotoFolderEditKind.Create || edit.Kind != SynologyPhotoFolderEditKind.Create || task.Record.Edit.Name == edit.Name) ||
                     FolderRenameContains(task.Record, edit.Folder.Path) ||
                     edit.Kind == SynologyPhotoFolderEditKind.Rename && (FolderContains(edit.Folder.Path, task.Record.Edit.Folder.Path) ||
                         task.Record.Edit.Kind == SynologyPhotoFolderEditKind.Rename && FolderContains(edit.Folder.Path, RenamedFolderPath(task.Record.Edit.Folder, task.Record.Edit.Name!))))))
                    throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
                await PrepareFolderEditAsync(record, cancellationToken).ConfigureAwait(false);
                var task = new PhotoFolderChangeTask(record); await SaveFolderChangeAsync(task).ConfigureAwait(false); _changes.Folders.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewFolderChangeAsync(operationId, cancellationToken).ConfigureAwait(false) :
            await ContinueFolderChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoFolderChange> ContinueFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FolderChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1));
        var uploads = _uploads.OwnerGates.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var ownsOwner = false; var ownsUpload = false;
        task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); ownsOwner = true;
            await uploads.WaitAsync(cancellationToken).ConfigureAwait(false); ownsUpload = true;
            await ReviewFolderCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
                await SendFolderChangeAsync(task, cancellationToken).ConfigureAwait(false);
        }
        finally { task.Running = false; if (ownsUpload) uploads.Release(); if (ownsOwner) owner.Release(); task.Gate.Release(); }
        return FolderChangeSnapshot(task);
    }
    private async Task SendFolderChangeAsync(PhotoFolderChangeTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await PrepareFolderEditAsync(task.Record, token).ConfigureAwait(false);
            var edit = task.Record.Edit; var version = edit.Kind == SynologyPhotoFolderEditKind.Cover ? 2 : 1;
            var capability = Capability("Browse.Folder", version, edit.Folder.Space);
            if (edit.Kind == SynologyPhotoFolderEditKind.Rename && edit.Name == edit.Folder.Name || edit.Kind == SynologyPhotoFolderEditKind.Sort && edit.Sort == edit.Folder.Sort)
            { task.Record = task.Record with { State = SynologyPhotoChangeState.Completed, Result = edit.Folder }; await SaveFolderChangeAsync(task).ConfigureAwait(false); return; }
            var method = edit.Kind switch { SynologyPhotoFolderEditKind.Create => "create", SynologyPhotoFolderEditKind.Rename => "rename", SynologyPhotoFolderEditKind.Cover => "set_cover", _ => "set_order" };
            var fields = edit.Kind == SynologyPhotoFolderEditKind.Cover ? Parameters(("id", edit.Folder.Id), ("id_item", new[] { edit.Photo!.Id.ItemId })) : edit.Kind == SynologyPhotoFolderEditKind.Sort
                ? Parameters(("id", edit.Folder.Id), ("sort_by", SortField(edit.Sort!.Field)), ("sort_direction", edit.Sort.Descending ? "desc" : "asc"))
                : Parameters((edit.Kind == SynologyPhotoFolderEditKind.Create ? "target_id" : "id", edit.Folder.Id), ("name", edit.Name!));
            task.Record = task.Record with { State = SynologyPhotoChangeState.Submitting, Failure = null };
            await SaveFolderChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFolderOwner(task.Record);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, version, method, fields, token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure };
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted && edit.Kind == SynologyPhotoFolderEditKind.Create)
                task.Record = task.Record with { CreatedId = Positive(Object(receipt.Data?["folder"]), "id") };
            await SaveFolderChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFolderOwner(task.Record);
            await ReviewFolderCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore();
            task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveFolderChangeAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewFolderCoreAsync(PhotoFolderChangeTask task, CancellationToken token)
    {
        CheckFolderOwner(task.Record);
        if (task.Record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting)) return;
        var edit = task.Record.Edit;
        if (edit.Kind == SynologyPhotoFolderEditKind.Create && (!task.Record.Accepted || task.Record.CreatedId is null)) return;
        if (edit.Kind == SynologyPhotoFolderEditKind.Cover && !task.Record.Accepted) return;
        try
        {
            await FreshManagementAccessAsync([edit.Folder.Space], token).ConfigureAwait(false);
            var id = edit.Kind == SynologyPhotoFolderEditKind.Create ? task.Record.CreatedId!.Value : edit.Folder.Id;
            var raw = await ReadPhotoFolderAsync(id, edit.Folder.Space, edit.Kind == SynologyPhotoFolderEditKind.Sort ? PhotoFolderRight.View :
                edit.Kind == SynologyPhotoFolderEditKind.Create ? PhotoFolderRight.Upload : PhotoFolderRight.Manage, token).ConfigureAwait(false);
            var result = PhotoFolder(raw, edit.Folder.Space);
            var matches = edit.Kind switch
            {
                SynologyPhotoFolderEditKind.Create => result.ParentId == edit.Folder.Id && result.Path == ChildFolderPath(edit.Folder.Path, edit.Name!),
                SynologyPhotoFolderEditKind.Rename => result.ParentId == edit.Folder.ParentId && result.Path == RenamedFolderPath(edit.Folder, edit.Name!),
                SynologyPhotoFolderEditKind.Cover => SamePhotoFolder(result, edit.Folder) && await VerifyFolderCoverAsync(raw, edit.Folder, token).ConfigureAwait(false),
                _ => SamePhotoFolder(result, edit.Folder) && ExplicitFolderSort(raw) == edit.Sort,
            };
            if (!matches) return;
            task.Record = task.Record with { State = SynologyPhotoChangeState.Completed, Result = result, Failure = null };
            await SaveFolderChangeAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    public async Task<SynologyPhotoFolderChange> ReviewFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FolderChangeSnapshot(task);
        try { await ReviewFolderCoreAsync(task, cancellationToken).ConfigureAwait(false); return FolderChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoFolderChange> CancelFolderChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFolderChange(operationId);
        await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            { task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled }; await SaveFolderChangeAsync(task).ConfigureAwait(false); }
            return FolderChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
