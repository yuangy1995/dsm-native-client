using System.Collections.Concurrent;
using System.Threading.Channels;
using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 映射内已登记文件的自动保存；事件合并后串行处理，提交未知只核查，不重新上传。
internal sealed class CloudDriveWritebackSession : IAsyncDisposable
{
    private readonly DesktopDriveMapping _mapping;
    private readonly string _root;
    private readonly DesktopCloudDriveSyncStore _store;
    private readonly CloudDriveWritebackCoordinator _coordinator;
    private readonly Func<string, string?> _remotePath;
    private readonly Func<string, string> _identity;
    private readonly Func<string, CancellationToken, Task<string?>>? _registerNewPath;
    private readonly Func<string, string, CancellationToken, Task>? _renamedLocalPath;
    private readonly Func<string, CancellationToken, Task<string?>>? _resolveExistingPath;
    private readonly Func<string, CancellationToken, Task>? _deletedLocalPath;
    private readonly Func<string, long, bool, CancellationToken, Task>? _cacheChanged;
    private readonly ConcurrentQueue<string> _deletes = new();
    private readonly ConcurrentQueue<(string Source, string Target)> _renames = new();
    private readonly Queue<(string Source, string Target)> _retryRenames = new();
    private readonly ConcurrentDictionary<string, byte> _failedRenameTargets = new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<string, string, bool> _isModified;
    private readonly Func<string, CloudDrivePendingChange, bool> _acknowledge;
    private readonly Action<Exception?> _stateChanged;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _processing = new(1, 1);
    private readonly ConcurrentDictionary<string, byte> _pending = new(StringComparer.OrdinalIgnoreCase);
    private readonly Channel<bool> _signals = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
        { SingleReader = true, FullMode = BoundedChannelFullMode.DropWrite });
    private FileSystemWatcher? _watcher;
    private Task? _consumer;
    private Func<IEnumerable<string>> _knownLocalPaths = () => [];
    private int _rescanRequested;
    private readonly ConcurrentDictionary<string, byte> _scanDirectories = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<Guid> _scannedDirectoryOperations = [];

    internal CloudDriveWritebackSession(DesktopDriveMapping mapping, string root, IDsmRepository repository,
        DesktopCloudDriveSyncStore store, Func<string, string?> remotePath, Action<Exception?> stateChanged,
        Func<string, string, bool>? isModified = null, Func<string, CloudDrivePendingChange, bool>? acknowledge = null,
        Func<string, CancellationToken, Task<string?>>? registerNewPath = null, Func<string, string>? itemIdentity = null,
        Func<string, string, CancellationToken, Task>? renamedLocalPath = null,
        Func<string, CancellationToken, Task<string?>>? resolveExistingPath = null,
        Func<string, CancellationToken, Task>? deletedLocalPath = null,
        Func<string, long, bool, CancellationToken, Task>? cacheChanged = null)
    {
        _mapping = mapping; _root = Path.GetFullPath(root); _store = store;
        _coordinator = new(mapping, repository, store); _remotePath = remotePath; _stateChanged = stateChanged;
        _registerNewPath = registerNewPath;
        _renamedLocalPath = renamedLocalPath; _resolveExistingPath = resolveExistingPath;
        _deletedLocalPath = deletedLocalPath;
        _cacheChanged = cacheChanged;
        _identity = itemIdentity ?? (path => DesktopDriveItemIdentity.Identifier(mapping.Id, path)!);
        _isModified = isModified ?? CloudFilePlaceholderNative.IsModified;
        _acknowledge = acknowledge ?? ((path, change) => change.Kind == CloudDriveChangeKind.CreateDirectory
            ? CloudFilePlaceholderNative.AcknowledgeCreatedDirectory(path, _identity(change.RemotePath))
            : CloudFilePlaceholderNative.AcknowledgeSavedContent(path,
                _identity(change.RemotePath), change.ContentLength, change.ContentHash));
    }

    internal void Start(Func<IEnumerable<string>> knownLocalPaths)
    {
        if (_consumer is not null) throw new InvalidOperationException("cloud.writeback.already_started");
        _lifetime.Token.ThrowIfCancellationRequested();
        _knownLocalPaths = knownLocalPaths;
        _watcher = new(_root)
        {
            IncludeSubdirectories = true,
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.DirectoryName,
        };
        _watcher.Changed += Changed;
        _watcher.Created += Changed;
        _watcher.Renamed += Renamed;
        _watcher.Deleted += Deleted;
        _watcher.Error += WatcherError;
        _consumer = ConsumeAsync();
        _watcher.EnableRaisingEvents = true;
        // 重启时处理已有修改和未决记录，不要求编辑器再次产生通知。
        foreach (var path in knownLocalPaths()) NotifyChanged(path);
        if (_registerNewPath is not null) RequestScan();
    }

    private void Changed(object sender, FileSystemEventArgs e) => NotifyChanged(e.FullPath);
    private void Renamed(object sender, RenamedEventArgs e) => NotifyRenamed(e.OldFullPath, e.FullPath);
    private void Deleted(object sender, FileSystemEventArgs e) => NotifyDeleted(e.FullPath);
    internal void NotifyDeleted(string path)
    {
        if (_lifetime.IsCancellationRequested || _deletedLocalPath is null) return;
        var full = Path.GetFullPath(path);
        if (!full.StartsWith(_root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return;
        _deletes.Enqueue(full); _signals.Writer.TryWrite(true);
    }
    internal void NotifyRenamed(string source, string target)
    {
        if (_lifetime.IsCancellationRequested) return;
        if (_renamedLocalPath is not null) _renames.Enqueue((Path.GetFullPath(source), Path.GetFullPath(target)));
        NotifyChanged(target);
        _signals.Writer.TryWrite(true);
    }
    private void WatcherError(object sender, ErrorEventArgs e)
    {
        _stateChanged(e.GetException());
        // 缓冲区溢出会丢事件，重新核查登记清单，不能把“没有通知”当成没有修改。
        foreach (var path in _knownLocalPaths()) NotifyChanged(path);
        if (_registerNewPath is not null) RequestScan();
    }

    internal void RequestScan(string? directory = null)
    {
        if (directory is null) Interlocked.Exchange(ref _rescanRequested, 1); else _scanDirectories[directory] = 0;
        _signals.Writer.TryWrite(true);
    }

    private IEnumerable<string> ScanLocalCandidates(IEnumerable<string> roots)
    {
        // 只扫描已登记目录的一层，以及普通本地新目录；不递归打开尚未浏览的云端目录树。
        var pending = new Stack<string>(roots);
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (pending.TryPop(out var directory))
        {
            _lifetime.Token.ThrowIfCancellationRequested();
            if (!visited.Add(directory)) continue;
            string[] entries;
            try
            {
                if (!string.Equals(directory, _root, StringComparison.OrdinalIgnoreCase) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                {
                    var remote = _remotePath(directory) ?? throw new InvalidDataException("cloud.sync.unindexed_placeholder");
                    using var handle = CloudFilesInterop.CreateFile(directory, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
                        CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
                    if (handle.IsInvalid) throw new IOException("cloud.sync.local_parent_unavailable");
                    _ = CloudFilePlaceholderNative.Read(handle, _identity(remote));
                }
                entries = Directory.GetFileSystemEntries(directory);
            }
            catch (Exception error) { _stateChanged(error); continue; }
            foreach (var entry in entries)
            {
                yield return entry;
                try { if (Directory.Exists(entry) && (File.GetAttributes(entry) & FileAttributes.ReparsePoint) == 0) pending.Push(entry); }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                catch (Exception error) { _stateChanged(error); }
            }
        }
    }

    internal void NotifyChanged(string localPath)
    {
        if (_lifetime.IsCancellationRequested) return;
        var path = Path.GetFullPath(localPath);
        if (!path.StartsWith(_root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
            _remotePath(path) is null && _registerNewPath is null) return;
        _pending[path] = 0;
        _signals.Writer.TryWrite(true);
    }

    private void WakeChildren(string directory)
    {
        foreach (var child in _knownLocalPaths().Where(path => string.Equals(Path.GetDirectoryName(path), directory, StringComparison.OrdinalIgnoreCase)))
            NotifyChanged(child);
    }

    private async Task ConsumeAsync()
    {
        try
        {
            while (await _signals.Reader.WaitToReadAsync(_lifetime.Token).ConfigureAwait(false))
            {
                while (_signals.Reader.TryRead(out _)) { }
                await Task.Delay(250, _lifetime.Token).ConfigureAwait(false);
                var renames = new List<(string Source, string Target)>();
                while (_retryRenames.TryDequeue(out var retry)) renames.Add(retry);
                while (_renames.TryDequeue(out var incoming))
                {
                    var previous = renames.FindLastIndex(item => string.Equals(item.Target, incoming.Source, StringComparison.OrdinalIgnoreCase));
                    if (previous >= 0) renames[previous] = (renames[previous].Source, incoming.Target); else renames.Add(incoming);
                }
                foreach (var rename in renames)
                {
                    try
                    {
                        await _renamedLocalPath!(rename.Source, rename.Target, _lifetime.Token).ConfigureAwait(false);
                        _failedRenameTargets.TryRemove(rename.Target, out _);
                    }
                    catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { return; }
                    catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33)
                    {
                        _retryRenames.Enqueue(rename); _signals.Writer.TryWrite(true);
                    }
                    catch (Exception error) { _failedRenameTargets[rename.Target] = 0; _stateChanged(error); }
                }
                // 尚未绑定身份的改名目标不能先被扫描/上传为新文件。
                if (!_renames.IsEmpty || _retryRenames.Count != 0) continue;
                if (Interlocked.Exchange(ref _rescanRequested, 0) != 0)
                    foreach (var path in ScanLocalCandidates(_knownLocalPaths().Where(Directory.Exists).Prepend(_root).ToArray())) NotifyChanged(path);
                foreach (var directory in _scanDirectories.Keys)
                    if (_scanDirectories.TryRemove(directory, out _))
                        foreach (var path in ScanLocalCandidates([directory])) NotifyChanged(path);
                foreach (var path in _pending.Keys.OrderBy(path => path.Count(character => character == Path.DirectorySeparatorChar)))
                {
                    if (!_pending.TryRemove(path, out _)) continue;
                    try
                    {
                        if (await ProcessPathAsync(path, _lifetime.Token).ConfigureAwait(false)) NotifyChanged(path);
                    }
                    catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { return; }
                    catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33)
                    {
                        // 文件仍被编辑器写入时等待关闭，不捕获半份内容；其他失败留给恢复入口。
                        NotifyChanged(path);
                    }
                    catch (Exception error) { _stateChanged(error); }
                }
                while (_deletes.TryDequeue(out var deleted))
                {
                    // 编辑器替换保存和同一批移动不是用户删除；先处理改名/保存，再记录确实消失的项目。
                    if (File.Exists(deleted) || Directory.Exists(deleted) || renames.Any(item =>
                        string.Equals(item.Source, deleted, StringComparison.OrdinalIgnoreCase))) continue;
                    try { await _deletedLocalPath!(deleted, _lifetime.Token).ConfigureAwait(false); }
                    catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { return; }
                    catch (Exception error) { _stateChanged(error); }
                }
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
    }

    // 返回 true 表示核查上传期间又有编辑，需继续处理新副本。
    internal async Task<bool> ProcessPathAsync(string localPath, CancellationToken token = default)
    {
        await _processing.WaitAsync(token).ConfigureAwait(false);
        try
        {
            return await ProcessCoreAsync(Path.GetFullPath(localPath), token).ConfigureAwait(false);
        }
        finally { _processing.Release(); }
    }

    private async Task<bool> ProcessCoreAsync(string physical, CancellationToken token)
    {
            if (!physical.StartsWith(_root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
                _failedRenameTargets.ContainsKey(physical) || !(File.Exists(physical) || Directory.Exists(physical)) ||
                !await _store.IsWritebackEnabledAsync(_mapping, token).ConfigureAwait(false)) return false;
            var remote = _resolveExistingPath is null ? _remotePath(physical) : await _resolveExistingPath(physical, token).ConfigureAwait(false);
            if (remote is null && _registerNewPath is not null) remote = await _registerNewPath(physical, token).ConfigureAwait(false);
            if (remote is null) return false;
            var directory = Directory.Exists(physical);
            var creations = await _store.ReadLocalCreationsAsync(_mapping, token).ConfigureAwait(false);
            var parent = Path.GetDirectoryName(physical)!;
            var parentRemote = _remotePath(parent);
            var records = await _store.ReadChangesAsync(_mapping, token).ConfigureAwait(false);
            var change = records.SingleOrDefault(item => item.RemotePath == remote && item.IsPending);
            if (change is null)
            {
                var previous = records.LastOrDefault(item => item.RemotePath == remote);
                if (previous?.Phase == CloudDriveChangePhase.KeptLocally) return false;
                if (creations.ContainsKey(remote)) change = await _store.PrepareLocalCreationAsync(_mapping, remote, physical, _root, token).ConfigureAwait(false);
                else
                {
                    if (directory)
                    {
                        if (previous?.Kind == CloudDriveChangeKind.CreateDirectory && previous.Phase == CloudDriveChangePhase.Verified)
                        {
                            if (await _store.TryAcknowledgeSavedAsync(_mapping, previous, () => _acknowledge(physical, previous), token).ConfigureAwait(false))
                            {
                                WakeChildren(physical);
                                if (_scannedDirectoryOperations.Add(previous.Id)) RequestScan(physical);
                            }
                        }
                        return false;
                    }
                    if (!_isModified(physical, _identity(remote)))
                    {
                        if (previous is { Phase: CloudDriveChangePhase.Verified, ContentReleased: false })
                            await _store.TryAcknowledgeSavedAsync(_mapping, previous, () => _acknowledge(physical, previous), token).ConfigureAwait(false);
                        if (_cacheChanged is not null) await _cacheChanged(remote, new FileInfo(physical).Length, false, token).ConfigureAwait(false);
                        return false;
                    }
                    if (previous?.Phase == CloudDriveChangePhase.Verified && await _store.TryAcknowledgeSavedAsync(_mapping,
                        previous, () => _acknowledge(physical, previous), token).ConfigureAwait(false))
                    {
                        if (_cacheChanged is not null) await _cacheChanged(remote, previous.ContentLength, true, token).ConfigureAwait(false);
                        return false;
                    }
                    change = await _store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(), remote, physical, _root, token).ConfigureAwait(false);
                }
            }
            if (directory != (change.Kind == CloudDriveChangeKind.CreateDirectory)) throw new InvalidDataException("cloud.sync.local_type_conflict");
            if (change.Phase is CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected) return false;
            if (parentRemote is not null && (creations.ContainsKey(parentRemote) || records.Any(item =>
                item.RemotePath == parentRemote && item.Kind == CloudDriveChangeKind.CreateDirectory && item.IsPending)))
            {
                await ProcessCoreAsync(parent, token).ConfigureAwait(false);
                if ((await _store.ReadLocalCreationsAsync(_mapping, token).ConfigureAwait(false)).ContainsKey(parentRemote))
                    throw new InvalidOperationException("cloud.sync.parent_pending");
            }
            var result = await _coordinator.SubmitAsync(change.Id, token).ConfigureAwait(false);
            _stateChanged(null);
            if (result.Phase != CloudDriveChangePhase.Verified) return false;
            var acknowledged = await _store.TryAcknowledgeSavedAsync(_mapping, result,
                () => _acknowledge(physical, result), token).ConfigureAwait(false);
            if (acknowledged && directory)
            {
                WakeChildren(physical);
                if (_scannedDirectoryOperations.Add(result.Id)) RequestScan(physical);
            }
            if (acknowledged && !directory && _cacheChanged is not null)
                await _cacheChanged(remote, result.ContentLength, true, token).ConfigureAwait(false);
            return !acknowledged;
    }

    public async ValueTask DisposeAsync()
    {
        _watcher?.Dispose(); _watcher = null;
        await _lifetime.CancelAsync().ConfigureAwait(false);
        _signals.Writer.TryComplete();
        if (_consumer is not null) await _consumer.ConfigureAwait(false);
        // 不删除不可变副本，也不清除 Submitted；下次连接只能按日志恢复。
        _pending.Clear();
    }
}
