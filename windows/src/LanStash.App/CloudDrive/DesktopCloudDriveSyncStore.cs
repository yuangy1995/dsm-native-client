using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed record CloudDriveContentVersion(string RemotePath, string Version, long Length);
internal enum CloudDriveChangePhase { Prepared, Submitted, Conflict, Verified, KeptLocally, Rejected }
internal enum CloudDriveChangeKind { SaveFile, CreateDirectory }
internal sealed record CloudDrivePathRelocation(Guid Id, string Source, string Destination, string LocalName);
internal sealed record CloudDrivePendingChange(Guid Id, string RemotePath, string? BaseVersion,
    string ContentHash, long ContentLength, CloudDriveChangePhase Phase, DateTimeOffset CreatedAt, DateTimeOffset? EmptyBaseModifiedAt = null,
    CloudDriveContentVersion? SavedVersion = null, DateTimeOffset? SavedEmptyModifiedAt = null,
    CloudDriveChangeKind Kind = CloudDriveChangeKind.SaveFile, bool ContentReleased = false)
{
    internal bool IsPending => Phase is not (CloudDriveChangePhase.Verified or CloudDriveChangePhase.KeptLocally);
    internal bool WasExisting => BaseVersion is not null || EmptyBaseModifiedAt is not null;
}

/// 独立于旧映射配置与可回收缓存；回退版本不能重写、回收尚未同步的内容。
internal sealed partial class DesktopCloudDriveSyncStore(string? directory = null,
    Func<DesktopDriveMapping, string, string>? identityResolver = null)
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> LocalGates = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _root = Path.GetFullPath(directory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "desktop-drive-sync-v1"));
    private sealed record Snapshot(int Version, Guid MappingId, Guid ProfileId, DesktopDriveScope Scope,
        bool WritebackEnabled, List<CloudDriveContentVersion> Versions, List<CloudDrivePendingChange> Changes,
        Dictionary<string, string>? LocalNames = null, Dictionary<string, DateTimeOffset>? EmptyFileBaselines = null,
        Dictionary<string, bool>? LocalCreations = null, List<CloudDrivePathRelocation>? Relocations = null,
        List<CloudDriveRelocationOperation>? NamespaceOperations = null,
        bool DeletionEnabled = false, List<CloudDriveDeletionOperation>? Deletions = null);

    internal async Task<IReadOnlyDictionary<string, string>> RegisterLocalNamesAsync(DesktopDriveMapping mapping,
        IReadOnlyDictionary<string, string> legacyNames, IEnumerable<string> paths, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var names = state.LocalNames is null ? new Dictionary<string, string>(StringComparer.Ordinal) :
            new Dictionary<string, string>(state.LocalNames, StringComparer.Ordinal);
        if (state.LocalNames is null)
            foreach (var pair in legacyNames.Where(pair => !IsMappingRoot(mapping, pair.Key)))
                names.Add(pair.Key, pair.Value.Length > 255 ? ShortLocalName(pair.Value, pair.Key) : pair.Value);
        ValidateNames(mapping, names);
        var occupiedParents = names.GroupBy(pair => Parent(pair.Key), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Select(pair => pair.Value).ToHashSet(StringComparer.OrdinalIgnoreCase), StringComparer.Ordinal);
        foreach (var path in paths.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
        {
            token.ThrowIfCancellationRequested();
            if (IsMappingRoot(mapping, path)) continue;
            RequirePath(mapping, path);
            CheckDeletionBlock(state, path);
            if (names.ContainsKey(path)) continue;
            var stem = ShortLocalName(DesktopDriveWindowsNameCodec.EscapeSegment(path[(path.LastIndexOf('/') + 1)..]), path);
            if (!occupiedParents.TryGetValue(Parent(path), out var occupied)) occupiedParents.Add(Parent(path), occupied = new(StringComparer.OrdinalIgnoreCase));
            var candidate = stem;
            if (occupied.Contains(candidate))
            {
                var digest = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(path))).ToLowerInvariant()[..16];
                candidate = stem + "~" + digest;
                for (var suffix = 1; occupied.Contains(candidate); suffix++) candidate = stem + "~" + digest + "-" + suffix;
            }
            names.Add(path, candidate);
            occupied.Add(candidate);
        }
        ValidateNames(mapping, names);
        if (state.LocalNames is null && names.Count == 0) return names;
        if (state.LocalNames is null || names.Count != state.LocalNames.Count)
            await WriteAsync(mapping, state with { Version = Math.Max(2, state.Version), LocalNames = names }, token);
        return names;
    }

    private static bool IsMappingRoot(DesktopDriveMapping mapping, string path) => path == "/" ||
        mapping.Scope.Kind == DesktopDriveScopeKind.Folder && path == DesktopDrivePath.Normalize(mapping.Scope.FolderPath);
    private static string Parent(string path) => path[..Math.Max(1, path.LastIndexOf('/'))];
    private static string ShortLocalName(string value, string path)
    {
        if (value.Length <= 220) return value;
        var count = char.IsHighSurrogate(value[179]) ? 179 : 180;
        var extension = System.IO.Path.GetExtension(value);
        if (extension.Length > 24) extension = "";
        var digest = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(path))).ToLowerInvariant()[..16];
        return value[..count] + "~" + digest + extension;
    }
    private static void ValidateNames(DesktopDriveMapping mapping, IReadOnlyDictionary<string, string> names)
    {
        var occupied = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        foreach (var pair in names)
        {
            RequirePath(mapping, pair.Key);
            if (string.IsNullOrWhiteSpace(pair.Value) || pair.Value.Length > 255 || pair.Value is "." or ".." || pair.Value.EndsWith('.') ||
                pair.Value.EndsWith(' ') || pair.Value.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0 ||
                DesktopDriveWindowsNameCodec.EscapeSegment(pair.Value).StartsWith("%00", StringComparison.Ordinal))
                throw new InvalidDataException("cloud.sync.invalid_local_name");
            if (!occupied.TryGetValue(Parent(pair.Key), out var siblings)) occupied.Add(Parent(pair.Key), siblings = new(StringComparer.OrdinalIgnoreCase));
            if (!siblings.Add(pair.Value)) throw new InvalidDataException("cloud.sync.local_name_conflict");
        }
    }

    internal async Task<bool> IsWritebackEnabledAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token)).WritebackEnabled;
    }

    internal async Task SetWritebackEnabledAsync(DesktopDriveMapping mapping, bool enabled, bool confirmed,
        CancellationToken token = default)
    {
        if (!confirmed || enabled && !CloudDriveWriteScope.CanEnable(mapping))
            throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        if (enabled && mapping.Scope.Kind == DesktopDriveScopeKind.AllShares) state = WithDeletions(state) with { Version = 10 };
        if (!enabled && (state.Changes.Any(change => change.IsPending) || state.NamespaceOperations?.Any(operation => operation.IsPending) == true ||
            state.Deletions?.Any(operation => operation.IsPending) == true))
            throw new InvalidOperationException("cloud.sync.pending_changes");
        await WriteAsync(mapping, state with { WritebackEnabled = enabled, DeletionEnabled = enabled && state.DeletionEnabled }, token);
    }

    internal async Task<CloudDriveContentVersion?> ReadVersionAsync(DesktopDriveMapping mapping,
        string remotePath, CancellationToken token = default)
    {
        RequirePath(mapping, remotePath);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token)).Versions.SingleOrDefault(item => item.RemotePath == remotePath);
    }

    // 空文件没有可读取的字节范围；原始远端时间必须在允许编辑前登记，不能使用修改后的本地时间。
    internal async Task<DateTimeOffset?> ReadEmptyFileBaselineAsync(DesktopDriveMapping mapping, string path, CancellationToken token = default)
    {
        RequirePath(mapping, path);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        return state.EmptyFileBaselines?.TryGetValue(path, out var value) == true ? value : null;
    }

    internal async Task BindEmptyFileBaselineAsync(DesktopDriveMapping mapping, string remotePath,
        DateTimeOffset modifiedAt, CancellationToken token = default)
    {
        RequirePath(mapping, remotePath);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        CheckRelocationBlock(state, remotePath);
        if (state.Versions.Any(item => item.RemotePath == remotePath) ||
            state.Changes.Any(item => item.RemotePath == remotePath && item.IsPending))
            throw new InvalidDataException("cloud.sync.version_conflict");
        var baselines = state.EmptyFileBaselines ?? new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        if (baselines.TryGetValue(remotePath, out var previous))
        {
            if (previous != modifiedAt) throw new InvalidDataException("cloud.sync.version_conflict");
            return;
        }
        baselines.Add(remotePath, modifiedAt);
        await WriteAsync(mapping, state with { Version = Math.Max(4, state.Version), EmptyFileBaselines = baselines }, token).ConfigureAwait(false);
    }

    internal async Task<CloudDrivePendingChange> CaptureMappedSaveAsync(DesktopDriveMapping mapping, Guid operationId,
        string remotePath, string localPath, string localRoot, CancellationToken token = default)
    {
        RequirePath(mapping, remotePath);
        string? version;
        DateTimeOffset? emptyBaseline;
        using (var lease = await AcquireAsync(mapping, token).ConfigureAwait(false))
        {
            var state = await ReadAsync(mapping, token).ConfigureAwait(false);
            version = state.Versions.SingleOrDefault(item => item.RemotePath == remotePath)?.Version;
            emptyBaseline = state.EmptyFileBaselines?.TryGetValue(remotePath, out var time) == true ? time : null;
        }
        return await PrepareMappedSaveAsync(mapping, operationId, remotePath, localPath, localRoot,
            version, token, emptyBaseline).ConfigureAwait(false);
    }

    internal async Task<string> RegisterLocalCreationAsync(DesktopDriveMapping mapping, string localRoot, string localPath,
        IReadOnlyCollection<string> knownRemotePaths, CancellationToken token = default)
    {
        var root = Path.GetFullPath(localRoot).TrimEnd(Path.DirectorySeparatorChar);
        var physical = Path.GetFullPath(localPath);
        if (!CloudDriveWriteScope.CanEnable(mapping) || !physical.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("cloud.sync.invalid_path");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        var names = state.LocalNames is null ? new Dictionary<string, string>(StringComparer.Ordinal) : new(state.LocalNames, StringComparer.Ordinal);
        var creations = state.LocalCreations is null ? new Dictionary<string, bool>(StringComparer.Ordinal) : new(state.LocalCreations, StringComparer.Ordinal);
        var remote = CloudDriveWriteScope.Root(mapping);
        var cursor = root;
        var components = physical[(root.Length + 1)..].Split(Path.DirectorySeparatorChar);
        for (var index = 0; index < components.Length; index++)
        {
            var name = components[index];
            var existing = names.SingleOrDefault(pair => Parent(pair.Key) == remote && string.Equals(pair.Value, name, StringComparison.OrdinalIgnoreCase));
            var target = existing.Key ?? remote.TrimEnd('/') + "/" + name;
            RequirePath(mapping, target);
            CheckRelocationBlock(state, target);
            if (target.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("cloud.sync.protected_path");
            cursor = Path.Combine(cursor, name);
            var attributes = File.GetAttributes(cursor);
            var directory = (attributes & FileAttributes.Directory) != 0;
            if (index < components.Length - 1 && !directory) throw new InvalidDataException("cloud.sync.invalid_parent");
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                // 仅接受已登记的父目录；未知占位或链接不能伪装成本地新建项。
                if (index == components.Length - 1 || !knownRemotePaths.Contains(target)) throw new InvalidDataException("cloud.sync.unindexed_placeholder");
                using var handle = CloudFilesInterop.CreateFile(cursor, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
                    CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
                if (handle.IsInvalid) throw new IOException("cloud.sync.local_parent_unavailable");
                _ = CloudFilePlaceholderNative.Read(handle, Identity(mapping, target));
            }
            if (existing.Key is null)
            {
                if (names.ContainsKey(target)) throw new InvalidDataException("cloud.sync.local_name_conflict");
                names.Add(target, name);
            }
            if (!knownRemotePaths.Contains(target))
            {
                CloudDriveWriteScope.RequireWritable(mapping, target);
                if (state.Versions.Any(item => item.RemotePath == target) || state.EmptyFileBaselines?.ContainsKey(target) == true)
                    throw new InvalidDataException("cloud.sync.version_conflict");
                if (creations.TryGetValue(target, out var previousKind) && previousKind != directory)
                    throw new InvalidDataException("cloud.sync.local_type_conflict");
                creations[target] = directory;
            }
            remote = target;
        }
        ValidateNames(mapping, names);
        await WriteAsync(mapping, state with { Version = Math.Max(5, state.Version), LocalNames = names, LocalCreations = creations,
            EmptyFileBaselines = state.EmptyFileBaselines ?? new(StringComparer.Ordinal) }, token).ConfigureAwait(false);
        return remote;
    }

    internal async Task<IReadOnlyDictionary<string, bool>> ReadLocalCreationsAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return new Dictionary<string, bool>((await ReadAsync(mapping, token).ConfigureAwait(false)).LocalCreations ?? [], StringComparer.Ordinal);
    }

    internal async Task<CloudDrivePendingChange> PrepareLocalCreationAsync(DesktopDriveMapping mapping, string remotePath,
        string localPath, string localRoot, CancellationToken token = default)
    {
        bool directory;
        using (var lease = await AcquireAsync(mapping, token).ConfigureAwait(false))
        {
            var state = await ReadAsync(mapping, token).ConfigureAwait(false);
            if (state.LocalCreations?.TryGetValue(remotePath, out directory) != true) throw new InvalidDataException("cloud.sync.creation_missing");
        }
        localPath = await ResolveMappedLocalPathAsync(mapping, remotePath, localPath, localRoot, token).ConfigureAwait(false);
        RejectReparsePoint(localPath);
        if (Directory.Exists(localPath) != directory) throw new InvalidDataException("cloud.sync.local_type_conflict");
        return await PrepareSaveCoreAsync(mapping, Guid.NewGuid(), remotePath,
            () => directory ? Stream.Null : new FileStream(localPath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536,
                FileOptions.Asynchronous | FileOptions.SequentialScan), null, token, null,
            directory ? CloudDriveChangeKind.CreateDirectory : CloudDriveChangeKind.SaveFile).ConfigureAwait(false);
    }

    // 必须在任何字节交给系统前保存；已有版本不同不能直接覆盖，需后续显式失效/重新读取流程。
    internal async Task BindVersionAsync(DesktopDriveMapping mapping, CloudDriveContentVersion version,
        CancellationToken token = default)
    {
        RequirePath(mapping, version.RemotePath); RequireVersion(version.Version, version.Length);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var old = state.Versions.SingleOrDefault(item => item.RemotePath == version.RemotePath);
        CheckRelocationBlock(state, version.RemotePath);
        if (state.EmptyFileBaselines?.ContainsKey(version.RemotePath) == true)
            throw new InvalidDataException("cloud.sync.version_conflict");
        if (old is not null)
        {
            if (old != version) throw new InvalidDataException("cloud.sync.version_conflict");
            return;
        }
        state.Versions.Add(version);
        await WriteAsync(mapping, state, token);
    }

    internal async Task<IReadOnlyList<CloudDrivePendingChange>> ReadChangesAsync(DesktopDriveMapping mapping,
        CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token)).Changes.ToArray();
    }

    // 持有同一个版本/写回锁直到本地失效和版本发布完成；本地失败时绝不先换服务器版本。
    internal async Task RefreshVersionAsync(DesktopDriveMapping mapping, string remotePath,
        CloudDriveContentVersion? expected, CloudDriveContentVersion? replacement,
        Func<CancellationToken, Task> updateLocalPlaceholder, CancellationToken token = default)
    {
        RequirePath(mapping, remotePath);
        ArgumentNullException.ThrowIfNull(updateLocalPlaceholder);
        if (replacement is not null)
        {
            if (replacement.RemotePath != remotePath) throw new InvalidDataException("cloud.sync.invalid_path");
            RequireVersion(replacement.Version, replacement.Length);
        }
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        if (state.Versions.SingleOrDefault(item => item.RemotePath == remotePath) != expected)
            throw new InvalidDataException("cloud.sync.version_conflict");
        CheckRelocationBlock(state, remotePath);
        if (state.Changes.Any(item => item.RemotePath == remotePath && item.IsPending))
            throw new InvalidOperationException("cloud.sync.pending_changes");
        token.ThrowIfCancellationRequested();
        await updateLocalPlaceholder(token);
        // 原生缓存已失效但此后失败时旧版本仍在。下次只读核查/刷新可重试，不发送 NAS 写入。
        token.ThrowIfCancellationRequested();
        state.Versions.RemoveAll(item => item.RemotePath == remotePath);
        state.EmptyFileBaselines?.Remove(remotePath);
        if (replacement is not null) state.Versions.Add(replacement);
        await WriteAsync(mapping, state, token);
    }

    internal async Task<bool> TryRemoveLocalProjectionAsync(DesktopDriveMapping mapping, string path,
        Func<CancellationToken, Task<bool>> removeLocal, CancellationToken token = default)
    {
        RequirePath(mapping, path);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        if (state.Changes.Any(change => change.IsPending && DesktopDrivePath.IsAncestorOrSame(path, change.RemotePath))) return false;
        CheckRelocationBlock(state, path);
        token.ThrowIfCancellationRequested();
        if (!await removeLocal(token).ConfigureAwait(false)) return false;
        state.Versions.RemoveAll(version => DesktopDrivePath.IsAncestorOrSame(path, version.RemotePath));
        if (state.EmptyFileBaselines is { } emptyBaselines)
            foreach (var target in emptyBaselines.Keys.Where(target => DesktopDrivePath.IsAncestorOrSame(path, target)).ToArray())
                emptyBaselines.Remove(target);
        // 不删除待同步/保留本地内容，也不重用已经分配的名字。
        await WriteAsync(mapping, state, token).ConfigureAwait(false);
        return true;
    }

    internal Task<CloudDrivePendingChange> PrepareSaveAsync(DesktopDriveMapping mapping, Guid operationId,
        string remotePath, string sourcePath, string? baseVersion, CancellationToken token = default, DateTimeOffset? emptyBaseModifiedAt = null)
        => PrepareSaveCoreAsync(mapping, operationId, remotePath, () =>
        {
            RejectReparsePoint(sourcePath);
            return new FileStream(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        }, baseVersion, token, emptyBaseModifiedAt);

    internal async Task<CloudDrivePendingChange> PrepareMappedSaveAsync(DesktopDriveMapping mapping, Guid operationId,
        string remotePath, string localPath, string localRoot, string? baseVersion, CancellationToken token = default, DateTimeOffset? emptyBaseModifiedAt = null)
    {
        if (baseVersion is null && emptyBaseModifiedAt is null) throw new InvalidDataException("cloud.sync.baseline_missing");
        var physical = await ResolveMappedLocalPathAsync(mapping, remotePath, localPath, localRoot, token).ConfigureAwait(false);
        return await PrepareSaveCoreAsync(mapping, operationId, remotePath, () =>
        {
            if ((File.GetAttributes(physical) & FileAttributes.ReparsePoint) != 0)
                return CloudFilePlaceholderNative.OpenEditedContent(physical, Identity(mapping, remotePath));
            // 编辑器的覆盖保存可能把占位替换成普通文件；只接受已登记名称内的普通文件。
            return new FileStream(physical, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        }, baseVersion, token, emptyBaseModifiedAt).ConfigureAwait(false);
    }

    private async Task<string> ResolveMappedLocalPathAsync(DesktopDriveMapping mapping, string remotePath,
        string localPath, string localRoot, CancellationToken token)
    {
        Dictionary<string, string> names;
        using (var lease = await AcquireAsync(mapping, token).ConfigureAwait(false))
            names = (await ReadAsync(mapping, token).ConfigureAwait(false)).LocalNames
                ?? throw new InvalidDataException("cloud.sync.local_name_missing");
        RequirePath(mapping, remotePath);
        var root = Path.GetFullPath(localRoot);
        var remote = CloudDriveWriteScope.Root(mapping);
        var physical = root;
        var components = remotePath[(remote == "/" ? 1 : remote.Length + 1)..].Split('/');
        for (var index = 0; index < components.Length; index++)
        {
            remote = remote.TrimEnd('/') + "/" + components[index];
            if (!names.TryGetValue(remote, out var name)) throw new InvalidDataException("cloud.sync.local_name_missing");
            physical = Path.Combine(physical, name);
            if (index < components.Length - 1 && (File.GetAttributes(physical) & FileAttributes.ReparsePoint) != 0)
            {
                using var parent = CloudFilesInterop.CreateFile(physical, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
                    CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);
                if (parent.IsInvalid) throw new IOException("cloud.sync.local_parent_unavailable");
                _ = CloudFilePlaceholderNative.Read(parent, Identity(mapping, remote));
            }
        }
        if (!string.Equals(Path.GetFullPath(localPath), physical, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("cloud.sync.local_path_mismatch");
        return physical;
    }

    private async Task<CloudDrivePendingChange> PrepareSaveCoreAsync(DesktopDriveMapping mapping, Guid operationId,
        string remotePath, Func<Stream> openSource, string? baseVersion, CancellationToken token, DateTimeOffset? emptyBaseModifiedAt,
        CloudDriveChangeKind kind = CloudDriveChangeKind.SaveFile)
    {
        CloudDriveWriteScope.RequireWritable(mapping, remotePath);
        if (remotePath.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("cloud.sync.protected_path");
        if (operationId == Guid.Empty) throw new ArgumentException("cloud.sync.invalid_operation");
        if (baseVersion is not null) RequireVersion(baseVersion, 0);
        if (baseVersion is not null && emptyBaseModifiedAt is not null) throw new ArgumentException("cloud.sync.invalid_baseline");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        CheckRelocationBlock(state, remotePath);
        var previous = state.Changes.SingleOrDefault(item => item.Id == operationId);
        if (previous is not null)
        {
            if (previous.RemotePath != remotePath || previous.BaseVersion != baseVersion || previous.EmptyBaseModifiedAt != emptyBaseModifiedAt)
                throw new InvalidDataException("cloud.sync.operation_conflict");
            // 固定请求编号只认最初副本，不用用户后来修改的文件重建同一操作。
            await VerifyContentAsync(mapping, previous, token);
            return previous;
        }
        if (state.Changes.Any(item => item.RemotePath == remotePath && item.IsPending))
            throw new InvalidOperationException("cloud.sync.pending_changes");
        var baseline = state.Versions.SingleOrDefault(item => item.RemotePath == remotePath);
        if (baseline?.Version != baseVersion)
            throw new InvalidDataException("cloud.sync.version_conflict");
        if (state.EmptyFileBaselines?.TryGetValue(remotePath, out var originalEmptyTime) == true && originalEmptyTime != emptyBaseModifiedAt)
            throw new InvalidDataException("cloud.sync.version_conflict");
        var contentPath = ContentPath(mapping, operationId);
        if (File.Exists(contentPath)) throw new InvalidDataException("cloud.sync.unindexed_content");
        var temporary = contentPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var input = openSource())
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                65536, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await input.CopyToAsync(output, token);
                await output.FlushAsync(token); output.Flush(flushToDisk: true);
            }
            var (hash, length) = await HashAsync(temporary, token);
            var change = new CloudDrivePendingChange(operationId, remotePath, baseVersion, hash, length,
                CloudDriveChangePhase.Prepared, DateTimeOffset.UtcNow, emptyBaseModifiedAt, Kind: kind);
            token.ThrowIfCancellationRequested();
            File.Move(temporary, contentPath);
            state.Changes.Add(change);
            if (emptyBaseModifiedAt is not null) state = state with { Version = Math.Max(3, state.Version) };
            // 若此后落盘失败，保留内容副本，不把它当作可回收的下载临时文件。
            await WriteAsync(mapping, state, token);
            return change;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    // 返回 true 的唯一调用方才能发送写请求；进程崩溃或未知结果不能使 Submitted 自动回到 Prepared。
    internal async Task<bool> TryMarkSubmittedAsync(DesktopDriveMapping mapping, Guid operationId,
        CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var change = Find(state, operationId);
        if (change.Phase != CloudDriveChangePhase.Prepared) return false;
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        await VerifyContentAsync(mapping, change, token);
        Replace(state, change with { Phase = CloudDriveChangePhase.Submitted });
        await WriteAsync(mapping, state, token);
        return true;
    }

    internal async Task MarkConflictAsync(DesktopDriveMapping mapping, Guid operationId, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var change = Find(state, operationId);
        if (change.Phase is not (CloudDriveChangePhase.Prepared or CloudDriveChangePhase.Submitted or CloudDriveChangePhase.Conflict))
            throw new InvalidOperationException("cloud.sync.invalid_transition");
        Replace(state, change with { Phase = CloudDriveChangePhase.Conflict });
        await WriteAsync(mapping, state, token);
    }

    internal async Task<Stream> OpenContentAsync(DesktopDriveMapping mapping, Guid operationId, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var change = Find(await ReadAsync(mapping, token), operationId);
        if (change.ContentReleased) throw new InvalidOperationException("cloud.sync.content_released");
        var path = ContentPath(mapping, operationId); RejectReparsePoint(path);
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        try
        {
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, token).ConfigureAwait(false));
            if (hash != change.ContentHash || stream.Length != change.ContentLength) throw new InvalidDataException("cloud.sync.content_changed");
            stream.Position = 0; return stream;
        }
        catch { await stream.DisposeAsync(); throw; }
    }

    internal async Task MarkRejectedAsync(DesktopDriveMapping mapping, Guid operationId, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token); var change = Find(state, operationId);
        if (change.Phase is not (CloudDriveChangePhase.Prepared or CloudDriveChangePhase.Submitted))
            throw new InvalidOperationException("cloud.sync.invalid_transition");
        Replace(state, change with { Phase = CloudDriveChangePhase.Rejected });
        await WriteAsync(mapping, state, token);
    }

    internal async Task ConfirmSavedAsync(DesktopDriveMapping mapping, Guid operationId,
        CloudDriveContentVersion? verifiedVersion, string verifiedContentHash, CancellationToken token = default,
        DateTimeOffset? verifiedEmptyModifiedAt = null)
    {
        if (verifiedVersion is not null) RequireVersion(verifiedVersion.Version, verifiedVersion.Length);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var change = Find(state, operationId);
        if (change.Phase is not (CloudDriveChangePhase.Submitted or CloudDriveChangePhase.Conflict) ||
            change.ContentHash != verifiedContentHash ||
            (verifiedVersion is null ? change.ContentLength != 0 : change.RemotePath != verifiedVersion.RemotePath || change.ContentLength != verifiedVersion.Length))
            throw new InvalidDataException("cloud.sync.result_mismatch");
        Replace(state, change with { Phase = CloudDriveChangePhase.Verified, SavedVersion = verifiedVersion,
            SavedEmptyModifiedAt = verifiedVersion is null ? verifiedEmptyModifiedAt : null });
        state.Versions.RemoveAll(item => item.RemotePath == change.RemotePath);
        state.EmptyFileBaselines?.Remove(change.RemotePath);
        state.LocalCreations?.Remove(change.RemotePath);
        if (verifiedVersion is not null) state.Versions.Add(verifiedVersion);
        if (verifiedVersion is null && verifiedEmptyModifiedAt is { } emptyTime)
        {
            var emptyBaselines = state.EmptyFileBaselines ?? new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
            emptyBaselines[change.RemotePath] = emptyTime;
            state = state with { Version = Math.Max(4, state.Version), EmptyFileBaselines = emptyBaselines };
        }
        await WriteAsync(mapping, state, token);
    }

    internal async Task<bool> TryAcknowledgeSavedAsync(DesktopDriveMapping mapping, CloudDrivePendingChange change,
        Func<bool> acknowledgeLocal, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (Find(state, change.Id) != change || change.Phase != CloudDriveChangePhase.Verified ||
            state.Changes.Any(item => item.RemotePath == change.RemotePath && item.IsPending)) return false;
        if (change.Kind != CloudDriveChangeKind.CreateDirectory && change.SavedVersion is { } version)
        {
            if (state.Versions.SingleOrDefault(item => item.RemotePath == change.RemotePath) != version) return false;
        }
        else if (change.Kind != CloudDriveChangeKind.CreateDirectory && !(change.SavedEmptyModifiedAt is { } time &&
            state.EmptyFileBaselines?.TryGetValue(change.RemotePath, out var current) == true && current == time)) return false;
        token.ThrowIfCancellationRequested();
        if (!acknowledgeLocal()) return false;
        var index = state.Changes.FindIndex(item => item.Id == change.Id);
        var completed = state.Changes.Take(index + 1).Where(item => item.RemotePath == change.RemotePath &&
            item.Kind == change.Kind && item.Phase == CloudDriveChangePhase.Verified).ToArray();
        if (completed.Any(item => !item.ContentReleased))
        {
            foreach (var item in completed) Replace(state, item with { ContentReleased = true });
            // 先持久记录可清理状态；中断只会多留副本，不会把未同步副本当作可删除。
            await WriteAsync(mapping, WithDeletions(state) with { Version = Math.Max(9, state.Version) }, token).ConfigureAwait(false);
        }
        foreach (var item in completed) RemoveReleasedContent(mapping, item.Id);
        return true;
    }

    internal async Task CleanReleasedContentAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        foreach (var change in state.Changes.Where(item => item.ContentReleased))
        { token.ThrowIfCancellationRequested(); RemoveReleasedContent(mapping, change.Id); }
    }

    private void RemoveReleasedContent(DesktopDriveMapping mapping, Guid id)
    {
        var path = ContentPath(mapping, id); RejectReparsePoint(path); File.Delete(path);
    }

    internal async Task KeepLocallyAsync(DesktopDriveMapping mapping, Guid operationId, bool confirmed,
        CancellationToken token = default)
    {
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token);
        var change = Find(state, operationId);
        // 已提交而未核实的请求不能伪装为放弃成功；仍须先核查远端结果。
        if (change.Phase is not (CloudDriveChangePhase.Prepared or CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected or CloudDriveChangePhase.KeptLocally))
            throw new InvalidOperationException("cloud.sync.result_unknown");
        await VerifyContentAsync(mapping, change, token);
        Replace(state, change with { Phase = CloudDriveChangePhase.KeptLocally });
        await WriteAsync(mapping, state, token);
    }

    internal async Task<CloudDrivePendingChange> PrepareRetryAsync(DesktopDriveMapping mapping, CloudDrivePendingChange expected,
        CloudDriveContentVersion? baseline, DateTimeOffset? emptyModifiedAt, bool confirmed, CancellationToken token = default)
    {
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        var previous = Find(state, expected.Id);
        if (!state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        CheckRelocationBlock(state, previous.RemotePath);
        if (previous != expected || previous.Phase is not (CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected or CloudDriveChangePhase.KeptLocally))
            throw new InvalidOperationException("cloud.sync.invalid_transition");
        if (state.Changes.Any(item => item.RemotePath == previous.RemotePath && item.Id != previous.Id && item.IsPending))
            throw new InvalidOperationException("cloud.sync.pending_changes");
        if (baseline is not null)
        {
            RequireVersion(baseline.Version, baseline.Length);
            if (baseline.RemotePath != previous.RemotePath || emptyModifiedAt is not null) throw new InvalidDataException("cloud.sync.invalid_baseline");
        }
        await VerifyContentAsync(mapping, previous, token).ConfigureAwait(false);
        var next = previous with { Id = Guid.NewGuid(), BaseVersion = baseline?.Version, EmptyBaseModifiedAt = emptyModifiedAt,
            Phase = CloudDriveChangePhase.Prepared, CreatedAt = DateTimeOffset.UtcNow, SavedVersion = null, SavedEmptyModifiedAt = null, ContentReleased = false };
        // 两份不可变内容分别保留；日志写入失败也不能删除旧副本或重放旧请求。
        var destination = ContentPath(mapping, next.Id); var temporary = destination + ".tmp"; var moved = false; var published = false;
        try
        {
            await using (var input = new FileStream(ContentPath(mapping, previous.Id), FileMode.Open, FileAccess.Read, FileShare.Read))
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                65536, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await input.CopyToAsync(output, token).ConfigureAwait(false);
                await output.FlushAsync(token).ConfigureAwait(false); output.Flush(true);
            }
            var copied = await HashAsync(temporary, token).ConfigureAwait(false);
            if (copied.Hash != next.ContentHash || copied.Length != next.ContentLength) throw new InvalidDataException("cloud.sync.content_changed");
            File.Move(temporary, destination); moved = true;
            Replace(state, previous with { Phase = CloudDriveChangePhase.KeptLocally });
            state.Changes.Add(next);
            state.Versions.RemoveAll(item => item.RemotePath == next.RemotePath);
            state.EmptyFileBaselines?.Remove(next.RemotePath);
            if (baseline is not null) state.Versions.Add(baseline);
            if (emptyModifiedAt is { } time)
            {
                var empty = state.EmptyFileBaselines ?? new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
                empty[next.RemotePath] = time;
                state = state with { Version = Math.Max(4, state.Version), EmptyFileBaselines = empty };
            }
            await WriteAsync(mapping, state, token).ConfigureAwait(false);
            published = true;
            return next;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            if (!published && moved && File.Exists(destination)) File.Delete(destination);
        }
    }

    internal async Task ExportContentAsync(DesktopDriveMapping mapping, Guid operationId, string destination, bool confirmed,
        CancellationToken token = default)
    {
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        var target = Path.GetFullPath(destination);
        if ((await ReadChangesAsync(mapping, token).ConfigureAwait(false)).Single(item => item.Id == operationId).Kind != CloudDriveChangeKind.SaveFile)
            throw new InvalidOperationException("cloud.sync.directory_has_no_file_copy");
        if (target.StartsWith(_root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("cloud.sync.protected_destination");
        RejectReparsePoint(target);
        await using var source = await OpenContentAsync(mapping, operationId, token).ConfigureAwait(false);
        var temporary = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                65536, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await source.CopyToAsync(output, token).ConfigureAwait(false);
                await output.FlushAsync(token).ConfigureAwait(false); output.Flush(true);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, target, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    internal async Task RelocatePathsAsync(DesktopDriveMapping mapping, CloudDrivePathRelocation relocation, CancellationToken token = default,
        IReadOnlyCollection<string>? activePaths = null)
    {
        CloudDriveWriteScope.RequireWritable(mapping, relocation.Source); CloudDriveWriteScope.RequireWritable(mapping, relocation.Destination);
        if (relocation.Id == Guid.Empty || DesktopDrivePath.IsAncestorOrSame(relocation.Source, relocation.Destination) ||
            new[] { relocation.Source, relocation.Destination }.Any(path => path.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase))))
            throw new InvalidDataException("cloud.relocate.invalid_path");
        using var upload = await AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        var receipts = state.Relocations ?? [];
        if (receipts.SingleOrDefault(item => item.Id == relocation.Id) is { } applied)
        {
            if (applied != relocation) throw new InvalidDataException("cloud.relocate.operation_conflict");
            return;
        }
        if (state.LocalNames is null || !state.LocalNames.ContainsKey(relocation.Source)) throw new InvalidDataException("cloud.relocate.source_missing");
        bool Affected(string path) => DesktopDrivePath.IsAncestorOrSame(relocation.Source, path);
        if (state.Changes.Any(change => Affected(change.RemotePath) && change.Phase == CloudDriveChangePhase.Submitted))
            throw new InvalidOperationException("cloud.sync.result_unknown");
        bool AtDestination(string path) => DesktopDrivePath.IsAncestorOrSame(relocation.Destination, path);
        // 别名可以晚于投影清理保留。只有当前目录索引和同步状态均无占用时才回收旧名称；内容快照不删除。
        if (activePaths?.Any(AtDestination) == true || state.Versions.Any(item => AtDestination(item.RemotePath)) ||
            state.EmptyFileBaselines?.Keys.Any(AtDestination) == true || state.LocalCreations?.Keys.Any(AtDestination) == true ||
            state.Changes.Any(item => AtDestination(item.RemotePath) && item.Phase != CloudDriveChangePhase.Verified) ||
            activePaths is null && state.LocalNames.Keys.Any(AtDestination))
            throw new InvalidDataException("cloud.relocate.destination_exists");
        string Move(string path) => Affected(path) ? relocation.Destination + path[relocation.Source.Length..] : path;
        var names = state.LocalNames.Where(item => !AtDestination(item.Key)).ToDictionary(item => Move(item.Key), item => item.Key == relocation.Source ? relocation.LocalName : item.Value, StringComparer.Ordinal);
        ValidateNames(mapping, names);
        var versions = state.Versions.Select(item => item with { RemotePath = Move(item.RemotePath) }).ToList();
        var changes = state.Changes.Select(item => item with
        {
            RemotePath = Move(item.RemotePath),
            SavedVersion = item.SavedVersion is { } saved ? saved with { RemotePath = Move(saved.RemotePath) } : null,
        }).ToList();
        var empty = (state.EmptyFileBaselines ?? []).ToDictionary(item => Move(item.Key), item => item.Value, StringComparer.Ordinal);
        var creations = (state.LocalCreations ?? []).ToDictionary(item => Move(item.Key), item => item.Value, StringComparer.Ordinal);
        CheckRelocationBlock(state, relocation.Source, relocation.Id);
        CheckRelocationBlock(state, relocation.Destination, relocation.Id);
        await WriteAsync(mapping, state with { Version = Math.Max(6, state.Version), Versions = versions, Changes = changes, LocalNames = names,
            EmptyFileBaselines = empty, LocalCreations = creations, Relocations = [.. receipts, relocation] }, token).ConfigureAwait(false);
    }

    private string Identity(DesktopDriveMapping mapping, string path) => identityResolver?.Invoke(mapping, path)
        ?? DesktopDriveItemIdentity.Identifier(mapping.Id, path) ?? throw new InvalidDataException("cloud.sync.invalid_path");

    private string MappingPath(DesktopDriveMapping mapping) => Path.Combine(_root, mapping.Id.ToString("N"));
    private string ContentPath(DesktopDriveMapping mapping, Guid id) => Path.Combine(MappingPath(mapping), id.ToString("N") + ".content");
    internal Task<IDisposable> AcquireWritebackAsync(DesktopDriveMapping mapping, CancellationToken token = default) =>
        AcquireAsync(mapping, token, "upload.lock");

    private async Task<IDisposable> AcquireAsync(DesktopDriveMapping mapping, CancellationToken token, string lockName = "write.lock")
    {
        if (mapping.Id == Guid.Empty || mapping.ProfileId == Guid.Empty) throw new ArgumentException("cloud.sync.invalid_mapping");
        Directory.CreateDirectory(_root); RejectReparsePoint(_root);
        var path = MappingPath(mapping);
        Directory.CreateDirectory(path); RejectReparsePoint(path);
        var lockPath = Path.Combine(path, lockName); RejectReparsePoint(lockPath);
        // 同进程异步调用正常排队，跨进程仍由 OS 互斥；不以过期时间偷锁或重放未决请求。
        var gate = LocalGates.GetOrAdd(lockPath, static _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(token).ConfigureAwait(false);
        try { return new Lease(new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None), gate); }
        catch { gate.Release(); throw; }
    }

    private sealed class Lease(FileStream file, SemaphoreSlim gate) : IDisposable
    {
        public void Dispose() { try { file.Dispose(); } finally { gate.Release(); } }
    }

    private async Task<Snapshot> ReadAsync(DesktopDriveMapping mapping, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var path = Path.Combine(MappingPath(mapping), "state.json"); RejectReparsePoint(path);
        if (!File.Exists(path))
        {
            if (Directory.EnumerateFiles(MappingPath(mapping), "*.content").Any())
                throw new InvalidDataException("cloud.sync.unindexed_content");
            return new(1, mapping.Id, mapping.ProfileId, mapping.Scope, false, [], []);
        }
        // 缺失 Phase 等字段不得按枚举默认值 Prepared 解释，否则可能重放已提交请求。
        using var document = JsonSerializer.Deserialize<JsonDocument>(await File.ReadAllTextAsync(path, token))
            ?? throw new InvalidDataException("cloud.sync.invalid_state");
        var state = document.RootElement.Deserialize<Snapshot>(new JsonSerializerOptions { RespectRequiredConstructorParameters = true })
            ?? throw new InvalidDataException("cloud.sync.invalid_state");
        if (state.Version is not (1 or 2 or 3 or 4 or 5 or 6 or 7 or 8 or 9 or 10) || state.Version == 2 && state.LocalNames is null || state.Version == 1 && state.LocalNames is not null ||
            state.Version >= 4 && state.EmptyFileBaselines is null || state.Version < 4 && state.EmptyFileBaselines is not null ||
            state.Version >= 5 && (state.LocalCreations is null || state.LocalNames is null) || state.Version < 5 && state.LocalCreations is not null ||
            state.Version >= 6 && state.Relocations is null || state.Version < 6 && state.Relocations is not null ||
            state.Version >= 7 && state.NamespaceOperations is null || state.Version < 7 && state.NamespaceOperations is not null ||
            state.Version >= 8 && (state.Deletions is null || !document.RootElement.TryGetProperty("DeletionEnabled", out _)) ||
            state.Version < 8 && (state.Deletions is not null || state.DeletionEnabled) || state.DeletionEnabled && !state.WritebackEnabled ||
            state.MappingId != mapping.Id || state.ProfileId != mapping.ProfileId ||
            state.Scope != mapping.Scope || state.Versions is null || state.Changes is null ||
            state.Versions.Select(item => item.RemotePath).Distinct(StringComparer.Ordinal).Count() != state.Versions.Count ||
            state.Changes.Select(item => item.Id).Distinct().Count() != state.Changes.Count ||
            state.WritebackEnabled && (!CloudDriveWriteScope.CanEnable(mapping) || mapping.Scope.Kind == DesktopDriveScopeKind.AllShares && state.Version < 10))
            throw new InvalidDataException("cloud.sync.invalid_state");
        if (state.Version >= 3 && document.RootElement.GetProperty("Changes").EnumerateArray().Any(item => !item.TryGetProperty("EmptyBaseModifiedAt", out _)))
            throw new InvalidDataException("cloud.sync.invalid_baseline");
        if (state.Version >= 5 && document.RootElement.GetProperty("Changes").EnumerateArray().Any(item => !item.TryGetProperty("Kind", out _)))
            throw new InvalidDataException("cloud.sync.invalid_state");
        if (state.Version >= 9 && document.RootElement.GetProperty("Changes").EnumerateArray().Any(item => !item.TryGetProperty("ContentReleased", out _)))
            throw new InvalidDataException("cloud.sync.invalid_state");
        if (state.Relocations is { } relocations)
        {
            if (relocations.Select(item => item.Id).Distinct().Count() != relocations.Count) throw new InvalidDataException("cloud.sync.invalid_state");
            foreach (var item in relocations)
            {
                RequirePath(mapping, item.Source); RequirePath(mapping, item.Destination);
                if (item.Id == Guid.Empty || DesktopDrivePath.IsAncestorOrSame(item.Source, item.Destination)) throw new InvalidDataException("cloud.sync.invalid_state");
            }
        }
        if (state.NamespaceOperations is { } operations)
        {
            if (operations.Select(item => item.Id).Distinct().Count() != operations.Count) throw new InvalidDataException("cloud.relocate.invalid_state");
            foreach (var operation in operations) ValidateRelocation(mapping, operation);
        }
        if (state.Deletions is { } deletions)
        {
            if (deletions.Select(item => item.Id).Distinct().Count() != deletions.Count) throw new InvalidDataException("cloud.delete.invalid_state");
            foreach (var operation in deletions) ValidateDeletion(mapping, operation);
        }
        if (state.LocalCreations is { } creations)
            foreach (var creationPath in creations.Keys) { RequirePath(mapping, creationPath); if (!state.LocalNames!.ContainsKey(creationPath)) throw new InvalidDataException("cloud.sync.invalid_state"); }
        foreach (var item in state.Versions) { RequirePath(mapping, item.RemotePath); RequireVersion(item.Version, item.Length); }
        if (state.EmptyFileBaselines is { } baselines)
            foreach (var remotePath in baselines.Keys)
            {
                RequirePath(mapping, remotePath);
                if (state.Versions.Any(item => item.RemotePath == remotePath)) throw new InvalidDataException("cloud.sync.invalid_baseline");
            }
        if (state.LocalNames is not null) ValidateNames(mapping, state.LocalNames);
        foreach (var item in state.Changes)
        {
            CloudDriveWriteScope.RequireWritable(mapping, item.RemotePath);
            if (item.ContentReleased && (state.Version < 9 || item.Phase != CloudDriveChangePhase.Verified)) throw new InvalidDataException("cloud.sync.invalid_state");
            if (item.Id == Guid.Empty || item.ContentLength < 0 || item.ContentHash is null || item.ContentHash.Length != 64 ||
                !item.ContentHash.All(char.IsAsciiHexDigit) || !Enum.IsDefined(item.Phase) || !Enum.IsDefined(item.Kind) ||
                item.Kind == CloudDriveChangeKind.CreateDirectory && (state.Version < 5 || item.ContentLength != 0 || item.WasExisting))
                throw new InvalidDataException("cloud.sync.invalid_state");
            if (item.BaseVersion is not null) RequireVersion(item.BaseVersion, 0);
            if (item.EmptyBaseModifiedAt is not null && (state.Version < 3 || item.BaseVersion is not null))
                throw new InvalidDataException("cloud.sync.invalid_baseline");
            if (item.SavedVersion is { } saved)
            {
                RequireVersion(saved.Version, saved.Length);
                if (item.Phase != CloudDriveChangePhase.Verified || saved.RemotePath != item.RemotePath ||
                    saved.Length != item.ContentLength || item.SavedEmptyModifiedAt is not null)
                    throw new InvalidDataException("cloud.sync.invalid_baseline");
            }
            if (item.SavedEmptyModifiedAt is not null && (item.Phase != CloudDriveChangePhase.Verified || item.ContentLength != 0))
                throw new InvalidDataException("cloud.sync.invalid_baseline");
        }
        return state;
    }

    private async Task WriteAsync(DesktopDriveMapping mapping, Snapshot state, CancellationToken token)
    {
        var path = Path.Combine(MappingPath(mapping), "state.json"); RejectReparsePoint(path);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                65536, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await JsonSerializer.SerializeAsync(stream, state, cancellationToken: token);
                await stream.FlushAsync(token); stream.Flush(flushToDisk: true);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private async Task VerifyContentAsync(DesktopDriveMapping mapping, CloudDrivePendingChange change, CancellationToken token)
    {
        var content = await HashAsync(ContentPath(mapping, change.Id), token);
        if (content.Hash != change.ContentHash || content.Length != change.ContentLength)
            throw new InvalidDataException("cloud.sync.content_changed");
    }
    private static async Task<(string Hash, long Length)> HashAsync(string path, CancellationToken token)
    {
        RejectReparsePoint(path);
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            65536, FileOptions.Asynchronous | FileOptions.SequentialScan);
        var length = stream.Length;
        return (Convert.ToHexString(await SHA256.HashDataAsync(stream, token)), length);
    }
    private static CloudDrivePendingChange Find(Snapshot state, Guid id) =>
        state.Changes.SingleOrDefault(item => item.Id == id) ?? throw new InvalidDataException("cloud.sync.operation_missing");
    private static void Replace(Snapshot state, CloudDrivePendingChange change) =>
        state.Changes[state.Changes.FindIndex(item => item.Id == change.Id)] = change;
    private static void RequirePath(DesktopDriveMapping mapping, string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !path.StartsWith('/') || path == "/" || path.Contains('\\') ||
            path.Any(char.IsControl) || DesktopDrivePath.Normalize(path) != path ||
            mapping.Scope.Kind == DesktopDriveScopeKind.Folder &&
            (DesktopDrivePath.Normalize(mapping.Scope.FolderPath) is not { } root || root == path || !DesktopDrivePath.IsAncestorOrSame(root, path)))
            throw new InvalidDataException("cloud.sync.invalid_path");
    }
    private static void RequireVersion(string version, long length)
    {
        if (length < 0 || string.IsNullOrWhiteSpace(version) || version.Length < 2 || version[0] != '"' || version[^1] != '"' ||
            version[1..^1].Any(character => character == '"' || char.IsControl(character)))
            throw new InvalidDataException("cloud.sync.invalid_version");
    }
    private static void RejectReparsePoint(string path)
    {
        if (File.Exists(path) || Directory.Exists(path))
            if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("cloud.sync.reparse_point");
    }
}
