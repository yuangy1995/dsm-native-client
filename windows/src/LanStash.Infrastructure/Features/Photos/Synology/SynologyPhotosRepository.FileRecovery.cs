using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsFileManagement => SupportsManagement;
    private sealed record PhotoFileChangeRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint,
        SynologyPhotoFileCommand Command, SynologyPhotoFolder[] Parents, SynologyPhotoFileState State = SynologyPhotoFileState.Ready,
        bool Accepted = false, long? TaskId = null, long? Total = null, bool TargetVerified = false,
        SynologyPhotoFileCounts? Counts = null, SynologyPhotoFailure? Failure = null, bool ReceiptConflict = false);
    private sealed class PhotoFileChangeTask(PhotoFileChangeRecord record)
    {
        internal volatile PhotoFileChangeRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal volatile bool Running;
    }
    private static bool ActiveFileChange(PhotoFileChangeRecord record) => record.State is
        SynologyPhotoFileState.Ready or SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview or SynologyPhotoFileState.Failed;
    private static SynologyPhotoFileCommand FreezeFiles(SynologyPhotoFileCommand command) => command with
    {
        Photos = command.Photos.Select(MinimalManagedPhoto).OrderBy(photo => photo.Id.ItemId).ToArray(),
        Folders = command.Folders.Select(folder => folder with { Sort = null }).OrderBy(folder => folder.Id).ToArray(),
        Destination = command.Destination is { } destination ? destination with { Sort = null } : null,
    };
    private static PhotoFileChangeRecord RestoreFileChange(Guid id, PhotoFileChangeRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.State) || record.TaskId <= 0 || record.Total < 0 || record.Parents is null ||
            record.Failure is { } failure && !Enum.IsDefined(failure)) throw Invalid();
        ValidateFileCommand(record.Command);
        if (record.Command.Photos.Any(photo => photo.Id.ProfileId != record.ProfileId) ||
            PhotoTextHash(JsonSerializer.Serialize(record.Command)) != record.Fingerprint) throw Invalid();
        foreach (var parent in record.Parents) ValidatePhotoFolder(parent);
        if (record.Parents.Select(parent => parent.Id).Distinct().Count() != record.Parents.Length ||
            record.Parents.Any(parent => parent.Space != record.Command.Space) ||
            !record.Command.Photos.Select(photo => photo.FolderId).Concat(record.Command.Folders.Select(folder => folder.ParentId)).Distinct()
                .Order().SequenceEqual(record.Parents.Select(parent => parent.Id).Order())) throw Invalid();
        if (record.TaskId is not null && !record.Accepted || record.Counts is { } counts &&
            (counts.Total < 0 || counts.Completion < 0 || counts.Completion > counts.Total || counts.Error < 0 || counts.Error > counts.Completion ||
             counts.Skip < 0 || counts.Skip > counts.Completion || counts.Overwrite < 0 || counts.Overwrite > counts.Completion)) throw Invalid();
        return record.State == SynologyPhotoFileState.Submitting ? record with { State = SynologyPhotoFileState.PendingReview } : record;
    }
    private void CheckFileOwner(PhotoFileChangeRecord record)
    {
        RequireManagementStore(); RequireAccess(record.Command.Space);
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (record.Command.Destination is { } target) RequireAccess(target.Space);
    }
    private PhotoFileChangeTask OwnedFileChange(Guid id)
    {
        if (!_changes.Files.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckFileOwner(task.Record); return task;
    }
    private Task SaveFileChangeAsync(PhotoFileChangeTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Files: task.Record));
    private static SynologyPhotoFileChange FileChangeSnapshot(PhotoFileChangeTask task) => new(task.Record.Id, task.Record.Command,
        task.Record.State, task.Record.Counts, task.Record.Failure, task.Running,
        !task.Running && task.Record.State is SynologyPhotoFileState.Ready or SynologyPhotoFileState.Failed);
    public async Task<IReadOnlyList<SynologyPhotoFileChange>> FileChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Files.Values.Where(task => task.Record.Owner == owner).Select(FileChangeSnapshot).ToArray();
    }
    public async Task PrepareFilesAsync(SynologyPhotoFileCommand command, CancellationToken cancellationToken = default)
    {
        ValidateFileCommand(command); var frozen = FreezeFiles(command); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareFilesCoreAsync(new(Guid.Empty, ProfileId, UploadOwner(), PhotoTextHash(JsonSerializer.Serialize(frozen)), frozen, []), cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoFileChange> ChangeFilesAsync(Guid operationId, SynologyPhotoFileCommand command, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty) throw Invalid(); ValidateFileCommand(command); command = FreezeFiles(command);
        var record = new PhotoFileChangeRecord(operationId, ProfileId, UploadOwner(), PhotoTextHash(JsonSerializer.Serialize(command)), command, []);
        await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Files.TryGetValue(operationId, out var old))
            {
                CheckFileOwner(old.Record);
                if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing = true;
            }
            else
            {
                var parents = await PrepareFilesCoreAsync(record, cancellationToken).ConfigureAwait(false);
                var task = new PhotoFileChangeTask(record with { Parents = parents });
                await SaveFileChangeAsync(task).ConfigureAwait(false); _changes.Files.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewFileChangeAsync(operationId, cancellationToken).ConfigureAwait(false) :
            await ContinueFileChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoFileChange> ContinueFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFileChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FileChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1));
        var uploads = _uploads.OwnerGates.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var ownsOwner = false; var ownsUploads = false;
        task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); ownsOwner = true;
            await uploads.WaitAsync(cancellationToken).ConfigureAwait(false); ownsUploads = true;
            await ReviewFilesCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (task.Record.State is SynologyPhotoFileState.Ready or SynologyPhotoFileState.Failed)
                await SendFilesAsync(task, cancellationToken).ConfigureAwait(false);
        }
        finally { task.Running = false; if (ownsUploads) uploads.Release(); if (ownsOwner) owner.Release(); task.Gate.Release(); }
        return FileChangeSnapshot(task);
    }
    public async Task<SynologyPhotoFileChange> ReviewFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFileChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return FileChangeSnapshot(task);
        try { await ReviewFilesCoreAsync(task, cancellationToken).ConfigureAwait(false); return FileChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoFileChange> CancelFileChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedFileChange(operationId);
        await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoFileState.Ready or SynologyPhotoFileState.Failed)
            { task.Record = task.Record with { State = SynologyPhotoFileState.Cancelled }; await SaveFileChangeAsync(task).ConfigureAwait(false); }
            return FileChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
