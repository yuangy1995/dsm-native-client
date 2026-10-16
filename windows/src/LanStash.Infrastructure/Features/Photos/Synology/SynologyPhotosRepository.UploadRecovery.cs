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
    private static readonly ConditionalWeakTable<IProtectedTaskStore, PhotoUploadRegistry> UploadRegistries = new();
    private readonly IProtectedTaskStore? _uploadStore;
    private readonly PhotoUploadRegistry _uploads;
    public bool SupportsUploads => _uploadStore is not null;

    private sealed class PhotoUploadRegistry
    {
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal readonly ConcurrentDictionary<Guid, PhotoUploadTask> Tasks = new();
        internal readonly ConcurrentDictionary<string, SemaphoreSlim> OwnerGates = new(StringComparer.Ordinal);
        internal bool Loaded;
        internal volatile bool Failed;
    }
    private sealed class PhotoUploadTask(PhotoUploadRecord record)
    {
        internal volatile PhotoUploadRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal readonly ConcurrentDictionary<Guid, string> Sources = new();
        internal readonly ConcurrentDictionary<Guid, long> Progress = new();
        internal volatile bool Running, Stop, CancelRemaining;
    }
    private sealed record PhotoUploadRecord(int Version, Guid Id, Guid ProfileId, string Owner,
        SynologyPhotoUploadTarget Target, SynologyPhotoCollection? Root, PhotoAlbumSnapshot? Album,
        PhotoUploadEntry[] Items, PhotoUploadFolder[] Folders);
    private sealed record PhotoAlbumSnapshot(long Id, long OwnerUserId, long UserId);
    private sealed record PhotoUploadFolder(long Parent, string Name, long Id);
    private sealed record PhotoUploadEntry(Guid Id, SynologyPhotoUploadFile File,
        SynologyPhotoUploadState State = SynologyPhotoUploadState.Queued, SynologyPhotoUploadStep Step = SynologyPhotoUploadStep.None,
        long? FolderId = null, long? FolderParent = null, string? FolderName = null,
        long? ReceiptId = null, bool Accepted = false, bool Rejected = false, string? UploadAction = null,
        SynologyPhoto? Photo = null, SynologyPhotoFailure? Failure = null);

    private string UploadOwner()
    {
        RequireAccess();
        if (_currentUserId is not > 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var uri = _api.GetBaseUri(_profile);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[]
        { ProfileId.ToString("N"), uri.Scheme, uri.IdnHost.ToLowerInvariant(), uri.Port.ToString(System.Globalization.CultureInfo.InvariantCulture),
            _profile.Username, _currentUserId.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) }))));
    }

    private async Task LoadUploadsAsync()
    {
        if (_uploadStore is null) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await _uploads.Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            RequireUploadStore();
            if (_uploads.Loaded) return;
            IReadOnlyDictionary<Guid, byte[]>? data = null;
            try
            {
                data = await _uploadStore.LoadAsync().ConfigureAwait(false);
                var records = data.Select(pair => RestoreUpload(pair.Key, pair.Value)).ToArray();
                foreach (var record in records) _uploads.Tasks.TryAdd(record.Id, new(record));
                _uploads.Loaded = true;
            }
            catch { _uploads.Failed = true; throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable); }
            finally { if (data is not null) foreach (var bytes in data.Values) CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { _uploads.Gate.Release(); }
    }
    private void RequireUploadStore()
    {
        if (_uploads.Failed) throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable);
    }
    private static PhotoUploadRecord RestoreUpload(Guid id, byte[] bytes)
    {
        var value = JsonSerializer.Deserialize<PhotoUploadRecord>(bytes, new JsonSerializerOptions { MaxDepth = 32 }) ?? throw Invalid();
        if (value.Version != 1 || id == Guid.Empty || value.Id != id || value.ProfileId == Guid.Empty || !UploadHash(value.Owner) ||
            value.Items is not { Length: > 0 and <= 10000 } || value.Folders is null ||
            value.Items.Select(item => item.Id).Distinct().Count() != value.Items.Length) throw Invalid();
        ValidateUploadTarget(value.Target);
        if (value.Target.DirectToAlbum ? value.Root is not null : value.Root is not { Id: > 0 } || value.Root.Space != value.Target.Space ||
                value.Target.FolderId is { } rootId && value.Root.Id != rootId) throw Invalid();
        if (value.Target.AlbumId is { } albumId ? value.Album is null || value.Album.Id != albumId || value.Album.OwnerUserId <= 0 || value.Album.UserId <= 0 : value.Album is not null) throw Invalid();
        foreach (var item in value.Items)
        {
            if (item.Id == Guid.Empty || item.File is null || !ValidUploadName(item.File.Name) || item.File.Length <= 0 ||
                !UploadHash(item.File.Sha256) || item.File.Directories is null || item.File.Directories.Count > 128 ||
                item.File.Directories.Any(name => !ValidUploadName(name)) || !Enum.IsDefined(item.State) || !Enum.IsDefined(item.Step) ||
                item.FolderId <= 0 || item.FolderParent <= 0 || item.ReceiptId <= 0 || item.Failure is { } failure && !Enum.IsDefined(failure) ||
                item.Photo is { } photo && (photo.Id.ProfileId != value.ProfileId || photo.Id.ItemId <= 0) ||
                item.Step == SynologyPhotoUploadStep.CreateFolder && (item.FolderParent is null || !ValidUploadName(item.FolderName)) ||
                item.Step == SynologyPhotoUploadStep.AddToAlbum && (item.Photo is null || value.Target.AlbumId is null || value.Target.DirectToAlbum) ||
                item.State is SynologyPhotoUploadState.Uploaded or SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped && item.Photo is null)
                throw Invalid();
        }
        if (value.Folders.Any(folder => folder.Id <= 0 || folder.Parent <= 0 || !ValidUploadName(folder.Name)) ||
            value.Folders.DistinctBy(folder => (folder.Parent, folder.Name)).Count() != value.Folders.Length) throw Invalid();
        // 保存提交前阶段后崩溃也不能证明未发出；重新启动只恢复查询能力。
        return value with { Items = value.Items.Select(item => item.State is SynologyPhotoUploadState.PreparingFolders or
            SynologyPhotoUploadState.Uploading or SynologyPhotoUploadState.AddingToAlbum
                ? item with { State = SynologyPhotoUploadState.PendingReview } : item).ToArray() };
    }
    private static bool UploadHash(string? hash) => hash is { Length: 64 } && hash.All(Uri.IsHexDigit);
    private static bool ValidUploadName(string? name) => !string.IsNullOrWhiteSpace(name) && name is not ("." or "..") &&
        name.Length <= 255 && !name.Any(character => char.IsControl(character) || character is '/' or '\\');

    private async Task SaveUploadAsync(PhotoUploadTask task)
    {
        RequireUploadStore();
        var bytes = JsonSerializer.SerializeToUtf8Bytes(task.Record);
        try { await _uploadStore!.SaveAsync(task.Record.Id, bytes).ConfigureAwait(false); }
        catch { _uploads.Failed = true; throw new SynologyPhotoException(SynologyPhotoFailure.RecoveryUnavailable); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private async Task SetUploadEntryAsync(PhotoUploadTask task, int index, PhotoUploadEntry entry)
    {
        var items = task.Record.Items.ToArray(); items[index] = entry;
        task.Record = task.Record with { Items = items };
        await SaveUploadAsync(task).ConfigureAwait(false);
    }
    private static SynologyPhotoUploadBatch UploadSnapshot(PhotoUploadTask task) => new(task.Record.Id, task.Record.ProfileId,
        task.Record.Target, task.Record.Items.Select(item => new SynologyPhotoUploadItem(item.Id, item.File with
            { Directories = item.File.Directories.ToArray() }, item.State, item.Step, task.Progress.GetValueOrDefault(item.Id),
            item.Photo, task.Sources.ContainsKey(item.Id), item.Failure)).ToArray(), task.Running, task.Stop);
    private PhotoUploadTask OwnedUpload(Guid id)
    {
        RequireUploadStore();
        if (!_uploads.Tasks.TryGetValue(id, out var task) || task.Record.ProfileId != ProfileId || task.Record.Owner != UploadOwner())
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return task;
    }
    public async Task<IReadOnlyList<SynologyPhotoUploadBatch>> UploadsAsync(CancellationToken cancellationToken = default)
    {
        if (!SupportsUploads) return [];
        var owner = UploadOwner(); await LoadUploadsAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (UploadOwner() != owner) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _uploads.Tasks.Values.Where(task => task.Record.Owner == owner).Select(UploadSnapshot).ToArray();
    }

    public async Task<SynologyPhotoUploadBatch> QueueUploadAsync(Guid operationId, SynologyPhotoUploadTarget target,
        IReadOnlyList<SynologyPhotoUploadSource> sources, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty || sources.Count is < 1 or > 10000) throw Invalid();
        ValidateUploadTarget(target); var owner = UploadOwner();
        await LoadUploadsAsync().ConfigureAwait(false);
        if (_uploads.Tasks.TryGetValue(operationId, out _)) return ExistingUpload();
        SynologyPhotoUploadBatch ExistingUpload()
        {
            var existing = OwnedUpload(operationId);
            if (existing.Record.Target != target) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            return UploadSnapshot(existing);
        }
        var items = new List<PhotoUploadEntry>(); var paths = new Dictionary<Guid, string>();
        foreach (var source in sources)
        {
            if (target.DirectToAlbum && source.Directories.Count > 0) throw Invalid();
            var file = await ReadUploadSourceAsync(source, cancellationToken).ConfigureAwait(false);
            var id = Guid.NewGuid(); items.Add(new(id, file)); paths.Add(id, Path.GetFullPath(source.Path));
        }
        if (items.DistinctBy(item => (item.File.Sha256, string.Join('/', item.File.Directories), item.File.Name)).Count() != items.Count) throw Invalid();
        var (root, album) = await PrepareUploadTargetAsync(target, cancellationToken).ConfigureAwait(false);
        if (UploadOwner() != owner) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        await _uploads.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            RequireUploadStore();
            if (_uploads.Tasks.TryGetValue(operationId, out _)) return ExistingUpload();
            // 未结束内容按摘要防重；改名称、目录或来源不能绕过未知上传。
            if (_uploads.Tasks.Values.Where(task => task.Record.Owner == owner).SelectMany(task => task.Record.Items)
                .Any(existing => existing.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled) &&
                    items.Any(item => item.File.Sha256 == existing.File.Sha256 && item.File.Length == existing.File.Length)))
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var task = new PhotoUploadTask(new(1, operationId, ProfileId, owner, target, root, album, items.ToArray(), []));
            foreach (var (id, path) in paths) task.Sources.TryAdd(id, path);
            await SaveUploadAsync(task).ConfigureAwait(false);
            _uploads.Tasks.TryAdd(operationId, task);
            return UploadSnapshot(task);
        }
        finally { _uploads.Gate.Release(); }
    }
    private static async Task<SynologyPhotoUploadFile> ReadUploadSourceAsync(SynologyPhotoUploadSource source, CancellationToken token)
    {
        if (source.Directories.Count > 128 || source.Directories.Any(name => !ValidUploadName(name))) throw Invalid();
        var info = new FileInfo(source.Path);
        if (!info.Exists || !ValidUploadName(info.Name) || info.Length <= 0 ||
            (info.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await using var stream = OpenUploadFile(info.FullName);
        var length = stream.Length; var modified = new DateTimeOffset(info.LastWriteTimeUtc);
        var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, token).ConfigureAwait(false));
        info.Refresh();
        if (info.Length != length || new DateTimeOffset(info.LastWriteTimeUtc) != modified) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return new(info.Name, length, modified, hash, source.Directories.ToArray());
    }
    private static FileStream OpenUploadFile(string path) => new(path, FileMode.Open, FileAccess.Read, FileShare.Read,
        64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
}
