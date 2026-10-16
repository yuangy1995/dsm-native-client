using System.Collections.Concurrent;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static readonly ConditionalWeakTable<IProtectedTaskStore, PhotoManagementRegistry> ManagementRegistries = new();
    private readonly IProtectedTaskStore? _managementStore;
    private readonly PhotoManagementRegistry _changes;
    public bool SupportsManagement => _managementStore is not null;
    private sealed class PhotoManagementRegistry
    {
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal readonly ConcurrentDictionary<Guid, PhotoChangeTask> Tasks = new();
        internal readonly ConcurrentDictionary<Guid, PhotoFolderChangeTask> Folders = new();
        internal readonly ConcurrentDictionary<Guid, PhotoFileChangeTask> Files = new();
        internal readonly ConcurrentDictionary<Guid, PhotoAlbumChangeTask> Albums = new();
        internal readonly ConcurrentDictionary<Guid, PhotoSharingTask> Sharing = new();
        internal readonly ConcurrentDictionary<Guid, PhotoTemporaryTask> Temporary = new();
        internal readonly ConcurrentDictionary<Guid, PhotoRequestTask> Requests = new();
        internal readonly ConcurrentDictionary<Guid, PhotoFolderSharingTask> FolderSharing = new();
        internal readonly ConcurrentDictionary<Guid, PhotoRecognitionTask> Recognition = new();
        internal readonly ConcurrentDictionary<Guid, PhotoPreviewTask> Previews = new();
        internal readonly ConcurrentDictionary<Guid, PhotoAutomaticTask> Automatic = new();
        internal readonly ConcurrentDictionary<Guid, PhotoSettingsTask> Settings = new();
        internal readonly ConcurrentDictionary<string, SemaphoreSlim> Owners = new(StringComparer.Ordinal);
        internal volatile bool Loaded;
        internal volatile bool Failed;
    }
    private sealed class PhotoChangeTask(PhotoChangeRecord record)
    {
        internal volatile PhotoChangeRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal readonly ConcurrentDictionary<SynologyPhotoIdentity, SynologyPhoto> Updated = new();
        internal string? Text;
        internal volatile bool Running, Stop;
    }
    private sealed record PhotoChangeRecord(int Version, Guid Id, Guid ProfileId, string Owner, string Fingerprint,
        SynologyPhotoEditKind Kind, SynologyPhotoSpace Space, string? TextHash, long[] TagIds, PhotoChangeEntry[] Items,
        SynologyPhotoChangeState TagState = SynologyPhotoChangeState.Ready, long? CreatedTagId = null);
    private sealed record PhotoChangeEntry(SynologyPhoto Original, long? ExpectedValue, string? OriginalTextHash, long[]? OriginalTags,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false,
        bool ReportedFailure = false, SynologyPhotoFailure? Failure = null);
    private sealed record PhotoManagementRecord(int Version, PhotoChangeRecord? Metadata = null, PhotoFolderChangeRecord? Folder = null, PhotoFileChangeRecord? Files = null, PhotoAlbumChangeRecord? Album = null, PhotoSharingRecord? Sharing = null, PhotoTemporaryRecord? Temporary = null, PhotoRequestRecord? Request = null, PhotoFolderSharingRecord? FolderSharing = null, PhotoRecognitionRecord? Recognition = null, PhotoPreviewRecord? Preview = null, PhotoAutomaticRecord? Automatic = null, PhotoSettingsRecord? Settings = null);
    private static string PhotoTextHash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static SynologyPhoto MinimalManagedPhoto(SynologyPhoto photo) => new(photo.Id, photo.Filename, photo.SizeBytes,
        photo.TakenAt, photo.IndexedAt, photo.FolderId, photo.MediaType)
    { AlbumContext = photo.AlbumContext, Rating = photo.Rating, Width = photo.Width, Height = photo.Height, Orientation = photo.Orientation };
    private void RequireManagementStore()
    {
        if (_managementStore is null) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (_changes.Failed) throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable);
    }
    private async Task LoadChangesAsync()
    {
        RequireManagementStore(); if (_changes.Loaded) return; await _changes.Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            RequireManagementStore(); if (_changes.Loaded) return;
            IReadOnlyDictionary<Guid, byte[]>? data = null;
            try
            {
                data = await _managementStore!.LoadAsync().ConfigureAwait(false);
                var records = data.Select(pair => (pair.Key, Record: JsonSerializer.Deserialize<PhotoManagementRecord>(pair.Value,
                    new JsonSerializerOptions { MaxDepth = 24 }) ?? throw Invalid())).ToArray();
                foreach (var (id, record) in records)
                {
                    if (record.Version != 1 || (record.Metadata is null ? 0 : 1) + (record.Folder is null ? 0 : 1) + (record.Files is null ? 0 : 1) + (record.Album is null ? 0 : 1) + (record.Sharing is null ? 0 : 1) + (record.Temporary is null ? 0 : 1) + (record.Request is null ? 0 : 1) + (record.FolderSharing is null ? 0 : 1) + (record.Recognition is null ? 0 : 1) + (record.Preview is null ? 0 : 1) + (record.Automatic is null ? 0 : 1) + (record.Settings is null ? 0 : 1) != 1) throw Invalid();
                    if (record.Metadata is { } metadata) _changes.Tasks.TryAdd(id, new(RestoreChange(id, metadata)));
                    else if (record.Folder is { } folder) _changes.Folders.TryAdd(id, new(RestoreFolderChange(id, folder)));
                    else if (record.Files is { } files) _changes.Files.TryAdd(id, new(RestoreFileChange(id, files)));
                    else if (record.Album is { } album) _changes.Albums.TryAdd(id, new(RestoreAlbumChange(id, album)));
                    else if (record.Sharing is { } sharing) _changes.Sharing.TryAdd(id, new(RestoreSharing(id, sharing)));
                    else if (record.Temporary is { } temporary) _changes.Temporary.TryAdd(id, new(RestoreTemporary(id, temporary)));
                    else if (record.Request is { } request) _changes.Requests.TryAdd(id, new(RestoreRequest(id, request)));
                    else if (record.FolderSharing is { } folderSharing) _changes.FolderSharing.TryAdd(id, new(RestoreFolderSharing(id, folderSharing)));
                    else if (record.Recognition is { } recognition) _changes.Recognition.TryAdd(id, new(RestoreRecognition(id, recognition)));
                    else if (record.Preview is { } preview) _changes.Previews.TryAdd(id, new(RestorePreview(id, preview)));
                    else if (record.Automatic is { } automatic) _changes.Automatic.TryAdd(id, new(RestoreAutomatic(id, automatic)));
                    else _changes.Settings.TryAdd(id, new(RestoreSettings(id, record.Settings!)));
                }
                _changes.Loaded = true;
            }
            catch { _changes.Failed = true; throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable); }
            finally { if (data is not null) foreach (var bytes in data.Values) CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { _changes.Gate.Release(); }
    }
    private static PhotoChangeRecord RestoreChange(Guid id, PhotoChangeRecord record)
    {
        if (record.Version != 1 || record.Id != id || id == Guid.Empty || record.ProfileId == Guid.Empty ||
            !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) || !Enum.IsDefined(record.Kind) || !Enum.IsDefined(record.Space) ||
            !Enum.IsDefined(record.TagState) || record.Items is not { Length: <= 100 } || record.TagIds is null ||
            record.Items.Length == 0 && record.Kind != SynologyPhotoEditKind.CreateTag ||
            record.Kind is SynologyPhotoEditKind.Description or SynologyPhotoEditKind.CreateTag && !UploadHash(record.TextHash) ||
            record.CreatedTagId <= 0 || record.TagIds.Any(value => value <= 0) || record.TagIds.Distinct().Count() != record.TagIds.Length ||
            record.Items.DistinctBy(item => item.Original.Id).Count() != record.Items.Length) throw Invalid();
        foreach (var item in record.Items)
        {
            var photo = item.Original;
            if (photo.Id.ProfileId != record.ProfileId || photo.Id.ItemId <= 0 || photo.FolderId <= 0 || photo.SizeBytes < 0 ||
                !Enum.IsDefined(photo.Id.Space) || !Enum.IsDefined(item.State) || item.Failure is { } failure && !Enum.IsDefined(failure) ||
                item.OriginalTextHash is not null && !UploadHash(item.OriginalTextHash) ||
                record.Kind == SynologyPhotoEditKind.Rating && item.ExpectedValue is not (>= 0 and <= 5) ||
                record.Kind is SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates && item.ExpectedValue is null ||
                record.Kind == SynologyPhotoEditKind.Rotate && (!photo.SupportsRotation || item.ExpectedValue != photo.CounterClockwiseOrientation) ||
                item.OriginalTags?.Any(value => value <= 0) == true) throw Invalid();
        }
        return record with
        {
            TagState = record.TagState == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.TagState,
            Items = record.Items.Select(item => item.State == SynologyPhotoChangeState.Submitting
                ? item with { State = SynologyPhotoChangeState.PendingReview } : item).ToArray(),
        };
    }
    private async Task SaveChangeAsync(PhotoChangeTask task)
    {
        await SaveManagementRecordAsync(task.Record.Id, new(1, Metadata: task.Record)).ConfigureAwait(false);
    }
    private async Task SaveManagementRecordAsync(Guid id, PhotoManagementRecord record)
    {
        RequireManagementStore(); var bytes = JsonSerializer.SerializeToUtf8Bytes(record);
        try { await _managementStore!.SaveAsync(id, bytes).ConfigureAwait(false); }
        catch { _changes.Failed = true; throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private async Task SetChangeEntryAsync(PhotoChangeTask task, int index, PhotoChangeEntry entry)
    {
        var items = task.Record.Items.ToArray(); items[index] = entry; task.Record = task.Record with { Items = items };
        await SaveChangeAsync(task).ConfigureAwait(false);
    }
    private PhotoChangeTask OwnedChange(Guid id)
    {
        RequireManagementStore();
        if (!_changes.Tasks.TryGetValue(id, out var task) || task.Record.ProfileId != ProfileId || task.Record.Owner != UploadOwner())
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return task;
    }
    private static bool UnresolvedChange(PhotoChangeTask task) => task.Record.TagState is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview ||
        task.Record.Items.Any(item => item.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview);
    private static SynologyPhotoChange ChangeSnapshot(PhotoChangeTask task)
    {
        var record = task.Record;
        var needsText = record.Kind == SynologyPhotoEditKind.Description || record.Kind == SynologyPhotoEditKind.CreateTag && record.CreatedTagId is null;
        var canContinue = !task.Running && !UnresolvedChange(task) && (!needsText || task.Text is not null) &&
            (record.Kind == SynologyPhotoEditKind.CreateTag && record.TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed ||
             record.Items.Any(item => item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed));
        return new(record.Id, record.Kind, record.Space, record.Items.Select(item => new SynologyPhotoChangeItem(item.Original,
            item.State, task.Updated.GetValueOrDefault(item.Original.Id), item.Failure)).ToArray(), record.TagState,
            record.CreatedTagId is { } id ? new(id, task.Text ?? "") : null, task.Running, canContinue);
    }
    public async Task<IReadOnlyList<SynologyPhotoChange>> ChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (UploadOwner() != owner) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Tasks.Values.Where(task => task.Record.Owner == owner).Select(ChangeSnapshot).ToArray();
    }
    public async Task<SynologyPhotoChange> EditAsync(Guid operationId, SynologyPhotoEdit edit, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty) throw Invalid();
        var record = ChangeRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existingOperation = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) || _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) || _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Tasks.ContainsKey(operationId))
            {
                var existing = OwnedChange(operationId);
                if (existing.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing.Text = edit.Text; existingOperation = true;
            }
            else
            {
                if (_changes.Tasks.Values.Where(task => task.Record.Owner == record.Owner).Any(task =>
                    task.Record.Items.Any(item => item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled) && record.Items.Any(next => next.Original.Id == item.Original.Id)) ||
                    task.Record.Kind == SynologyPhotoEditKind.CreateTag && task.Record.Space == record.Space && task.Record.TextHash == record.TextHash &&
                        task.Record.TagState is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled)))
                    throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
                await PrepareChangeRecordAsync(record, cancellationToken).ConfigureAwait(false);
                var task = new PhotoChangeTask(record) { Text = edit.Text };
                await SaveChangeAsync(task).ConfigureAwait(false); _changes.Tasks.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existingOperation ? await ReviewChangeAsync(operationId, cancellationToken).ConfigureAwait(false)
            : await ContinueChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoChange> CancelChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedChange(operationId); task.Stop = true;
        await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            task.Record = task.Record with
            {
                TagState = task.Record.TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed ? SynologyPhotoChangeState.Cancelled : task.Record.TagState,
                Items = task.Record.Items.Select(item => item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed
                    ? item with { State = SynologyPhotoChangeState.Cancelled } : item).ToArray(),
            };
            await SaveChangeAsync(task).ConfigureAwait(false); return ChangeSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
