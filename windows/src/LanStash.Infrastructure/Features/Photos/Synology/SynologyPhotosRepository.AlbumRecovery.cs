using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoAlbumChangeRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint, SynologyPhotoAlbumEdit Edit,
        string? NameHash, SynologyPhotoAlbumMemberChange[] Members, SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready,
        bool Accepted = false, bool MemberFailures = false, long? CreatedId = null, SynologyPhotoFailure? Failure = null,
        string? ConditionHash = null, bool ReplacementVerified = false, bool CleanupSent = false, bool CleanupAccepted = false, bool CleanupRejected = false);
    private sealed class PhotoAlbumChangeTask(PhotoAlbumChangeRecord record)
    {
        internal volatile PhotoAlbumChangeRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal string? Name;
        internal SynologyPhotoCondition? Condition;
        internal SynologyPhotoAlbum? Result;
        internal volatile bool Running;
    }
    private static string AlbumFingerprint(SynologyPhotoAlbumEdit edit, string? nameHash, string? conditionHash) => PhotoTextHash(JsonSerializer.Serialize(new { Edit = edit, NameHash = nameHash, ConditionHash = conditionHash }));
    private PhotoAlbumChangeRecord CreateAlbumRecord(Guid id, SynologyPhotoAlbumEdit edit)
    {
        if (id == Guid.Empty) throw Invalid(); ValidateAlbumEdit(edit);
        var nameHash = AlbumNeedsName(edit.Kind) ? PhotoTextHash(edit.Name!) : null;
        var conditionHash = AlbumNeedsCondition(edit.Kind) ? ConditionHash(edit.Condition!) : null;
        edit = edit with { Name = null, ConditionSpace = edit.Condition?.Space, Condition = null, Photos = edit.Photos.Select(MinimalManagedPhoto).ToArray() };
        if (edit.Photos.Any(photo => photo.Id.ProfileId != ProfileId) || edit.Album is { } album && album.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(id, ProfileId, UploadOwner(), AlbumFingerprint(edit, nameHash, conditionHash), edit, nameHash,
            edit.Photos.Select(photo => new SynologyPhotoAlbumMemberChange(photo, SynologyPhotoChangeState.Ready)).ToArray(), ConditionHash: conditionHash);
    }
    private static PhotoAlbumChangeRecord RestoreAlbumChange(Guid id, PhotoAlbumChangeRecord record)
    {
        ValidateAlbumEdit(record.Edit, true);
        if (id == Guid.Empty || record.Id != id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) ||
            record.Edit.Name is not null || record.Edit.Condition is not null || record.Fingerprint != AlbumFingerprint(record.Edit, record.NameHash, record.ConditionHash) ||
            AlbumNeedsCondition(record.Edit.Kind) && !UploadHash(record.ConditionHash) ||
            record.ReplacementVerified && (record.Edit.Kind != SynologyPhotoAlbumEditKind.Rebuild || !record.Accepted || record.CreatedId is null || record.CreatedId == record.Edit.Album!.Id) ||
            record.CleanupSent && !record.ReplacementVerified || record.CleanupAccepted && (!record.CleanupSent || record.CleanupRejected) || record.CleanupRejected && !record.CleanupSent ||
            AlbumNeedsName(record.Edit.Kind) && !UploadHash(record.NameHash) || !Enum.IsDefined(record.State) || record.CreatedId <= 0 ||
            record.Failure is { } failure && !Enum.IsDefined(failure) || record.Members is null || record.Members.Length != record.Edit.Photos.Count ||
            record.Members.Where((item, index) => JsonSerializer.Serialize(item.Photo) != JsonSerializer.Serialize(record.Edit.Photos[index]) ||
                !Enum.IsDefined(item.State) || item.Photo.Id.ProfileId != record.ProfileId).Any()) throw Invalid();
        return record with
        {
            State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State,
            Members = record.Members.Select(item => item.State == SynologyPhotoChangeState.Submitting ? item with { State = SynologyPhotoChangeState.PendingReview } : item).ToArray(),
        };
    }
    private void CheckAlbumOwner(PhotoAlbumChangeRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner() || record.Edit.Album is { } album && album.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoAlbumChangeTask OwnedAlbumChange(Guid id)
    {
        if (!_changes.Albums.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckAlbumOwner(task.Record); return task;
    }
    private Task SaveAlbumChangeAsync(PhotoAlbumChangeTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Album: task.Record));
    private static bool ActiveAlbumChange(PhotoAlbumChangeRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static SynologyPhotoAlbumChange AlbumChangeSnapshot(PhotoAlbumChangeTask task) => new(task.Record.Id,
        task.Record.Edit with { Name = task.Name, Condition = task.Condition }, task.Record.State, task.Record.Members, task.Result, task.Record.Failure, task.Running,
        !task.Running && AlbumCanContinue(task)) { ReplacementCreated = task.Record.ReplacementVerified };
    private static bool AlbumCanContinue(PhotoAlbumChangeTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed &&
        (task.Record.ReplacementVerified ? !task.Record.CleanupSent || task.Record.CleanupRejected :
        (!AlbumNeedsName(task.Record.Edit.Kind) || task.Name is not null) && (!AlbumNeedsCondition(task.Record.Edit.Kind) || task.Condition is not null));
    public async Task<IReadOnlyList<SynologyPhotoAlbumChange>> AlbumChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Albums.Values.Where(task => task.Record.Owner == owner).Select(AlbumChangeSnapshot).ToArray();
    }
    public async Task<SynologyPhotoAlbumChange> EditAlbumAsync(Guid operationId, SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateAlbumRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Albums.TryGetValue(operationId, out var old))
            {
                CheckAlbumOwner(old.Record);
                if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                old.Name = edit.Name; old.Condition = edit.Condition; existing = true;
            }
            else
            {
                _ = await PrepareAlbumCoreAsync(record, cancellationToken, edit.Condition).ConfigureAwait(false);
                var task = new PhotoAlbumChangeTask(record) { Name = edit.Name, Condition = edit.Condition };
                await SaveAlbumChangeAsync(task).ConfigureAwait(false); _changes.Albums.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewAlbumChangeAsync(operationId, cancellationToken).ConfigureAwait(false) :
            await ContinueAlbumChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoAlbumChange> ContinueAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedAlbumChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return AlbumChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1));
        var uploads = _uploads.OwnerGates.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var ownsOwner = false; var ownsUploads = false;
        task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); ownsOwner = true;
            await uploads.WaitAsync(cancellationToken).ConfigureAwait(false); ownsUploads = true;
            await ReviewAlbumCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (AlbumCanContinue(task))
            {
                if (task.Record.ReplacementVerified) await SendFrozenCleanupAsync(task, cancellationToken).ConfigureAwait(false);
                else await SendAlbumChangeAsync(task, cancellationToken).ConfigureAwait(false);
            }
        }
        finally { task.Running = false; if (ownsUploads) uploads.Release(); if (ownsOwner) owner.Release(); task.Gate.Release(); }
        return AlbumChangeSnapshot(task);
    }
    public async Task<SynologyPhotoAlbumChange> ReviewAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedAlbumChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return AlbumChangeSnapshot(task);
        try { await ReviewAlbumCoreAsync(task, cancellationToken).ConfigureAwait(false); return AlbumChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoAlbumChange> CancelAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedAlbumChange(operationId); await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            {
                task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled, Members = task.Record.Members.Select(item =>
                    item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed ? item with { State = SynologyPhotoChangeState.Cancelled } : item).ToArray() };
                await SaveAlbumChangeAsync(task).ConfigureAwait(false);
            }
            return AlbumChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
    private bool AlbumPhotoBusy(SynologyPhotoIdentity id) => _changes.Temporary.Values.Any(task => task.Record.Owner == UploadOwner() && ActiveTemporary(task.Record) && task.Record.Stage != SynologyPhotoTemporaryStage.Configure && task.Record.Sources.Contains(id)) || _changes.Albums.Values.Any(task => task.Record.Owner == UploadOwner() && ActiveAlbumChange(task.Record) && task.Record.Edit.Photos.Any(photo => photo.Id == id));
    private async Task CheckAlbumBusyAsync(long id, CancellationToken token, Guid except = default)
    {
        if (_managementStore is null) return; await LoadChangesAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
        if (_changes.Automatic.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveAutomatic(task.Record) &&
            (task.Record.Candidate.SourcePhoto is null || task.Record.Candidate.SourcePhoto.AlbumContext?.AlbumId == id))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (_changes.Temporary.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveTemporary(task.Record) && task.Record.Stage != SynologyPhotoTemporaryStage.Configure && (task.Record.AlbumId == id || task.Record.CopyId == id)) ||
            _changes.Recognition.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveRecognition(task.Record) && task.Record.Photos.Any(photo => photo.Album?.AlbumId == id)) ||
            _changes.Previews.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && task.Record.Items.Any(item => ActivePreview(item) && item.Original.AlbumContext?.AlbumId == id)) ||
            _changes.Requests.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveRequest(task.Record) && task.Record.AlbumId == id) ||
            _changes.Sharing.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveSharing(task.Record) && task.Record.AlbumId == id) ||
            _changes.Albums.Values.Any(task => task.Record.Id != except && task.Record.Owner == UploadOwner() && ActiveAlbumChange(task.Record) &&
            (task.Record.Edit.Album?.Id == id || task.Record.CreatedId == id || task.Record.Edit.Photos.Any(photo => photo.AlbumContext?.AlbumId == id))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
    private async Task CheckAlbumConflictsAsync(PhotoAlbumChangeRecord record, CancellationToken token)
    {
        var edit = record.Edit;
        if (_changes.Temporary.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveTemporary(task.Record) &&
            task.Record.Stage != SynologyPhotoTemporaryStage.Configure && (record.NameHash == task.Record.NameHash && AlbumCreates(edit.Kind) || edit.Photos.Any(photo => task.Record.Sources.Contains(photo.Id)))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (edit.Album is { } album) await CheckAlbumBusyAsync(album.Id, token, record.Id).ConfigureAwait(false);
        foreach (var id in edit.Photos.Select(photo => photo.AlbumContext?.AlbumId).OfType<long>().Distinct())
            await CheckAlbumBusyAsync(id, token, record.Id).ConfigureAwait(false);
        foreach (var task in _changes.Albums.Values.Where(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveAlbumChange(task.Record)))
        {
            var other = task.Record.Edit;
            if (AlbumCreates(edit.Kind) && AlbumCreates(other.Kind) && record.NameHash == task.Record.NameHash ||
                edit.Kind == SynologyPhotoAlbumEditKind.ListSort && other.Kind == edit.Kind && edit.Scope == other.Scope ||
                edit.Kind == SynologyPhotoAlbumEditKind.ListDisplay && other.Kind == edit.Kind ||
                edit.Photos.Any(photo => other.Photos.Any(existing => existing.Id == photo.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
        if (edit.Photos.Any(photo => RecognitionPhotoBusy(photo.Id) || PreviewPhotoBusy(photo.Id) || FilePhotoBusy(photo.Id) ||
            _changes.Tasks.Values.Any(task => task.Record.Owner == record.Owner && task.Record.Items.Any(item => item.Original.Id == photo.Id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
            _changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) && task.Record.Edit.Photo?.Id == photo.Id)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (edit.Album is { } target) await CheckAlbumContentBusyAsync(target.Id, record.Owner, token).ConfigureAwait(false);
    }
    private async Task CheckAlbumContentBusyAsync(long albumId, string owner, CancellationToken token)
    {
        if (_changes.Tasks.Values.Where(task => task.Record.Owner == owner).Any(task => task.Record.Items.Any(item =>
                item.Original.AlbumContext?.AlbumId == albumId && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
            _changes.Files.Values.Any(task => task.Record.Owner == owner && ActiveFileChange(task.Record) && task.Record.Command.Photos.Any(photo => photo.AlbumContext?.AlbumId == albumId)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (_uploadStore is null) return; await LoadUploadsAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
        if (_uploads.Tasks.Values.Any(task => task.Record.Owner == owner && task.Record.Target.AlbumId == albumId &&
            task.Record.Items.Any(item => item.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
}
