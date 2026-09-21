using System.Text.Json;
using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed class DesktopCloudDriveStore(string? path = null)
{
    private sealed record Snapshot(
        int Version,
        IReadOnlyList<DesktopDriveMapping> Mappings,
        IReadOnlyDictionary<Guid, IReadOnlyDictionary<string, string>> ItemPaths,
        IReadOnlyDictionary<Guid, DesktopDriveMappingRuntime>? Runtimes);

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _path = path ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "LanStash",
        "desktop-drives-v1.json");

    internal async Task<IReadOnlyList<DesktopDriveMapping>> LoadAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return (await LoadSnapshotUnlockedAsync().ConfigureAwait(false)).Mappings;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task SaveAsync(IReadOnlyList<DesktopDriveMapping> mappings)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            var mappingIds = mappings.Select(item => item.Id).ToHashSet();
            var itemPaths = snapshot.ItemPaths
                .Where(item => mappingIds.Contains(item.Key))
                .ToDictionary(item => item.Key, item => item.Value);
            var runtimes = (snapshot.Runtimes
                    ?? new Dictionary<Guid, DesktopDriveMappingRuntime>())
                .Where(item => mappingIds.Contains(item.Key))
                .ToDictionary(item => item.Key, item => item.Value);
            await SaveSnapshotUnlockedAsync(
                new Snapshot(3, mappings, itemPaths, runtimes)).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task<DesktopDriveMappingRuntime> LoadRuntimeAsync(
        Guid mappingId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            return snapshot.Runtimes?.GetValueOrDefault(mappingId)
                ?? DesktopDriveMappingRuntime.Default;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task SaveRuntimeAsync(
        Guid mappingId,
        DesktopDriveMappingRuntime runtime)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            if (!snapshot.Mappings.Any(item => item.Id == mappingId))
            {
                return;
            }
            var runtimes = (snapshot.Runtimes
                    ?? new Dictionary<Guid, DesktopDriveMappingRuntime>())
                .ToDictionary(item => item.Key, item => item.Value);
            runtimes[mappingId] = runtime;
            await SaveSnapshotUnlockedAsync(
                snapshot with { Version = 3, Runtimes = runtimes })
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task UpdateRuntimeAsync(
        Guid mappingId,
        Func<DesktopDriveMappingRuntime, DesktopDriveMappingRuntime> update)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            if (!snapshot.Mappings.Any(item => item.Id == mappingId))
            {
                return;
            }
            var runtimes = (snapshot.Runtimes
                    ?? new Dictionary<Guid, DesktopDriveMappingRuntime>())
                .ToDictionary(item => item.Key, item => item.Value);
            var current = runtimes.GetValueOrDefault(mappingId)
                ?? DesktopDriveMappingRuntime.Default;
            runtimes[mappingId] = update(current);
            await SaveSnapshotUnlockedAsync(
                snapshot with { Version = 3, Runtimes = runtimes })
                .ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task<IReadOnlyDictionary<string, string>> LoadItemPathsAsync(
        Guid mappingId)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            return snapshot.ItemPaths.TryGetValue(mappingId, out var values)
                ? values
                : new Dictionary<string, string>();
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task<IReadOnlyDictionary<string, string>> RegisterItemPathsAsync(
        Guid mappingId,
        IEnumerable<string> remotePaths)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            if (!snapshot.Mappings.Any(item => item.Id == mappingId))
            {
                throw new InvalidOperationException("CloudDriveNotMapped");
            }
            var allPaths = snapshot.ItemPaths.ToDictionary(
                item => item.Key,
                item => item.Value);
            var mappingPaths = allPaths.TryGetValue(mappingId, out var existing)
                ? existing.ToDictionary(item => item.Key, item => item.Value)
                : new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var rawPath in remotePaths)
            {
                var path = DesktopDrivePath.Normalize(rawPath);
                if (mappingPaths.Values.Contains(path, StringComparer.Ordinal)) continue;
                var identity = path is null ? null : DesktopDriveItemIdentity.Identifier(mappingId, "/identity/" + Guid.NewGuid().ToString("N"));
                if (path is not null && identity is not null)
                {
                    // 已有路径沿用持久身份；新对象不再由路径推导，删除后同名重建也不会复用旧身份。
                    while (mappingPaths.ContainsKey(identity))
                        identity = DesktopDriveItemIdentity.Identifier(mappingId, "/identity/" + Guid.NewGuid().ToString("N"))!;
                    mappingPaths.Add(identity, path);
                }
            }
            allPaths[mappingId] = mappingPaths;
            await SaveSnapshotUnlockedAsync(
                snapshot with
                {
                    Version = 3,
                    ItemPaths = allPaths,
                }).ConfigureAwait(false);
            return mappingPaths;
        }
        finally
        {
            _gate.Release();
        }
    }

    internal async Task<IReadOnlyDictionary<string, string>> RelocateItemPathsAsync(Guid mappingId, string source, string destination)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            var mapping = snapshot.Mappings.SingleOrDefault(item => item.Id == mappingId)
                ?? throw new InvalidOperationException("CloudDriveNotMapped");
            if (!CloudDriveWriteScope.CanWrite(mapping, source) || !CloudDriveWriteScope.CanWrite(mapping, destination) ||
                DesktopDrivePath.IsAncestorOrSame(source, destination)) throw new InvalidDataException("cloud.relocate.invalid_path");
            var current = snapshot.ItemPaths.GetValueOrDefault(mappingId) ?? new Dictionary<string, string>();
            var affected = current.Where(item => DesktopDrivePath.IsAncestorOrSame(source, item.Value)).ToArray();
            if (affected.Length == 0) throw new InvalidDataException("cloud.relocate.source_missing");
            if (current.Values.Any(value => DesktopDrivePath.IsAncestorOrSame(destination, value)))
                throw new InvalidDataException("cloud.relocate.destination_exists");
            string Move(string value) => DesktopDrivePath.IsAncestorOrSame(source, value) ? destination + value[source.Length..] : value;
            var moved = current.ToDictionary(item => item.Key, item => Move(item.Value), StringComparer.Ordinal);
            var indexes = snapshot.ItemPaths.ToDictionary(item => item.Key, item => item.Value);
            indexes[mappingId] = moved;
            var runtimes = (snapshot.Runtimes ?? new Dictionary<Guid, DesktopDriveMappingRuntime>()).ToDictionary(item => item.Key, item => item.Value);
            if (runtimes.TryGetValue(mappingId, out var runtime))
                runtimes[mappingId] = runtime with
                {
                    PinnedPaths = runtime.PinnedPaths.Select(Move).ToArray(),
                    CacheEntries = runtime.CacheEntries.ToDictionary(item => Move(item.Key), item => item.Value with { RemotePath = Move(item.Value.RemotePath) }, StringComparer.Ordinal),
                };
            await SaveSnapshotUnlockedAsync(snapshot with { ItemPaths = indexes, Runtimes = runtimes }).ConfigureAwait(false);
            return moved;
        }
        finally { _gate.Release(); }
    }

    internal Task ApplyCacheReleaseAsync(Guid mappingId, DesktopDriveMappingRuntime baseline,
        IReadOnlyCollection<string> released, IReadOnlyCollection<string>? unpinnedTargets = null) => UpdateRuntimeAsync(mappingId, current =>
    {
        bool Unpinned(string path) => unpinnedTargets?.Any(target => DesktopDrivePath.IsAncestorOrSame(target, path)) == true;
        var pins = current.PinnedPaths.Where(path => !Unpinned(path) || !baseline.PinnedPaths.Contains(path, StringComparer.Ordinal)).ToArray();
        var updated = current with { PinnedPaths = pins };
        var entries = current.CacheEntries.Where(item => !released.Contains(item.Key) ||
                !baseline.CacheEntries.TryGetValue(item.Key, out var old) || item.Value != old)
            .ToDictionary(item => item.Key, item => Unpinned(item.Key) ? item.Value with
            {
                Kind = updated.KeepsOffline(item.Key) ? DesktopDriveCacheEntryKind.KeptOffline : DesktopDriveCacheEntryKind.Temporary,
                UpdatedAt = DateTimeOffset.UtcNow,
            } : item.Value, StringComparer.Ordinal);
        // 只移除本次确实释放且未被新保存更新的记录；其他统计、状态和新离线偏好保持原样。
        return updated with { CacheEntries = entries };
    });

    internal async Task UnregisterItemPathAsync(Guid mappingId, string path, string? expectedIdentity = null)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var snapshot = await LoadSnapshotUnlockedAsync().ConfigureAwait(false);
            if (!snapshot.ItemPaths.TryGetValue(mappingId, out var current)) return;
            if (expectedIdentity is not null)
            {
                if (!current.TryGetValue(expectedIdentity, out var original)) return; // 已完成清理，不触碰后来同名的新项目。
                if (original != path) throw new InvalidDataException("cloud.delete.identity_changed");
            }
            var paths = snapshot.ItemPaths.ToDictionary(item => item.Key, item => item.Value);
            paths[mappingId] = current.Where(item => !DesktopDrivePath.IsAncestorOrSame(path, item.Value))
                .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
            var runtimes = (snapshot.Runtimes ?? new Dictionary<Guid, DesktopDriveMappingRuntime>()).ToDictionary(item => item.Key, item => item.Value);
            if (expectedIdentity is not null && runtimes.TryGetValue(mappingId, out var runtime))
                runtimes[mappingId] = runtime with
                {
                    PinnedPaths = runtime.PinnedPaths.Where(item => !DesktopDrivePath.IsAncestorOrSame(path, item)).ToArray(),
                    CacheEntries = runtime.CacheEntries.Where(item => !DesktopDrivePath.IsAncestorOrSame(path, item.Key))
                        .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal),
                };
            await SaveSnapshotUnlockedAsync(snapshot with { ItemPaths = paths, Runtimes = runtimes }).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private async Task<Snapshot> LoadSnapshotUnlockedAsync()
    {
        if (!File.Exists(_path))
        {
            return new(
                3,
                [],
                new Dictionary<Guid, IReadOnlyDictionary<string, string>>(),
                new Dictionary<Guid, DesktopDriveMappingRuntime>());
        }
        var content = await File.ReadAllTextAsync(_path).ConfigureAwait(false);
        using var document = JsonDocument.Parse(content);
        if (document.RootElement.ValueKind == JsonValueKind.Array)
        {
            var mappings = JsonSerializer.Deserialize<List<DesktopDriveMapping>>(content)
                ?? [];
            return new(
                3,
                mappings,
                new Dictionary<Guid, IReadOnlyDictionary<string, string>>(),
                new Dictionary<Guid, DesktopDriveMappingRuntime>());
        }
        return JsonSerializer.Deserialize<Snapshot>(content)
            ?? new(
                3,
                [],
                new Dictionary<Guid, IReadOnlyDictionary<string, string>>(),
                new Dictionary<Guid, DesktopDriveMappingRuntime>());
    }

    private async Task SaveSnapshotUnlockedAsync(Snapshot snapshot)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var temporaryPath = $"{_path}.{Guid.NewGuid():N}.tmp";
        try
        {
            await File.WriteAllTextAsync(
                temporaryPath,
                JsonSerializer.Serialize(snapshot)).ConfigureAwait(false);
            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
