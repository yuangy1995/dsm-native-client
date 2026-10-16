using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoRequestFolder(SynologyPhotoSpace Space, long Id);
    private sealed record PhotoRequestPath(SynologyPhotoSpace Space, string[] Ancestors);
    private sealed record PhotoRequestRecord(Guid Id, Guid ProfileId, string Owner, SynologyPhotoRequestEditKind Kind,
        string Fingerprint, string Key, string? TargetHash, string? OriginalHash, string? ExpectedHash, bool IgnoreFolderId,
        SynologyPhotoSpace Space, PhotoRequestFolder[] Folders, PhotoRequestPath[] Paths, long? AlbumId = null,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false, SynologyPhotoFailure? Failure = null);
    private sealed class PhotoRequestTask(PhotoRequestRecord record)
    {
        internal volatile PhotoRequestRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal SynologyPhotoRequestEdit? Edit;
        internal SynologyPhotoRequest? Result;
        internal volatile bool Running;
    }
    private PhotoRequestRecord CreateRequestRecord(Guid id, SynologyPhotoRequestEdit edit)
    {
        if (id == Guid.Empty || !Enum.IsDefined(edit.Kind) ||
            edit.Kind == SynologyPhotoRequestEditKind.Create != (edit.Original is null) ||
            edit.Kind == SynologyPhotoRequestEditKind.Delete != (edit.Settings is null) ||
            edit.Settings is { IsValid: false } || edit.Original is { Id.Length: 0 }) throw Invalid();
        if (edit.Original is { } original && original.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var target = edit.Original is null ? null : PhotoTextHash(edit.Original.Id);
        var previous = edit.Original is null ? null : RequestSnapshotHash(edit.Original);
        var expected = edit.Settings is null ? null : RequestSettingsHash(edit.Settings, edit.Settings.FolderId is null);
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Kind, previous, expected }));
        var key = target ?? PhotoTextHash(JsonSerializer.Serialize(new { edit.Settings!.Subject, edit.Settings.Space }));
        var folders = edit.Kind == SynologyPhotoRequestEditKind.Delete ? [] : new[] { edit.Original?.Settings, edit.Settings }
            .OfType<SynologyPhotoRequestSettings>().Where(value => value.FolderId is not null)
            .Select(value => new PhotoRequestFolder(value.Space, value.FolderId!.Value)).Distinct().ToArray();
        var paths = edit.Kind == SynologyPhotoRequestEditKind.Delete ? [] : new[] { edit.Original?.Settings, edit.Settings }
            .OfType<SynologyPhotoRequestSettings>().Select(value =>
            {
                var parts = value.FolderPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
                return new PhotoRequestPath(value.Space, Enumerable.Range(0, parts.Length + 1).Select(count => PhotoTextHash("/" + string.Join('/', parts.Take(count)))).ToArray());
            }).ToArray();
        return new(id, ProfileId, UploadOwner(), edit.Kind, fingerprint, key, target, previous, expected,
            edit.Settings?.FolderId is null, (edit.Settings ?? edit.Original!.Settings).Space, folders, paths);
    }
    private static PhotoRequestRecord RestoreRequest(Guid id, PhotoRequestRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !Enum.IsDefined(record.Kind) || !Enum.IsDefined(record.Space) ||
            !Enum.IsDefined(record.State) || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) || !UploadHash(record.Key) ||
            record.Kind != SynologyPhotoRequestEditKind.Create && (!UploadHash(record.TargetHash) || !UploadHash(record.OriginalHash)) ||
            record.Kind != SynologyPhotoRequestEditKind.Delete && !UploadHash(record.ExpectedHash) ||
            record.TargetHash is not null && !UploadHash(record.TargetHash) || record.OriginalHash is not null && !UploadHash(record.OriginalHash) ||
            record.AlbumId <= 0 || record.Folders is not { Length: <= 2 } || record.Folders.Any(folder => folder.Id <= 0 || !Enum.IsDefined(folder.Space)) ||
            record.Paths is not { Length: <= 2 } || record.Paths.Any(path => !Enum.IsDefined(path.Space) || path.Ancestors is not { Length: > 0 } || path.Ancestors.Any(hash => !UploadHash(hash))) ||
            record.Failure is { } failure && !Enum.IsDefined(failure)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private void CheckRequestOwner(PhotoRequestRecord record)
    {
        RequireManagementStore(); RequirePhotoRequests();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoRequestTask OwnedRequest(Guid id)
    {
        if (!_changes.Requests.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckRequestOwner(task.Record); return task;
    }
    private Task SaveRequestAsync(PhotoRequestTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Request: task.Record));
    private static bool ActiveRequest(PhotoRequestRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static bool RequestNeedsInput(PhotoRequestTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed && task.Edit is null && task.Record.Kind != SynologyPhotoRequestEditKind.Delete;
    private static bool RequestCanContinue(PhotoRequestTask task) => task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed && !RequestNeedsInput(task);
    private static SynologyPhotoRequestChange RequestChangeSnapshot(PhotoRequestTask task) => new(task.Record.Id, task.Record.Kind, task.Record.State,
        task.Record.Failure, task.Running, !task.Running && RequestCanContinue(task), RequestNeedsInput(task), task.Result);
    private async Task<(SynologyPhotoRequest? Original, long? AlbumId)> PrepareRequestCoreAsync(PhotoRequestRecord record, SynologyPhotoRequestEdit? edit, CancellationToken token)
    {
        CheckRequestOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        if (record.Space == SynologyPhotoSpace.Shared && MembersBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (!SharingSafety.Requests) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await FreshManagementAccessAsync(record.Kind == SynologyPhotoRequestEditKind.Delete
            ? [_personalAllowed ? SynologyPhotoSpace.Personal : SynologyPhotoSpace.Shared] : [record.Space], token).ConfigureAwait(false);
        _ = Capability("PhotoRequest", 1, null);
        if (_changes.Requests.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveRequest(task.Record) &&
            (task.Record.Key == record.Key || record.TargetHash is not null && task.Record.TargetHash == record.TargetHash)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        SynologyPhotoRequest? current = null;
        if (record.Kind != SynologyPhotoRequestEditKind.Create)
        {
            current = await FindPhotoRequestAsync(record.TargetHash!, token).ConfigureAwait(false);
            if (current is null || RequestSnapshotHash(current) != record.OriginalHash) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        long? albumId = null;
        if (record.Kind != SynologyPhotoRequestEditKind.Delete)
        {
            if (edit?.Settings is not { } settings || RequestSettingsHash(settings, record.IgnoreFolderId) != record.ExpectedHash)
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            albumId = await ValidateRequestSettingsAsync(settings, record.Id, token).ConfigureAwait(false);
            if (record.AlbumId is not null && record.AlbumId != albumId) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        RequireGeneration(generation, token); CheckRequestOwner(record); return (current, albumId);
    }
    public async Task PreparePhotoRequestAsync(SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateRequestRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareRequestCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
    }
    public async Task<IReadOnlyList<SynologyPhotoRequestChange>> PhotoRequestChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Requests.Values.Where(task => task.Record.Owner == owner).Select(RequestChangeSnapshot).ToArray();
    }
    public async Task<SynologyPhotoRequestChange> EditPhotoRequestAsync(Guid operationId, SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateRequestRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Requests.TryGetValue(operationId, out var old))
            {
                CheckRequestOwner(old.Record); if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (!old.Running) old.Edit = edit; existing = true;
            }
            else
            {
                var prepared = await PrepareRequestCoreAsync(record, edit, cancellationToken).ConfigureAwait(false);
                var task = new PhotoRequestTask(record with { AlbumId = prepared.AlbumId }) { Edit = edit, Result = prepared.Original };
                await SaveRequestAsync(task).ConfigureAwait(false); _changes.Requests.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewPhotoRequestAsync(operationId, cancellationToken).ConfigureAwait(false) : await ContinuePhotoRequestAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoRequestChange> ContinuePhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRequest(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return RequestChangeSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await ReviewRequestCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (RequestCanContinue(task)) await SendRequestAsync(task, cancellationToken).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return RequestChangeSnapshot(task);
    }
    public async Task<SynologyPhotoRequestChange> ReviewPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRequest(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return RequestChangeSnapshot(task);
        try { await ReviewRequestCoreAsync(task, cancellationToken).ConfigureAwait(false); return RequestChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoRequestChange> CancelPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRequest(operationId); await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            { task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled }; task.Edit = null; await SaveRequestAsync(task).ConfigureAwait(false); }
            return RequestChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
