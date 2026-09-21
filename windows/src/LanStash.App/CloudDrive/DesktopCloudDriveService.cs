using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using LanStash.Domain;
using Microsoft.Win32;

namespace LanStash.App.CloudDrive;

internal sealed class DesktopCloudDriveService : IDisposable
{
    private static readonly Guid ProviderId = new("50131da3-3e75-4a6f-8c97-8c283d2b6c4c");
    private const long DownloadChunkBytes = 4L * 1024 * 1024;
    private readonly DesktopCloudDriveStore _store = new();
    private readonly Dictionary<Guid, MappingRuntime> _runtimes = [];
    private readonly Dictionary<Guid, DesktopDriveMappingRuntime> _states = [];
    private readonly string _rootDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        "LanStash");
    private List<DesktopDriveMapping> _mappings = [];

    internal IReadOnlyList<DesktopDriveMapping> Mappings => _mappings;

    internal DesktopDriveMapping? MappingContaining(IEnumerable<string> paths)
    {
        var normalized = paths
            .Select(DesktopDrivePath.Normalize)
            .ToArray();
        if (normalized.Any(path => path is null))
        {
            return null;
        }
        return _mappings.FirstOrDefault(mapping =>
            normalized.All(path =>
            {
                if (mapping.Scope.Kind == DesktopDriveScopeKind.AllShares)
                {
                    return path != "/";
                }
                var root = DesktopDrivePath.Normalize(mapping.Scope.FolderPath);
                return root is not null &&
                    DesktopDrivePath.IsAncestorOrSame(root, path!);
            }));
    }

    internal async Task InitializeAsync()
    {
        _mappings = [.. await _store.LoadAsync().ConfigureAwait(false)];
        foreach (var mapping in _mappings)
        {
            _states[mapping.Id] = await _store.LoadRuntimeAsync(mapping.Id)
                .ConfigureAwait(false);
        }
        UpdateLaunchAtLogin();
    }

    internal async Task ActivateAsync(Guid profileId, IDsmRepository repository)
    {
        foreach (var mapping in _mappings.Where(item => item.ProfileId == profileId))
        {
            if (Runtime(mapping).IsManuallyPaused)
            {
                continue;
            }
            try
            {
                _ = await repository.ListFilesAsync(
                    mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                        ? string.Empty
                        : mapping.Scope.FolderPath ?? string.Empty,
                    0,
                    1).ConfigureAwait(false);
                await RegisterAndConnectAsync(mapping, repository).ConfigureAwait(false);
                await SetRuntimeAsync(
                    mapping.Id,
                    Runtime(mapping) with
                    {
                        State = DesktopDriveMappingState.Available,
                        LastSuccessfulCheckAt = DateTimeOffset.UtcNow,
                    }).ConfigureAwait(false);
            }
            catch
            {
                await SetRuntimeAsync(
                    mapping.Id,
                    Runtime(mapping) with
                    {
                        State = DesktopDriveMappingState.Offline,
                    }).ConfigureAwait(false);
            }
        }
    }

    internal async Task<DesktopDriveMapping> AddAsync(
        Guid profileId,
        string displayName,
        DesktopDriveScope scope,
        IDsmRepository repository,
        DesktopDriveCachePolicy? cachePolicy = null,
        bool launchAtLogin = true)
    {
        if (scope.Kind == DesktopDriveScopeKind.Folder)
        {
            var normalized = DesktopDrivePath.Normalize(scope.FolderPath)
                ?? throw new InvalidOperationException("CloudDriveInvalidPath");
            scope = DesktopDriveScope.Folder(normalized);
        }

        if (string.IsNullOrWhiteSpace(displayName))
        {
            throw new InvalidOperationException("CloudDriveInvalidName");
        }
        var selectedPolicy = cachePolicy ?? DesktopDriveCachePolicy.Default;
        DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();
        _ = CacheRoot(selectedPolicy);
        _ = await repository.ListFilesAsync(
            scope.Kind == DesktopDriveScopeKind.AllShares
                ? string.Empty
                : scope.FolderPath ?? string.Empty,
            0,
            1).ConfigureAwait(false);

        var mapping = new DesktopDriveMapping(
            Guid.NewGuid(),
            profileId,
            displayName.Trim(),
            scope,
            DesktopDriveAccessMode.ReadOnly,
            selectedPolicy,
            launchAtLogin,
            DateTimeOffset.UtcNow);
        if (_mappings.Any(item => item.Overlaps(mapping)))
        {
            throw new InvalidOperationException("CloudDriveOverlap");
        }

        _mappings.Add(mapping);
        await _store.SaveAsync(_mappings).ConfigureAwait(false);
        try
        {
            await RegisterAndConnectAsync(mapping, repository).ConfigureAwait(false);
            await SetRuntimeAsync(
                mapping.Id,
                DesktopDriveMappingRuntime.Default with
                {
                    State = DesktopDriveMappingState.Available,
                    LastSuccessfulCheckAt = DateTimeOffset.UtcNow,
                }).ConfigureAwait(false);
            UpdateLaunchAtLogin();
            return mapping;
        }
        catch
        {
            _mappings.Remove(mapping);
            await _store.SaveAsync(_mappings).ConfigureAwait(false);
            throw;
        }
    }

    internal async Task RemoveAsync(Guid mappingId)
    {
        var mapping = _mappings.FirstOrDefault(item => item.Id == mappingId);
        if (mapping is null)
        {
            return;
        }
        var sync = new DesktopCloudDriveSyncStore();
        if ((await sync.ReadChangesAsync(mapping).ConfigureAwait(false)).Any(change => change.IsPending) ||
            await sync.IsWritebackEnabledAsync(mapping).ConfigureAwait(false))
            throw new InvalidOperationException("CloudDriveWritebackRemoveBlocked");
        Disconnect(mappingId);
        if (_states.TryGetValue(mappingId, out var state))
        {
            await SetRuntimeAsync(
                mappingId,
                state with { State = DesktopDriveMappingState.Removing })
                .ConfigureAwait(false);
        }
        var path = MappingPath(mapping);
        var result = CloudFilesInterop.CfUnregisterSyncRoot(path);
        if (result < 0 && Directory.Exists(path))
        {
            CloudFilesInterop.ThrowIfFailed(result, "CfUnregisterSyncRoot");
        }
        _mappings.Remove(mapping);
        lock (_states)
        {
            _states.Remove(mappingId);
        }
        await _store.SaveAsync(_mappings).ConfigureAwait(false);
        UpdateLaunchAtLogin();
    }

    internal string MappingPath(DesktopDriveMapping mapping)
    {
        var suffix = mapping.Id.ToString("N")[..8];
        return Path.Combine(
            CacheRoot(mapping.CachePolicy),
            $"{SafeRootName(mapping.DisplayName)} ({suffix})");
    }

    internal static DesktopDriveCacheLocation CacheLocationForPath(string path)
    {
        var root = Path.GetPathRoot(path)
            ?? throw new InvalidOperationException("CloudDriveCacheDiskInvalid");
        var drive = new DriveInfo(root);
        if (!drive.IsReady ||
            !string.Equals(drive.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("CloudDriveCacheDiskInvalid");
        }
        var buffer = new StringBuilder(64);
        if (!CloudFilesInterop.GetVolumeNameForVolumeMountPoint(
                EnsureTrailingSeparator(root),
                buffer,
                (uint)buffer.Capacity))
        {
            throw new InvalidOperationException("CloudDriveCacheDiskInvalid");
        }
        return DesktopDriveCacheLocation.EligibleVolume(buffer.ToString());
    }

    internal void Reveal(DesktopDriveMapping mapping)
    {
        DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();
        Directory.CreateDirectory(MappingPath(mapping));
        Process.Start(new ProcessStartInfo("explorer.exe", MappingPath(mapping))
        {
            UseShellExecute = true,
        });
    }

    internal void DisconnectProfile(Guid profileId)
    {
        foreach (var mappingId in _mappings
                     .Where(item => item.ProfileId == profileId)
                     .Select(item => item.Id)
                     .ToArray())
        {
            Disconnect(mappingId);
        }
    }

    internal async Task ClearLocalCacheAsync(DesktopDriveMapping mapping)
    {
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out runtime);
        }
        if (runtime is null)
        {
            throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        }
        var state = Runtime(mapping);
        var paths = state.CacheEntries.Values
            .Where(entry => entry.Kind == DesktopDriveCacheEntryKind.Temporary)
            .Select(entry => entry.RemotePath)
            .ToArray();
        var released = runtime.Dehydrate(paths);
        await _store.ApplyCacheReleaseAsync(mapping.Id, state, released).ConfigureAwait(false);
        UpdateRuntimeCache(mapping.Id, await _store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        if (released.Count != paths.Length)
        {
            throw new IOException("One or more cached files could not be released.");
        }
    }

    internal DesktopDriveCacheSummary CacheSummary(DesktopDriveMapping mapping)
    {
        var state = Runtime(mapping);
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out runtime);
        }
        long temporary = 0;
        long offline = 0;
        var temporaryCount = 0;
        var offlineCount = 0;
        foreach (var entry in state.CacheEntries.Values)
        {
            var allocatedBytes = runtime?.AllocatedSizeFor(entry.RemotePath)
                ?? entry.AllocatedSizeBytes;
            if (allocatedBytes <= 0)
            {
                continue;
            }
            if (entry.Kind == DesktopDriveCacheEntryKind.Temporary)
            {
                temporary = checked(temporary + allocatedBytes);
                temporaryCount++;
            }
            else
            {
                offline = checked(offline + allocatedBytes);
                offlineCount++;
            }
        }
        return new(temporary, offline, temporaryCount, offlineCount);
    }

    internal string CacheVolumeName(DesktopDriveMapping mapping)
    {
        var root = Path.GetPathRoot(CacheRoot(mapping.CachePolicy))
            ?? throw new InvalidOperationException(
                "CloudDriveCacheDiskUnavailable");
        return new DriveInfo(root).Name;
    }

    internal DesktopDriveMappingRuntime Runtime(DesktopDriveMapping mapping)
    {
        lock (_states)
        {
            return _states.GetValueOrDefault(mapping.Id)
                ?? DesktopDriveMappingRuntime.Default;
        }
    }

    internal async Task<DesktopDriveMapping> SetTemporaryCacheLimitAsync(
        DesktopDriveMapping mapping,
        long limitBytes)
    {
        if (limitBytes < 0)
        {
            throw new InvalidOperationException("CloudDriveCacheLimitInvalid");
        }
        var updated = mapping with
        {
            CachePolicy = mapping.CachePolicy with
            {
                TemporaryLimitBytes = limitBytes,
            },
        };
        var index = _mappings.FindIndex(item => item.Id == mapping.Id);
        if (index < 0)
        {
            throw new InvalidOperationException("CloudDriveNotMapped");
        }
        _mappings[index] = updated;
        await _store.SaveAsync(_mappings).ConfigureAwait(false);
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out runtime);
        }
        if (runtime is not null)
        {
            await runtime.EnforceTemporaryLimitAsync(
                    Runtime(updated),
                    limitBytes)
                .ConfigureAwait(false);
        }
        return updated;
    }

    internal async Task<DesktopDriveMapping> SetLaunchAtLoginAsync(
        DesktopDriveMapping mapping,
        bool launchAtLogin)
    {
        var index = _mappings.FindIndex(item => item.Id == mapping.Id);
        if (index < 0)
        {
            throw new InvalidOperationException("CloudDriveNotMapped");
        }
        var updated = mapping with { LaunchAtLogin = launchAtLogin };
        _mappings[index] = updated;
        await _store.SaveAsync(_mappings).ConfigureAwait(false);
        UpdateLaunchAtLogin();
        return updated;
    }

    internal async Task<DesktopDriveCachePlan> PlanKeepOfflineAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository,
        IProgress<DesktopDrivePlanningProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var rootPath = mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
            ? "/"
            : DesktopDrivePath.Normalize(mapping.Scope.FolderPath)
                ?? throw new InvalidOperationException("CloudDriveInvalidPath");
        return await BuildPlanAsync(
            mapping,
            repository,
            [rootPath],
            [],
            progress,
            cancellationToken).ConfigureAwait(false);
    }

    private static async Task<DesktopDriveCachePlan> BuildPlanAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository,
        IReadOnlyList<string> rootFolders,
        IReadOnlyList<DesktopDrivePlannedFile> rootFiles,
        IProgress<DesktopDrivePlanningProgress>? progress,
        CancellationToken cancellationToken)
    {
        return await DesktopDriveTreePlanner.BuildAsync(
            rootFolders,
            (path, offset, limit, token) =>
                repository.ListFilesAsync(
                    path == "/" &&
                    mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                        ? string.Empty
                        : path,
                    offset,
                    limit,
                    token),
            rootFiles: rootFiles,
            progress: progress,
            cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    internal Task KeepOfflineAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository,
        IProgress<DesktopDriveOfflineProgress>? progress = null,
        IProgress<DesktopDrivePlanningProgress>? planningProgress = null,
        CancellationToken cancellationToken = default) =>
        KeepOfflineCoreAsync(
            mapping,
            repository,
            null,
            progress,
            planningProgress,
            cancellationToken);

    internal Task KeepOfflineAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository,
        IReadOnlyList<FileItem> items,
        IProgress<DesktopDriveOfflineProgress>? progress = null,
        IProgress<DesktopDrivePlanningProgress>? planningProgress = null,
        CancellationToken cancellationToken = default) =>
        KeepOfflineCoreAsync(
            mapping,
            repository,
            items,
            progress,
            planningProgress,
            cancellationToken);

    private async Task KeepOfflineCoreAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository,
        IReadOnlyList<FileItem>? items,
        IProgress<DesktopDriveOfflineProgress>? progress,
        IProgress<DesktopDrivePlanningProgress>? planningProgress,
        CancellationToken cancellationToken)
    {
        progress?.Report(new(DesktopDriveOfflinePhase.Planning));
        IReadOnlyList<string> pinRoots;
        DesktopDriveCachePlan plan;
        if (items is null)
        {
            var root = mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                ? "/"
                : DesktopDrivePath.Normalize(mapping.Scope.FolderPath)
                    ?? throw new InvalidOperationException("CloudDriveInvalidPath");
            pinRoots = [root];
            plan = await BuildPlanAsync(
                mapping,
                repository,
                [root],
                [],
                planningProgress,
                cancellationToken).ConfigureAwait(false);
        }
        else
        {
            if (items.Count == 0)
            {
                throw new InvalidOperationException("CloudDriveNoSelection");
            }
            pinRoots = items.Select(item =>
                    DesktopDrivePath.Normalize(item.Path)
                        ?? throw new InvalidOperationException("CloudDriveInvalidPath"))
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            var folders = items
                .Where(item => item.IsDirectory)
                .Select(item => DesktopDrivePath.Normalize(item.Path)!)
                .ToArray();
            var files = items
                .Where(item => !item.IsDirectory)
                .Select(item => new DesktopDrivePlannedFile(
                    item.Path,
                    item.Size,
                    item.ModifiedAt))
                .ToArray();
            plan = await BuildPlanAsync(
                mapping,
                repository,
                folders,
                files,
                planningProgress,
                cancellationToken).ConfigureAwait(false);
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (!plan.IsComplete)
        {
            throw new InvalidOperationException("CloudDrivePlanIncomplete");
        }

        progress?.Report(new(
            DesktopDriveOfflinePhase.CheckingSpace,
            TotalFiles: plan.Files.Count,
            TotalBytes: plan.TotalBytes));
        var mappingPath = MappingPath(mapping);
        var driveRoot = Path.GetPathRoot(mappingPath)
            ?? throw new IOException("Cloud drive cache volume is unavailable.");
        var drive = new DriveInfo(driveRoot);
        var currentCacheEntries = Runtime(mapping).CacheEntries;
        MappingRuntime? activeRuntime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out activeRuntime);
        }
        var decision = DesktopDriveCacheSpaceCalculator.Evaluate(
            plan.Files.Select(file =>
                new DesktopDriveCacheCandidate(
                    file.SizeBytes,
                    activeRuntime?.AllocatedSizeFor(file.RemotePath) ??
                    currentCacheEntries.GetValueOrDefault(file.RemotePath)
                        ?.AllocatedSizeBytes ?? 0)).ToArray(),
            drive.TotalSize,
            drive.AvailableFreeSpace);
        if (decision.Kind != DesktopDriveCacheSpaceDecisionKind.Allowed)
        {
            throw new InsufficientLocalSpaceException(
                decision.RequiredBytes,
                decision.AvailableBytes,
                decision.ShortageBytes,
                drive.Name);
        }

        await RegisterAndConnectAsync(mapping, repository).ConfigureAwait(false);
        MappingRuntime runtime;
        lock (_runtimes)
        {
            runtime = _runtimes[mapping.Id];
        }
        var previousState = Runtime(mapping);
        try
        {
            progress?.Report(new(
                DesktopDriveOfflinePhase.Preparing,
                TotalFiles: plan.Files.Count,
                TotalBytes: plan.TotalBytes,
                RequiredBytes: decision.RequiredBytes,
                AvailableBytes: decision.AvailableBytes,
                VolumeName: drive.Name));
            await runtime.EnsurePlaceholderTreeAsync(plan, cancellationToken)
                .ConfigureAwait(false);
            await SetRuntimeAsync(
                mapping.Id,
                previousState with
                {
                    State = DesktopDriveMappingState.Checking,
                    PinnedPaths = previousState.PinnedPaths
                        .Concat(pinRoots)
                        .Distinct(StringComparer.Ordinal)
                        .Order(StringComparer.Ordinal)
                        .ToArray(),
                    CacheEntries = previousState.CacheEntries.ToDictionary(
                        item => item.Key,
                        item => pinRoots.Any(root =>
                            DesktopDrivePath.IsAncestorOrSame(root, item.Key))
                                ? item.Value with
                                {
                                    Kind = DesktopDriveCacheEntryKind.KeptOffline,
                                    UpdatedAt = DateTimeOffset.UtcNow,
                                }
                                : item.Value,
                        StringComparer.Ordinal),
                }).ConfigureAwait(false);
            runtime.SetPinned(pinRoots, true);
            await runtime.HydrateAsync(
                plan,
                progress,
                cancellationToken).ConfigureAwait(false);
            await SetRuntimeAsync(
                mapping.Id,
                Runtime(mapping) with
                {
                    State = DesktopDriveMappingState.Available,
                    LastSuccessfulCheckAt = DateTimeOffset.UtcNow,
                }).ConfigureAwait(false);
            progress?.Report(new(
                DesktopDriveOfflinePhase.Completed,
                plan.Files.Count,
                plan.Files.Count,
                plan.TotalBytes,
                plan.TotalBytes,
                decision.RequiredBytes,
                decision.AvailableBytes,
                VolumeName: drive.Name));
        }
        catch (OperationCanceledException)
        {
            await RestorePinsAfterFailedKeepAsync(
                mapping,
                runtime,
                pinRoots,
                previousState,
                DesktopDriveMappingState.Available).ConfigureAwait(false);
            progress?.Report(new(
                DesktopDriveOfflinePhase.Cancelled,
                TotalFiles: plan.Files.Count,
                TotalBytes: plan.TotalBytes));
            throw;
        }
        catch
        {
            await RestorePinsAfterFailedKeepAsync(
                mapping,
                runtime,
                pinRoots,
                previousState,
                DesktopDriveMappingState.Degraded).ConfigureAwait(false);
            throw;
        }
    }

    private async Task RestorePinsAfterFailedKeepAsync(
        DesktopDriveMapping mapping,
        MappingRuntime runtime,
        IReadOnlyList<string> pinRoots,
        DesktopDriveMappingRuntime previousState,
        DesktopDriveMappingState state)
    {
        try
        {
            runtime.SetPinned(pinRoots, false);
        }
        catch
        {
            // 状态仍需恢复；平台固定标记会在下次连接时重新核对。
        }
        var current = Runtime(mapping);
        await SetRuntimeAsync(
            mapping.Id,
            current with
            {
                State = state,
                PinnedPaths = previousState.PinnedPaths,
                CacheEntries = current.CacheEntries.ToDictionary(
                    item => item.Key,
                    item => item.Value with
                    {
                        Kind = previousState.KeepsOffline(item.Key)
                            ? DesktopDriveCacheEntryKind.KeptOffline
                            : DesktopDriveCacheEntryKind.Temporary,
                        UpdatedAt = DateTimeOffset.UtcNow,
                    },
                    StringComparer.Ordinal),
            }).ConfigureAwait(false);
    }

    internal async Task ReleaseOfflineAsync(DesktopDriveMapping mapping)
    {
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out runtime);
        }
        if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        var state = Runtime(mapping);
        runtime.SetPinned(state.PinnedPaths, false);
        await _store.ApplyCacheReleaseAsync(mapping.Id, state, [], state.PinnedPaths).ConfigureAwait(false);
        UpdateRuntimeCache(mapping.Id, await _store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        if (runtime is not null)
        {
            var offlinePaths = state.CacheEntries.Values
                .Where(entry => entry.Kind == DesktopDriveCacheEntryKind.KeptOffline)
                .Select(entry => entry.RemotePath)
                .ToArray();
            // 第一阶段已更新类型，因此清理以该阶段后的快照比较，不能写回旧缓存清单。
            var baseline = Runtime(mapping);
            var released = runtime.Dehydrate(offlinePaths);
            await _store.ApplyCacheReleaseAsync(mapping.Id, baseline, released).ConfigureAwait(false);
            UpdateRuntimeCache(mapping.Id, await _store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
            if (released.Count != offlinePaths.Length)
            {
                throw new IOException("One or more offline files could not be released.");
            }
        }
    }

    internal async Task ReleaseOfflineAsync(
        DesktopDriveMapping mapping,
        IReadOnlyList<FileItem> items)
    {
        var targets = items
            .Select(item => DesktopDrivePath.Normalize(item.Path)
                ?? throw new InvalidOperationException("CloudDriveInvalidPath"))
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var state = Runtime(mapping);
        var remainingPins = state.PinnedPaths
            .Where(pin => !targets.Any(target =>
                DesktopDrivePath.IsAncestorOrSame(target, pin)))
            .ToArray();
        if (targets.Any(target => remainingPins.Any(pin =>
                DesktopDrivePath.IsAncestorOrSame(pin, target))))
        {
            throw new InvalidOperationException("CloudDriveCoveredByParent");
        }
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            _runtimes.TryGetValue(mapping.Id, out runtime);
        }
        if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        runtime.SetPinned(targets, false);
        var cachedPaths = state.CacheEntries.Values
            .Where(entry =>
                entry.Kind == DesktopDriveCacheEntryKind.KeptOffline &&
                targets.Any(target =>
                    DesktopDrivePath.IsAncestorOrSame(
                        target,
                        entry.RemotePath)))
            .Select(entry => entry.RemotePath)
            .ToArray();
        var released = runtime.Dehydrate(cachedPaths);
        await _store.ApplyCacheReleaseAsync(mapping.Id, state, released, targets).ConfigureAwait(false);
        UpdateRuntimeCache(mapping.Id, await _store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        if (released.Count != cachedPaths.Length)
        {
            throw new IOException("One or more offline files could not be released.");
        }
    }

    internal async Task PauseAsync(DesktopDriveMapping mapping)
    {
        Disconnect(mapping.Id);
        await SetRuntimeAsync(
            mapping.Id,
            Runtime(mapping) with
            {
                State = DesktopDriveMappingState.Paused,
                IsManuallyPaused = true,
            }).ConfigureAwait(false);
    }

    internal async Task ResumeAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository)
    {
        await SetRuntimeAsync(
            mapping.Id,
            Runtime(mapping) with
            {
                State = DesktopDriveMappingState.Checking,
                IsManuallyPaused = false,
            }).ConfigureAwait(false);
        try
        {
            await RegisterAndConnectAsync(mapping, repository).ConfigureAwait(false);
            await SetRuntimeAsync(
                mapping.Id,
                Runtime(mapping) with
                {
                    State = DesktopDriveMappingState.Available,
                    LastSuccessfulCheckAt = DateTimeOffset.UtcNow,
                }).ConfigureAwait(false);
        }
        catch
        {
            await SetRuntimeAsync(
                mapping.Id,
                Runtime(mapping) with { State = DesktopDriveMappingState.Offline })
                .ConfigureAwait(false);
            throw;
        }
    }

    internal async Task<CloudDriveRefreshSummary> RefreshFilesAsync(DesktopDriveMapping mapping, CancellationToken token)
    {
        DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();
        MappingRuntime? runtime;
        lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
        if (runtime is null || !_mappings.Contains(mapping)) throw new InvalidOperationException("cloud.refresh.disconnected");
        return await runtime.RefreshFilesAsync(token).ConfigureAwait(false);
    }

    internal async Task<CloudDriveWritebackOverview> ReadWritebackAsync(DesktopDriveMapping mapping, CancellationToken token)
    {
        if (!_mappings.Contains(mapping)) throw new InvalidOperationException("CloudDriveNotMapped");
        var sync = new DesktopCloudDriveSyncStore();
        return new(await sync.IsWritebackEnabledAsync(mapping, token).ConfigureAwait(false),
            await sync.ReadChangesAsync(mapping, token).ConfigureAwait(false),
            await sync.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false),
            await sync.IsDeletionEnabledAsync(mapping, token).ConfigureAwait(false),
            await sync.ReadDeletionOperationsAsync(mapping, token).ConfigureAwait(false));
    }

    internal async Task ConfigureDeletionAsync(DesktopDriveMapping mapping, bool enabled, bool confirmed, CancellationToken token)
    {
        if (!_mappings.Contains(mapping)) throw new InvalidOperationException("CloudDriveNotMapped");
        MappingRuntime? runtime; lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
        if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        await runtime.ConfigureDeletionAsync(enabled, confirmed, token).ConfigureAwait(false);
    }

    internal async Task RecoverDeletionAsync(DesktopDriveMapping mapping, IDsmRepository repository, CloudDriveDeletionOperation expected,
        CloudDriveDeletionRecoveryAction action, bool confirmed, CancellationToken token)
    {
        if (!_mappings.Contains(mapping) || !confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        var sync = new DesktopCloudDriveSyncStore();
        var current = (await sync.ReadDeletionOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == expected.Id);
        if (current != expected) throw new InvalidOperationException("CloudDriveWritebackChanged");
        var coordinator = new CloudDriveDeletionCoordinator(mapping, repository, sync);
        if (action == CloudDriveDeletionRecoveryAction.Review) { await coordinator.ReviewAsync(expected.Id, token).ConfigureAwait(false); return; }
        if (action == CloudDriveDeletionRecoveryAction.Abandon) { await coordinator.AbandonAsync(expected, true, token).ConfigureAwait(false); return; }
        MappingRuntime? runtime; lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
        if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        if (action == CloudDriveDeletionRecoveryAction.Confirm)
        {
            await runtime.ValidateLocalDeletionAsync(expected, token).ConfigureAwait(false);
            current = await coordinator.ConfirmAsync(expected, true, token).ConfigureAwait(false);
        }
        if (current.Phase == CloudDriveDeletionPhase.ServerVerified) await runtime.CompleteDeletionAsync(current, token).ConfigureAwait(false);
    }

    internal async Task RecoverRelocationAsync(DesktopDriveMapping mapping, IDsmRepository repository,
        CloudDriveRelocationOperation expected, CloudDriveRelocationRecoveryAction action, bool confirmed, CancellationToken token)
    {
        if (!_mappings.Contains(mapping) || !confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        var sync = new DesktopCloudDriveSyncStore();
        var current = (await sync.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == expected.Id);
        if (current is null || !DesktopCloudDriveSyncStore.SameOperation(current, expected)) throw new InvalidOperationException("CloudDriveWritebackChanged");
        var coordinator = new CloudDriveRelocationCoordinator(mapping, repository, sync);
        if (action == CloudDriveRelocationRecoveryAction.Review) await coordinator.ReviewAsync(expected.Id, true, token).ConfigureAwait(false);
        else if (action == CloudDriveRelocationRecoveryAction.Continue) await coordinator.ContinueAsync(expected, true, token).ConfigureAwait(false);
        else if (action == CloudDriveRelocationRecoveryAction.Abandon)
        {
            MappingRuntime? runtime;
            lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
            if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
            await runtime.RestoreLocalBeforeAbandonAsync(expected, token).ConfigureAwait(false);
            await coordinator.AbandonAsync(expected, true, token).ConfigureAwait(false);
        }
        else
        {
            MappingRuntime? runtime;
            lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
            if (runtime is null) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
            await runtime.CompleteRelocationAsync(expected, true, token).ConfigureAwait(false);
        }
    }

    internal async Task<CloudDriveWritebackPreparation> ConfigureWritebackAsync(DesktopDriveMapping mapping, bool enabled,
        bool confirmed, CancellationToken token)
    {
        DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();
        MappingRuntime? runtime;
        lock (_runtimes) { _runtimes.TryGetValue(mapping.Id, out runtime); }
        if (runtime is null || !_mappings.Contains(mapping)) throw new InvalidOperationException("CloudDriveResumeBeforeWriteback");
        return await runtime.ConfigureWritebackAsync(enabled, confirmed, token).ConfigureAwait(false);
    }

    internal async Task RecoverWritebackAsync(DesktopDriveMapping mapping, IDsmRepository repository,
        CloudDrivePendingChange expected, CloudDriveRecoveryAction action, bool confirmed, CancellationToken token)
    {
        if (!_mappings.Contains(mapping)) throw new InvalidOperationException("CloudDriveNotMapped");
        var sync = new DesktopCloudDriveSyncStore();
        var current = (await sync.ReadChangesAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == expected.Id);
        if (current != expected) throw new InvalidOperationException("CloudDriveWritebackChanged");
        var coordinator = new CloudDriveWritebackCoordinator(mapping, repository, sync);
        switch (action)
        {
            case CloudDriveRecoveryAction.Review: await coordinator.ReviewAsync(expected.Id, token, acceptDirectory: confirmed).ConfigureAwait(false); break;
            case CloudDriveRecoveryAction.Save: await coordinator.SubmitAsync(expected.Id, token).ConfigureAwait(false); break;
            case CloudDriveRecoveryAction.Retry: await coordinator.RetryAsync(expected, confirmed, token).ConfigureAwait(false); break;
            case CloudDriveRecoveryAction.KeepLocal: await sync.KeepLocallyAsync(mapping, expected.Id, confirmed, token).ConfigureAwait(false); break;
        }
        lock (_runtimes)
            if (_runtimes.TryGetValue(mapping.Id, out var runtime)) runtime.NotifyWriteback(expected.RemotePath);
    }

    internal Task ExportWritebackAsync(DesktopDriveMapping mapping, Guid id, string destination, CancellationToken token)
    {
        if (!_mappings.Contains(mapping)) throw new InvalidOperationException("CloudDriveNotMapped");
        var target = Path.GetFullPath(destination);
        if (_mappings.Any(item => target.StartsWith(MappingPath(item) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("CloudDriveExportOutsideMapping");
        return new DesktopCloudDriveSyncStore().ExportContentAsync(mapping, id, target, true, token);
    }

    public void Dispose()
    {
        foreach (var mappingId in _runtimes.Keys.ToArray())
        {
            Disconnect(mappingId);
        }
    }

    private async Task RegisterAndConnectAsync(
        DesktopDriveMapping mapping,
        IDsmRepository repository)
    {
        DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();
        if (_runtimes.ContainsKey(mapping.Id))
        {
            return;
        }
        var itemPaths = await _store.LoadItemPathsAsync(mapping.Id)
            .ConfigureAwait(false);
        var localNames = await new DesktopCloudDriveSyncStore().RegisterLocalNamesAsync(mapping,
            DesktopDriveWindowsNameCodec.BuildSafeSegments(itemPaths.Values), []).ConfigureAwait(false);
        await Task.Run(async () =>
        {
            var path = MappingPath(mapping);
            Directory.CreateDirectory(path);
            var identity = Encoding.UTF8.GetBytes(mapping.Id.ToString("D"));
            var identityHandle = GCHandle.Alloc(identity, GCHandleType.Pinned);
            try
            {
                var registration = new CloudFilesInterop.SyncRegistration
                {
                    StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncRegistration>(),
                    ProviderName = "LanStash",
                    ProviderVersion = "1.0",
                    SyncRootIdentity = identityHandle.AddrOfPinnedObject(),
                    SyncRootIdentityLength = (uint)identity.Length,
                    FileIdentity = IntPtr.Zero,
                    FileIdentityLength = 0,
                    ProviderId = ProviderId,
                };
                var policies = new CloudFilesInterop.SyncPolicies
                {
                    StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.SyncPolicies>(),
                    Hydration = new() { Primary = 1, Modifier = 0 },
                    Population = new() { Primary = CloudFilesInterop.PopulationPolicyFull, Modifier = 0 },
                    // 数据修改仍由系统清除已同步；名称走独立日志，不把未回传的 Windows 属性当作内容编辑。
                    InSync = CloudFilesInterop.InSyncPolicyDefault,
                    HardLink = 0,
                    PlaceholderManagement = 0,
                };
                CloudFilesInterop.ThrowIfFailed(
                    CloudFilesInterop.CfRegisterSyncRoot(
                        path,
                        registration,
                        policies,
                        CloudFilesInterop.RegisterUpdate |
                        CloudFilesInterop.RegisterMarkRootInSync),
                    "CfRegisterSyncRoot");
            }
            finally
            {
                identityHandle.Free();
            }

            var runtime = new MappingRuntime(
                mapping,
                path,
                repository,
                _store,
                itemPaths,
                localNames,
                state => UpdateRuntimeCache(mapping.Id, state));
            runtime.ContextHandle = GCHandle.Alloc(runtime);
            var callbacks = new[]
            {
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackFetchData,
                    Callback = runtime.FetchDataCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackCancelFetchData,
                    Callback = runtime.CancelCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackFetchPlaceholders,
                    Callback = runtime.FetchPlaceholdersCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackCancelFetchPlaceholders,
                    Callback = runtime.CancelCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNotifyFileOpenCompletion,
                    Callback = runtime.FileOpenedCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNotifyFileCloseCompletion,
                    Callback = runtime.FileClosedCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNotifyDelete,
                    Callback = runtime.RejectDeleteCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNotifyRename,
                    Callback = runtime.RejectRenameCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNotifyRenameCompletion,
                    Callback = runtime.RenameCompletedCallback,
                },
                new CloudFilesInterop.CallbackRegistration
                {
                    Type = CloudFilesInterop.CallbackNone,
                },
            };
            var result = CloudFilesInterop.CfConnectSyncRoot(
                path,
                callbacks,
                GCHandle.ToIntPtr(runtime.ContextHandle),
                    CloudFilesInterop.ConnectRequireFullPath | CloudFilesInterop.ConnectRequireProcessInfo,
                out var connectionKey);
            if (result < 0)
            {
                runtime.ContextHandle.Free();
                CloudFilesInterop.ThrowIfFailed(result, "CfConnectSyncRoot");
            }
            runtime.ConnectionKey = connectionKey;
            runtime.Callbacks = callbacks;
            lock (_runtimes)
            {
                _runtimes[mapping.Id] = runtime;
            }
            try { await runtime.StartWritebackAsync().ConfigureAwait(false); }
            catch { Disconnect(mapping.Id); throw; }
        }).ConfigureAwait(false);
    }

    private async Task SetRuntimeAsync(
        Guid mappingId,
        DesktopDriveMappingRuntime runtime)
    {
        lock (_states)
        {
            _states[mappingId] = runtime;
        }
        await _store.SaveRuntimeAsync(mappingId, runtime).ConfigureAwait(false);
    }

    private void UpdateRuntimeCache(
        Guid mappingId,
        DesktopDriveMappingRuntime runtime)
    {
        lock (_states)
        {
            _states[mappingId] = runtime;
        }
    }

    private void Disconnect(Guid mappingId)
    {
        MappingRuntime? runtime;
        lock (_runtimes)
        {
            if (!_runtimes.Remove(mappingId, out runtime))
            {
                return;
            }
        }
        var callbacksDrained = runtime.StopAcceptingCallbacksAsync();
        _ = CloudFilesInterop.CfDisconnectSyncRoot(runtime.ConnectionKey);
        callbacksDrained.GetAwaiter().GetResult();
        if (runtime.ContextHandle.IsAllocated)
        {
            runtime.ContextHandle.Free();
        }
    }

    private void UpdateLaunchAtLogin()
    {
        try
        {
            const string valueName = "LanStash";
            using var runKey = Registry.CurrentUser.CreateSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run");
            if (DesktopCloudDriveCapabilityGate.IsRegistrationEnabled &&
                _mappings.Any(item => item.LaunchAtLogin))
            {
                runKey?.SetValue(valueName, $"\"{Environment.ProcessPath}\"");
            }
            else
            {
                runKey?.DeleteValue(valueName, throwOnMissingValue: false);
            }
        }
        catch
        {
            // 启动注册失败不影响当前会话中的云盘位置。
        }
    }

    private string CacheRoot(DesktopDriveCachePolicy policy)
    {
        if (policy.Location.Kind == DesktopDriveCacheLocationKind.SystemDefault)
        {
            return _rootDirectory;
        }
        var volumeName = policy.Location.VolumeId;
        if (string.IsNullOrWhiteSpace(volumeName))
        {
            throw new InvalidOperationException("CloudDriveCacheDiskInvalid");
        }
        var buffer = new char[1024];
        if (!CloudFilesInterop.GetVolumePathNamesForVolumeName(
                volumeName,
                buffer,
                (uint)buffer.Length,
                out var required))
        {
            if (required > (uint)buffer.Length)
            {
                buffer = new char[checked((int)required)];
                if (!CloudFilesInterop.GetVolumePathNamesForVolumeName(
                        volumeName,
                        buffer,
                        (uint)buffer.Length,
                        out required))
                {
                    throw new InvalidOperationException(
                        "CloudDriveCacheDiskUnavailable");
                }
            }
            else
            {
                throw new InvalidOperationException(
                    "CloudDriveCacheDiskUnavailable");
            }
        }
        var root = new string(buffer)
            .Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .FirstOrDefault()
            ?? throw new InvalidOperationException("CloudDriveCacheDiskUnavailable");
        var drive = new DriveInfo(root);
        if (!drive.IsReady ||
            !string.Equals(drive.DriveFormat, "NTFS", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("CloudDriveCacheDiskUnavailable");
        }
        return Path.Combine(root, "LanStash");
    }

    private static string EnsureTrailingSeparator(string path) =>
        path.EndsWith(Path.DirectorySeparatorChar)
            ? path
            : path + Path.DirectorySeparatorChar;

    private static string SafeRootName(string displayName)
    {
        var value = DesktopDriveWindowsNameCodec.EscapeSegment(
            displayName.Trim());
        return value.Length > 80
            ? value[..80].TrimEnd(' ', '.')
            : value;
    }

    private sealed class MappingRuntime
    {
        private readonly DesktopDriveMapping mapping;
        private readonly string localRoot;
        private readonly IDsmRepository repository;
        private readonly DesktopCloudDriveStore store;
        private readonly Action<DesktopDriveMappingRuntime> runtimeChanged;
        internal MappingRuntime(DesktopDriveMapping mapping, string localRoot, IDsmRepository repository,
            DesktopCloudDriveStore store, IReadOnlyDictionary<string, string> initialItemPaths,
            IReadOnlyDictionary<string, string> initialLocalNames, Action<DesktopDriveMappingRuntime> runtimeChanged)
        {
            this.mapping = mapping; this.localRoot = localRoot; this.repository = repository;
            this.store = store; this.runtimeChanged = runtimeChanged;
            _remotePaths = new(initialItemPaths, StringComparer.Ordinal);
            _safeSegments = new(initialLocalNames, StringComparer.Ordinal);
            _syncStore = new(identityResolver: (_, path) => ItemIdentity(path));
        }
        private DesktopDriveMapping Mapping => mapping;
        private readonly DesktopCloudDriveSyncStore _syncStore;
        private readonly CancellationTokenSource _refreshLifetime = new();
        private readonly CloudFileLocalRemovalGate _localRemovals = new();
        private readonly ConcurrentDictionary<string, string> _localRemotePaths = new(StringComparer.OrdinalIgnoreCase);
        private CloudDriveWritebackSession? _writebackSession;
        private readonly SemaphoreSlim _writebackConfiguration = new(1, 1);
        private readonly SemaphoreSlim _relocationCompletion = new(1, 1);
        private volatile bool _writebackEnabled;
        private volatile bool _deletionEnabled;
        internal readonly CloudFilesInterop.Callback FetchDataCallback =
            OnFetchData;
        internal readonly CloudFilesInterop.Callback FetchPlaceholdersCallback =
            OnFetchPlaceholders;
        internal readonly CloudFilesInterop.Callback CancelCallback =
            OnCancel;
        internal readonly CloudFilesInterop.Callback FileOpenedCallback =
            OnFileOpened;
        internal readonly CloudFilesInterop.Callback FileClosedCallback = OnFileClosed;
        internal readonly CloudFilesInterop.Callback RejectDeleteCallback =
            OnRejectDelete;
        internal readonly CloudFilesInterop.Callback RejectRenameCallback =
            OnRenameRequested;
        internal readonly CloudFilesInterop.Callback RenameCompletedCallback = OnRenameCompleted;
        internal GCHandle ContextHandle;
        internal CloudFilesInterop.ConnectionKey ConnectionKey;
        internal CloudFilesInterop.CallbackRegistration[] Callbacks = [];
        private readonly ConcurrentDictionary<string, string> _remotePaths;
        private readonly ConcurrentDictionary<string, string> _safeSegments;
        private readonly ConcurrentDictionary<long, ActiveRangeRequest>
            _requestCancellations = [];
        private readonly ConcurrentDictionary<long, CancellationTokenSource>
            _placeholderRequestCancellations = [];
        private readonly ConcurrentDictionary<string, SemaphoreSlim>
            _rangeTransferGates = new(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, DateTimeOffset>
            _lastAccessWrites = new(StringComparer.Ordinal);
        private readonly object _callbackGate = new();
        private TaskCompletionSource? _callbacksDrained;
        private int _activeCallbacks;
        private bool _acceptingCallbacks = true;

        internal async Task StartWritebackAsync()
        {
            try
            {
                _writebackEnabled = await _syncStore.IsWritebackEnabledAsync(mapping, _refreshLifetime.Token).ConfigureAwait(false);
                _deletionEnabled = await _syncStore.IsDeletionEnabledAsync(mapping, _refreshLifetime.Token).ConfigureAwait(false);
                try { await _syncStore.CleanReleasedContentAsync(mapping, _refreshLifetime.Token).ConfigureAwait(false); }
                catch (Exception error) when (error is UnauthorizedAccessException or IOException)
                { await ReportWritebackStateAsync(error).ConfigureAwait(false); }
                if (_writebackSession is not null || !_writebackEnabled) return;
                foreach (var path in _remotePaths.Values.Where(path => path != RootRemotePath()))
                    _localRemotePaths[LocalPath(path)] = path;
                var session = new CloudDriveWritebackSession(mapping, localRoot, repository, _syncStore,
                    path => _localRemotePaths.GetValueOrDefault(path), error => _ = ReportWritebackStateAsync(error),
                    registerNewPath: async (path, token) =>
                    {
                        foreach (var operation in (await _syncStore.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).Where(item => item.IsPending))
                        {
                            var parent = operation.Destination[..Math.Max(1, operation.Destination.LastIndexOf('/'))];
                            var target = Path.Combine(LocalPath(parent), operation.LocalName);
                            if (string.Equals(path, target, StringComparison.OrdinalIgnoreCase) ||
                                operation.IsDirectory && path.StartsWith(target + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return null;
                        }
                        // 事件溢出或离线改名可能丢失源目标关系；缺少原投影时不猜测新文件身份。
                        if (HasMissingLocalProjection()) throw new InvalidOperationException("CloudDriveWritebackPending");
                        var remote = await _syncStore.RegisterLocalCreationAsync(mapping, localRoot, path, _remotePaths.Values.ToArray(), token).ConfigureAwait(false);
                        var pending = await _syncStore.ReadLocalCreationsAsync(mapping, token).ConfigureAwait(false);
                        await RegisterPathsAsync(pending.Keys, token).ConfigureAwait(false);
                        return remote;
                    }, itemIdentity: ItemIdentity, renamedLocalPath: BindObservedLocalMoveAsync,
                    resolveExistingPath: ResolveWritebackPathAsync, deletedLocalPath: RecordDeletedLocalPathAsync,
                    cacheChanged: async (path, length, saved, token) =>
                    {
                        token.ThrowIfCancellationRequested();
                        await RecordCacheEntryAsync(path, length, saved).ConfigureAwait(false);
                    });
                _writebackSession = session;
                session.Start(() => _localRemotePaths.Keys);
            }
            catch (OperationCanceledException) when (_refreshLifetime.IsCancellationRequested) { }
            catch (Exception error)
            {
                await ReportWritebackStateAsync(error).ConfigureAwait(false);
                throw;
            }
        }

        private bool HasMissingLocalProjection() => _remotePaths.Values.Where(path => path != RootRemotePath())
            .Any(path => !CloudFileRenamePaths.HasExactLeafName(LocalPath(path)));

        private string RelocationTarget(string source, string targetLocal)
        {
            CloudDriveWriteScope.RequireWritable(mapping, source);
            if (!Path.GetFullPath(targetLocal).StartsWith(Path.GetFullPath(localRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("cloud.relocate.outside_mapping");
            var parentLocal = Path.GetDirectoryName(targetLocal)!;
            var parentRemote = string.Equals(parentLocal, localRoot, StringComparison.OrdinalIgnoreCase) ? RootRemotePath() :
                _localRemotePaths.GetValueOrDefault(parentLocal) ?? throw new InvalidDataException("cloud.relocate.parent_unknown");
            // 普通文件转换前也检查父目录，不能沿着未知链接将身份写到映射外。
            for (var parent = parentLocal; !string.Equals(parent, localRoot, StringComparison.OrdinalIgnoreCase); parent = Path.GetDirectoryName(parent)!)
            {
                var remote = _localRemotePaths.GetValueOrDefault(parent) ?? throw new InvalidDataException("cloud.relocate.parent_unknown");
                if ((File.GetAttributes(parent) & FileAttributes.ReparsePoint) != 0 && CloudFilePlaceholderNative.ReadIdentity(parent) != ItemIdentity(remote))
                    throw new InvalidDataException("cloud.relocate.local_unverified");
            }
            var name = Path.GetFileName(targetLocal);
            var remoteName = name == Path.GetFileName(LocalPath(source)) ? source[(source.LastIndexOf('/') + 1)..] : name;
            var target = parentRemote.TrimEnd('/') + "/" + remoteName;
            CloudDriveWriteScope.RequireWritable(mapping, target);
            return target;
        }

        private Task BindObservedLocalMoveAsync(string sourceLocal, string targetLocal, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            if (!_writebackEnabled || !_localRemotePaths.TryGetValue(sourceLocal, out var source) ||
                !File.Exists(targetLocal) || Directory.Exists(targetLocal)) return Task.CompletedTask;
            if (!string.Equals(sourceLocal, targetLocal, StringComparison.OrdinalIgnoreCase) &&
                (File.Exists(sourceLocal) || Directory.Exists(sourceLocal))) return Task.CompletedTask;
            var target = RelocationTarget(source, targetLocal);
            if (target == source) return Task.CompletedTask;
            if (_remotePaths.Values.Any(path => path == target)) throw new InvalidDataException("cloud.relocate.destination_exists");
            CloudFilePlaceholderNative.BindRenamedLocalFile(targetLocal, ItemIdentity(source));
            return Task.CompletedTask;
        }

        private async Task<string?> ResolveWritebackPathAsync(string physical, CancellationToken token)
        {
            var known = _localRemotePaths.GetValueOrDefault(physical);
            if ((File.GetAttributes(physical) & FileAttributes.ReparsePoint) == 0) return known;
            var identity = CloudFilePlaceholderNative.ReadIdentity(physical);
            if (!_remotePaths.TryGetValue(identity, out var source)) throw new InvalidDataException("cloud.sync.unindexed_placeholder");
            var expectedLocal = LocalPath(source);
            if (string.Equals(expectedLocal, physical, StringComparison.OrdinalIgnoreCase) && CloudFileRenamePaths.HasExactLeafName(expectedLocal)) return source;
            if (!string.Equals(expectedLocal, physical, StringComparison.OrdinalIgnoreCase) && (File.Exists(expectedLocal) || Directory.Exists(expectedLocal)))
                throw new InvalidDataException("cloud.relocate.local_unverified");
            var target = RelocationTarget(source, physical);
            var directory = Directory.Exists(physical);
            var operation = (await _syncStore.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false))
                .SingleOrDefault(item => item.IsPending && item.ItemIdentity == identity);
            if (operation is not null && (operation.Source != source || operation.Destination != target || operation.IsDirectory != directory))
                throw new InvalidOperationException("cloud.relocate.pending");
            operation ??= await new CloudDriveRelocationCoordinator(mapping, repository, _syncStore).StartAsync(identity, source, target,
                Path.GetFileName(physical), true, token, expectedDirectory: directory).ConfigureAwait(false);
            if (operation.Phase != CloudDriveRelocationPhase.ServerVerified) throw new InvalidOperationException("cloud.relocate.pending");
            await CompleteRelocationAsync(operation, false, token).ConfigureAwait(false);
            return target;
        }

        private async Task RecordDeletedLocalPathAsync(string physical, CancellationToken token)
        {
            if (!_deletionEnabled || !_localRemotePaths.TryGetValue(physical, out var path) || File.Exists(physical) || Directory.Exists(physical)) return;
            var identity = ItemIdentity(path);
            if ((await _syncStore.ReadDeletionOperationsAsync(mapping, token).ConfigureAwait(false)).Any(item => item.ItemIdentity == identity && item.Phase != CloudDriveDeletionPhase.Abandoned) ||
                (await _syncStore.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).Any(item => item.IsPending &&
                    (DesktopDrivePath.IsAncestorOrSame(item.Source, path) || DesktopDrivePath.IsAncestorOrSame(item.Destination, path)))) return;
            await new CloudDriveDeletionCoordinator(mapping, repository, _syncStore).PrepareAsync(identity, path, token).ConfigureAwait(false);
            await ReportWritebackStateAsync(new InvalidOperationException("cloud.delete.confirmation_pending")).ConfigureAwait(false);
        }

        private async Task ReportWritebackStateAsync(Exception? error)
        {
            if (_refreshLifetime.IsCancellationRequested) return;
            try
            {
                var state = await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false);
                if (error is not null)
                {
                    state = state with { State = DesktopDriveMappingState.Degraded };
                    await store.SaveRuntimeAsync(mapping.Id, state).ConfigureAwait(false);
                }
                runtimeChanged(state);
            }
            catch { /* 状态通知失败不改变上传日志，也不把未知提交重置为未发送。 */ }
        }

        internal void NotifyWriteback(string remotePath) => _writebackSession?.NotifyChanged(LocalPath(remotePath));

        internal async Task ConfigureDeletionAsync(bool enabled, bool confirmed, CancellationToken token)
        {
            if (enabled && (repository is not IFileRecycleRepository recycle || recycle.ProfileId != mapping.ProfileId ||
                !recycle.Availability.CanMoveToRecycle || recycle.Availability.DeleteVersion != 2)) throw new NotSupportedException("cloud.delete.unsupported");
            await _syncStore.SetDeletionEnabledAsync(mapping, enabled, confirmed, token).ConfigureAwait(false);
            _deletionEnabled = enabled;
        }

        internal async Task CompleteDeletionAsync(CloudDriveDeletionOperation operation, CancellationToken token)
        {
            var completion = new CloudDriveDeletionCompletion(mapping, _syncStore, store, (tree, cancellation) =>
            {
                foreach (var item in tree.OrderByDescending(item => item.Value.Count(character => character == '/')))
                {
                    cancellation.ThrowIfCancellationRequested();
                    var local = LocalPath(item.Value);
                    if (!CloudFilePlaceholderNative.Remove(local, item.Key, Directory.Exists(local), _localRemovals, confirmedDeletion: true))
                        throw new InvalidOperationException("cloud.sync.pending_changes");
                }
                return Task.CompletedTask;
            });
            await completion.CompleteAsync(operation, token).ConfigureAwait(false);
            var paths = await store.LoadItemPathsAsync(mapping.Id).ConfigureAwait(false);
            foreach (var key in _remotePaths.Keys.Where(key => !paths.ContainsKey(key)).ToArray()) _remotePaths.TryRemove(key, out _);
            foreach (var item in _localRemotePaths.Where(item => !paths.Values.Contains(item.Value, StringComparer.Ordinal)).ToArray())
                _localRemotePaths.TryRemove(item.Key, out _);
            _writebackSession?.RequestScan();
            runtimeChanged(await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        }

        internal async Task ValidateLocalDeletionAsync(CloudDriveDeletionOperation operation, CancellationToken token)
        {
            var paths = await store.LoadItemPathsAsync(mapping.Id).ConfigureAwait(false);
            if (!paths.TryGetValue(operation.ItemIdentity, out var source) || source != operation.RemotePath)
                throw new InvalidDataException("cloud.delete.identity_changed");
            var physical = LocalPath(source);
            if (!File.Exists(physical) && !Directory.Exists(physical)) return;
            if (Directory.Exists(physical) != operation.IsDirectory) throw new InvalidDataException("cloud.delete.identity_changed");
            var known = paths.Where(item => DesktopDrivePath.IsAncestorOrSame(source, item.Value))
                .ToDictionary(item => LocalPath(item.Value), item => item.Key, StringComparer.OrdinalIgnoreCase);
            var pending = new Stack<string>(); pending.Push(physical);
            while (pending.TryPop(out var local))
            {
                token.ThrowIfCancellationRequested();
                if (!known.TryGetValue(local, out var identity)) throw new InvalidOperationException("cloud.sync.pending_changes");
                var directory = Directory.Exists(local);
                // 回收站尝试会清除 InSync；先核对 NAS 与原大小，只接纳数据未改变的元数据状态。
                var remote = paths[identity];
                var metadata = await repository.ReadFileMetadataAsync(remote, token).ConfigureAwait(false);
                if (metadata is null || metadata.Item.Path != remote || metadata.Item.IsDirectory != directory)
                    throw new InvalidDataException("cloud.delete.target_changed");
                var baseline = directory ? null : await _syncStore.ReadVersionAsync(mapping, remote, token).ConfigureAwait(false);
                if (baseline is not null && baseline.Length != metadata.Item.Size ||
                    !CloudFilePlaceholderNative.AcknowledgeRelocation(local, identity, directory, metadata.Item.Size))
                    throw new InvalidOperationException("cloud.sync.pending_changes");
                CloudFilePlaceholderNative.RequireSynchronized(local, identity, directory);
                if (directory) foreach (var child in Directory.EnumerateFileSystemEntries(local)) pending.Push(child);
            }
        }

        internal async Task<CloudDriveWritebackPreparation> ConfigureWritebackAsync(bool enabled, bool confirmed, CancellationToken token)
        {
            if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, _refreshLifetime.Token);
            await _writebackConfiguration.WaitAsync(linked.Token).ConfigureAwait(false);
            try
            {
                var paths = _remotePaths.Values.Distinct(StringComparer.Ordinal).Where(path => path != RootRemotePath() && File.Exists(LocalPath(path))).ToArray();
                if (!enabled)
                {
                    // 已绑定原身份但还没取得 NAS 改名预检的目标可能不在旧路径；不能漏过它而关闭写回。
                    if (HasMissingLocalProjection())
                        throw new InvalidOperationException("CloudDriveWritebackPending");
                    var changes = await _syncStore.ReadChangesAsync(mapping, linked.Token).ConfigureAwait(false);
                    if (changes.Any(change => change.IsPending))
                        throw new InvalidOperationException("CloudDriveWritebackPending");
                    // 先逐项恢复只读，再落盘关闭；任何正在编辑或未同步内容都会保留启用状态。
                    foreach (var path in paths)
                    {
                        linked.Token.ThrowIfCancellationRequested();
                        var identity = ItemIdentity(path);
                        if (changes.LastOrDefault(change => change.RemotePath == path)?.Phase == CloudDriveChangePhase.KeptLocally)
                            CloudFilePlaceholderNative.PreserveLocallyReadOnly(LocalPath(path), identity);
                        else CloudFilePlaceholderNative.SetWritable(LocalPath(path), identity, false);
                    }
                    await _syncStore.SetWritebackEnabledAsync(mapping, false, true, linked.Token).ConfigureAwait(false);
                    _writebackEnabled = false;
                    _deletionEnabled = false;
                    if (_writebackSession is { } session) { await session.DisposeAsync().ConfigureAwait(false); _writebackSession = null; }
                    return new(paths.Length, 0);
                }
                await _syncStore.SetWritebackEnabledAsync(mapping, true, true, linked.Token).ConfigureAwait(false);
                await StartWritebackAsync().ConfigureAwait(false);
                var ready = 0; var unavailable = 0;
                foreach (var path in paths)
                {
                    linked.Token.ThrowIfCancellationRequested();
                    try { await PrepareEditableFileCoreAsync(path, linked.Token).ConfigureAwait(false); ready++; }
                    catch (OperationCanceledException) when (linked.IsCancellationRequested) { throw; }
                    catch { unavailable++; }
                }
                return new(ready, unavailable);
            }
            finally { _writebackConfiguration.Release(); }
        }

        private async Task PrepareEditableFileAsync(string path, CancellationToken token)
        {
            await _writebackConfiguration.WaitAsync(token).ConfigureAwait(false);
            try { if (_writebackEnabled) await PrepareEditableFileCoreAsync(path, token).ConfigureAwait(false); }
            finally { _writebackConfiguration.Release(); }
        }

        private async Task PrepareEditableFileCoreAsync(string path, CancellationToken token)
        {
            var gate = _rangeTransferGates.GetOrAdd(path, static _ => new SemaphoreSlim(1, 1));
            await gate.WaitAsync(token).ConfigureAwait(false);
            try
            {
                var local = LocalPath(path);
                var state = ReadPlaceholderState(path);
                if (state.ModifiedDataSize != 0 || state.InSyncState != 1) throw new InvalidDataException("cloud.sync.pending_changes");
                if (state.OnDiskDataSize < new FileInfo(local).Length) throw new InvalidDataException("cloud.writeback.open_first");
                var known = await _syncStore.ReadVersionAsync(mapping, path, token).ConfigureAwait(false);
                var candidate = await new CloudDriveWritebackCoordinator(mapping, repository, _syncStore).ReadEditableCandidateAsync(path, token).ConfigureAwait(false)
                    ?? throw new FileNotFoundException();
                if (new FileInfo(local).Length != candidate.Item.Size) throw new InvalidDataException("cloud.sync.version_conflict");
                if (candidate.Version is { } version)
                {
                    if (known is null && state.OnDiskDataSize == 0) await _syncStore.BindVersionAsync(mapping, version, token).ConfigureAwait(false);
                    else if (known != version) throw new InvalidDataException("cloud.sync.version_conflict");
                }
                else
                {
                    if (candidate.Item.ModifiedAt is not { } time) throw new InvalidDataException("cloud.sync.baseline_missing");
                    await _syncStore.BindEmptyFileBaselineAsync(mapping, path, time, token).ConfigureAwait(false);
                }
                token.ThrowIfCancellationRequested();
                CloudFilePlaceholderNative.SetWritable(local, ItemIdentity(path), true);
            }
            finally { gate.Release(); }
        }

        private static void OnFetchData(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                var parameters = Marshal.PtrToStructure<FetchDataCallbackParameters>(
                    parametersPointer);
                var remotePath = runtime.RemotePath(
                    CopyIdentity(info.FileIdentity, info.FileIdentityLength));
                if (!runtime.TryBeginCallback())
                {
                    TryFailOperation(info, CloudFilesInterop.OperationTransferData);
                    return;
                }
                var connectionKey = info.ConnectionKey;
                var transferKey = info.TransferKey;
                var requestKey = info.RequestKey;
                var fileSize = info.FileSize;
                var fileId = info.FileId;
                var syncRootFileId = info.SyncRootFileId;
                _ = runtime.RunCallbackAsync(() => runtime.TransferDataAsync(
                        connectionKey,
                        transferKey,
                        requestKey,
                        remotePath,
                        parameters.RequiredFileOffset,
                        parameters.RequiredLength,
                        fileSize,
                        fileId,
                        syncRootFileId));
            }
            catch
            {
                TryFailOperation(info, CloudFilesInterop.OperationTransferData);
            }
        }

        private static void OnFetchPlaceholders(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                var remotePath = info.FileIdentity != IntPtr.Zero &&
                                 info.FileIdentityLength > 0
                    ? runtime.RemotePath(
                        CopyIdentity(info.FileIdentity, info.FileIdentityLength))
                    : runtime.Mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                        ? "/"
                        : runtime.Mapping.Scope.FolderPath ?? "/";
                if (!runtime.TryBeginCallback())
                {
                    TryFailOperation(
                        info,
                        CloudFilesInterop.OperationTransferPlaceholders);
                    return;
                }
                var connectionKey = info.ConnectionKey;
                var transferKey = info.TransferKey;
                var requestKey = info.RequestKey;
                _ = runtime.RunCallbackAsync(() => runtime.TransferPlaceholdersAsync(
                        connectionKey,
                        transferKey,
                        requestKey,
                        remotePath));
            }
            catch
            {
                TryFailOperation(info, CloudFilesInterop.OperationTransferPlaceholders);
            }
        }

        private static void OnCancel(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                if (runtime._requestCancellations.TryGetValue(
                    info.RequestKey.Value,
                    out var request))
                {
                    var parameters =
                        Marshal.PtrToStructure<CancelFetchDataCallbackParameters>(
                            parametersPointer);
                    if (CloudFileCancelRange.CoversOutstandingRange(
                            request.Offset,
                            request.Length,
                            parameters.FileOffset,
                            parameters.Length))
                    {
                        request.Cancellation.Cancel();
                    }
                }
                else if (runtime._placeholderRequestCancellations.TryGetValue(
                             info.RequestKey.Value,
                             out var placeholderCancellation))
                {
                    placeholderCancellation.Cancel();
                }
            }
            catch
            {
                // 取消通知不能让异常越过原生边界。
            }
        }

        private static void OnFileOpened(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer)
        {
            try
            {
                if (info.FileIdentity == IntPtr.Zero ||
                    info.FileIdentityLength == 0)
                {
                    return;
                }
                var runtime = FromContext(info.CallbackContext);
                var remotePath = runtime.RemotePath(
                    CopyIdentity(info.FileIdentity, info.FileIdentityLength));
                if (!runtime.TryBeginCallback())
                {
                    return;
                }
                _ = runtime.RunCallbackAsync(
                    () => runtime.RecordAccessAsync(remotePath));
            }
            catch
            {
                // 打开通知只用于更新缓存排序，失败不影响文件访问。
            }
        }

        private static void OnFileClosed(in CloudFilesInterop.CallbackInfo info, IntPtr parametersPointer)
        {
            try
            {
                if (info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0 ||
                    info.ProcessInfo != IntPtr.Zero && Marshal.ReadInt32(info.ProcessInfo) >= 8 &&
                    Marshal.ReadInt32(info.ProcessInfo, 4) == Environment.ProcessId) return;
                var runtime = FromContext(info.CallbackContext);
                if (!runtime._writebackEnabled) return;
                var path = runtime.RemotePath(CopyIdentity(info.FileIdentity, info.FileIdentityLength));
                if (!runtime.TryBeginCallback()) return;
                _ = runtime.RunCallbackAsync(async () =>
                {
                    try
                    {
                        if ((await runtime._syncStore.ReadRelocationOperationsAsync(runtime.Mapping, runtime._refreshLifetime.Token).ConfigureAwait(false))
                            .Any(item => item.IsPending && item.ItemIdentity == runtime.ItemIdentity(path))) return;
                        if (!File.Exists(runtime.LocalPath(path))) return;
                        runtime.NotifyWriteback(path);
                        if (!CloudFilePlaceholderNative.IsModified(runtime.LocalPath(path), runtime.ItemIdentity(path)))
                            await runtime.PrepareEditableFileAsync(path, runtime._refreshLifetime.Token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (runtime._refreshLifetime.IsCancellationRequested) { }
                    catch (Exception error) { await runtime.ReportWritebackStateAsync(error).ConfigureAwait(false); }
                });
            }
            catch { /* 关闭通知不阻塞用户应用，异常不能越过原生边界。 */ }
        }

        private static void OnRejectDelete(in CloudFilesInterop.CallbackInfo info, IntPtr parametersPointer)
        {
            try
            {
                var request = CloudFilePlaceholderNative.ReadDeleteRequest(parametersPointer);
                if (request.Undelete) { RejectMutation(info, CloudFilesInterop.OperationAckDelete); return; }
                var runtime = FromContext(info.CallbackContext);
                if (runtime._localRemovals.TryConsume(info)) { RejectMutation(info, CloudFilesInterop.OperationAckDelete, true); return; }
                if (!runtime._writebackEnabled || !runtime._deletionEnabled || info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0)
                { RejectMutation(info, CloudFilesInterop.OperationAckDelete); return; }
                var identity = CopyIdentity(info.FileIdentity, info.FileIdentityLength);
                var path = runtime.RemotePath(identity);
                if (request.Directory != Directory.Exists(runtime.LocalPath(path))) { RejectMutation(info, CloudFilesInterop.OperationAckDelete); return; }
                var state = runtime.ReadPlaceholderState(path, request.Directory);
                if (state.FileId != info.FileId || state.SyncRootFileId != info.SyncRootFileId || state.ModifiedDataSize != 0 || !runtime.TryBeginCallback())
                { RejectMutation(info, CloudFilesInterop.OperationAckDelete); return; }
                // 先保留本机文件。此通知只登记待确认项，用户在同步恢复窗口确认后才删除 NAS。
                RejectMutation(info, CloudFilesInterop.OperationAckDelete);
                _ = runtime.RunCallbackAsync(async () =>
                {
                    try
                    {
                        var operations = await runtime._syncStore.ReadDeletionOperationsAsync(runtime.Mapping, runtime._refreshLifetime.Token).ConfigureAwait(false);
                        if (!operations.Any(item => item.IsPending && item.ItemIdentity == identity))
                            await new CloudDriveDeletionCoordinator(runtime.Mapping, runtime.repository, runtime._syncStore)
                                .PrepareAsync(identity, path, runtime._refreshLifetime.Token).ConfigureAwait(false);
                        await runtime.ReportWritebackStateAsync(new InvalidOperationException("cloud.delete.confirmation_pending")).ConfigureAwait(false);
                    }
                    catch (Exception error) { await runtime.ReportWritebackStateAsync(error).ConfigureAwait(false); }
                });
            }
            catch { RejectMutation(info, CloudFilesInterop.OperationAckDelete); }
        }

        private static void OnRenameRequested(in CloudFilesInterop.CallbackInfo info, IntPtr parametersPointer)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                if (!runtime._writebackEnabled || info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0)
                { RejectMutation(info, CloudFilesInterop.OperationAckRename); return; }
                var request = CloudFileRenamePaths.Read(info, parametersPointer, runtime.localRoot);
                var identity = CopyIdentity(info.FileIdentity, info.FileIdentityLength);
                var source = runtime.RemotePath(identity);
                var state = runtime.ReadPlaceholderState(source, request.Directory);
                if (state.FileId != info.FileId || state.SyncRootFileId != info.SyncRootFileId || !runtime.TryBeginCallback())
                { RejectMutation(info, CloudFilesInterop.OperationAckRename); return; }
                var copied = info;
                _ = runtime.RunCallbackAsync(() => runtime.RequestRelocationAsync(copied, identity, source, request.Target, request.Directory));
            }
            catch { RejectMutation(info, CloudFilesInterop.OperationAckRename); }
        }

        private async Task RequestRelocationAsync(CloudFilesInterop.CallbackInfo info, string identity, string source,
            string targetLocal, bool directory)
        {
            var allowed = false;
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_refreshLifetime.Token);
            cancellation.CancelAfter(TimeSpan.FromSeconds(50));
            try
            {
                var sourceLocal = LocalPath(source);
                var localName = Path.GetFileName(targetLocal);
                var target = RelocationTarget(source, targetLocal);
                if (!string.Equals(sourceLocal, targetLocal, StringComparison.OrdinalIgnoreCase) && (File.Exists(targetLocal) || Directory.Exists(targetLocal)))
                    throw new InvalidDataException("cloud.relocate.destination_exists");
                var existing = (await _syncStore.ReadRelocationOperationsAsync(mapping, cancellation.Token).ConfigureAwait(false))
                    .SingleOrDefault(item => item.IsPending && item.ItemIdentity == identity);
                var coordinator = new CloudDriveRelocationCoordinator(mapping, repository, _syncStore);
                CloudDriveRelocationOperation result;
                if (existing is not null)
                {
                    if (existing.Source != source || existing.Destination != target || existing.LocalName != localName || existing.IsDirectory != directory)
                        throw new InvalidOperationException("cloud.relocate.pending");
                    result = existing.Phase == CloudDriveRelocationPhase.ServerVerified ? existing :
                        await coordinator.ContinueAsync(existing, true, cancellation.Token).ConfigureAwait(false);
                }
                else result = await coordinator.StartAsync(identity, source, target, localName, true, cancellation.Token, expectedDirectory: directory).ConfigureAwait(false);
                allowed = result.Phase == CloudDriveRelocationPhase.ServerVerified && !cancellation.IsCancellationRequested;
                if (!allowed) await ReportWritebackStateAsync(new IOException("cloud.relocate.pending")).ConfigureAwait(false);
            }
            catch (Exception error) { await ReportWritebackStateAsync(error).ConfigureAwait(false); }
            finally { RejectMutation(info, CloudFilesInterop.OperationAckRename, allowed); }
        }

        private static void OnRenameCompleted(in CloudFilesInterop.CallbackInfo info, IntPtr parametersPointer)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                if (info.FileIdentity == IntPtr.Zero || info.FileIdentityLength == 0) return;
                var identity = CopyIdentity(info.FileIdentity, info.FileIdentityLength);
                if (!runtime.TryBeginCallback()) return;
                _ = runtime.RunCallbackAsync(async () =>
                {
                    try
                    {
                        var operation = (await runtime._syncStore.ReadRelocationOperationsAsync(runtime.Mapping, runtime._refreshLifetime.Token).ConfigureAwait(false))
                            .SingleOrDefault(item => item.ItemIdentity == identity && item.Phase == CloudDriveRelocationPhase.ServerVerified);
                        if (operation is not null) await runtime.CompleteRelocationAsync(operation, false, runtime._refreshLifetime.Token).ConfigureAwait(false);
                    }
                    catch (Exception error) { await runtime.ReportWritebackStateAsync(error).ConfigureAwait(false); }
                });
            }
            catch { /* 完成通知不回应内核，但未完成的日志继续留给恢复入口。 */ }
        }

        internal async Task RestoreLocalBeforeAbandonAsync(CloudDriveRelocationOperation operation, CancellationToken token)
        {
            if (operation.Step != 0 || operation.Phase is not (CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.Rejected))
                throw new InvalidOperationException("cloud.relocate.result_unknown");
            using var writeback = await _syncStore.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
            var current = (await _syncStore.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == operation.Id);
            if (current is null || !DesktopCloudDriveSyncStore.SameOperation(current, operation)) throw new InvalidOperationException("cloud.relocate.state_changed");
            var parent = operation.Destination[..Math.Max(1, operation.Destination.LastIndexOf('/'))];
            var target = Path.Combine(LocalPath(parent), operation.LocalName);
            CloudFileRenamePaths.CompleteLocalMove(target, LocalPath(operation.Source), operation.IsDirectory, true,
                path => VerifyLocalRelocationItem(path, operation));
        }

        internal async Task CompleteRelocationAsync(CloudDriveRelocationOperation operation, bool moveLocal, CancellationToken token)
        {
            await _relocationCompletion.WaitAsync(token).ConfigureAwait(false);
            try
            {
                var current = (await _syncStore.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == operation.Id);
                if (current is null || !DesktopCloudDriveSyncStore.SameOperation(current, operation) || operation.Phase != CloudDriveRelocationPhase.ServerVerified)
                    throw new InvalidOperationException("cloud.relocate.result_unknown");
                var parent = operation.Destination[..Math.Max(1, operation.Destination.LastIndexOf('/'))];
                var target = Path.Combine(LocalPath(parent), operation.LocalName);
                CloudFileRenamePaths.CompleteLocalMove(LocalPath(operation.Source), target, operation.IsDirectory, moveLocal,
                    path => VerifyLocalRelocationItem(path, operation));
                _ = CloudFilePlaceholderNative.AcknowledgeRelocation(target, operation.ItemIdentity, operation.IsDirectory, operation.Length);
                var completion = new CloudDriveRelocationCompletion(mapping, _syncStore, store, item =>
                {
                    if (!CloudFileRenamePaths.HasExactLeafName(target)) return false;
                    VerifyLocalRelocationItem(target, item); return true;
                });
                await completion.CompleteAsync(operation.Id, token).ConfigureAwait(false);
                var paths = await store.LoadItemPathsAsync(mapping.Id).ConfigureAwait(false);
                var names = await _syncStore.RegisterLocalNamesAsync(mapping, new Dictionary<string, string>(), paths.Values, token).ConfigureAwait(false);
                foreach (var item in names) _safeSegments[item.Key] = item.Value;
                foreach (var key in _safeSegments.Keys.Where(key => !names.ContainsKey(key)).ToArray()) _safeSegments.TryRemove(key, out _);
                foreach (var item in paths) _remotePaths[item.Key] = item.Value;
                foreach (var key in _remotePaths.Keys.Where(key => !paths.ContainsKey(key)).ToArray()) _remotePaths.TryRemove(key, out _);
                _localRemotePaths.Clear();
                foreach (var path in paths.Values.Where(path => path != RootRemotePath())) _localRemotePaths[LocalPath(path)] = path;
                foreach (var path in paths.Values.Where(path => DesktopDrivePath.IsAncestorOrSame(operation.Destination, path))) NotifyWriteback(path);
                _writebackSession?.RequestScan();
                runtimeChanged(await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
            }
            finally { _relocationCompletion.Release(); }
        }

        private static void VerifyLocalRelocationItem(string path, CloudDriveRelocationOperation operation)
        {
            if (Directory.Exists(path) != operation.IsDirectory) throw new InvalidDataException("cloud.relocate.local_unverified");
            using var handle = CloudFilesInterop.CreateFile(path, 0x80, CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero,
                CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint | (operation.IsDirectory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
            if (handle.IsInvalid) throw new IOException("cloud.relocate.local_unavailable");
            _ = CloudFilePlaceholderNative.Read(handle, operation.ItemIdentity);
        }

        private static void RejectMutationWithLifetime(
            CloudFilesInterop.CallbackInfo info,
            uint operationType)
        {
            try
            {
                var runtime = FromContext(info.CallbackContext);
                if (!runtime.TryBeginCallback())
                {
                    RejectMutation(info, operationType);
                    return;
                }
                try
                {
                    RejectMutation(info, operationType, operationType == CloudFilesInterop.OperationAckDelete && runtime._localRemovals.TryConsume(info));
                }
                finally
                {
                    runtime.EndCallback();
                }
            }
            catch
            {
                RejectMutation(info, operationType);
            }
        }

        private static void RejectMutation(
            CloudFilesInterop.CallbackInfo info,
            uint operationType,
            bool authorizedLocalRemoval = false)
        {
            try
            {
                var operation = Operation(
                    operationType,
                    info.ConnectionKey,
                    info.TransferKey,
                    info.RequestKey);
                var parameters = new CloudFilesInterop.AcknowledgeParameters
                {
                    ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.AcknowledgeParameters>(),
                    CompletionStatus = authorizedLocalRemoval ? CloudFilesInterop.StatusSuccess : CloudFilesInterop.StatusAccessDenied,
                };
                Execute(operation, parameters);
            }
            catch
            {
                // 回调不能让异常越过原生边界。
            }
        }

        private bool TryBeginCallback()
        {
            lock (_callbackGate)
            {
                if (!_acceptingCallbacks)
                {
                    return false;
                }
                _activeCallbacks++;
                return true;
            }
        }

        private async Task RunCallbackAsync(Func<Task> operation)
        {
            try
            {
                await operation().ConfigureAwait(false);
            }
            finally
            {
                EndCallback();
            }
        }

        private void EndCallback()
        {
            lock (_callbackGate)
            {
                _activeCallbacks--;
                if (!_acceptingCallbacks && _activeCallbacks == 0)
                {
                    _callbacksDrained?.TrySetResult();
                }
            }
        }

        internal Task StopAcceptingCallbacksAsync()
        {
            lock (_callbackGate)
            {
                _acceptingCallbacks = false;
                _refreshLifetime.Cancel();
                foreach (var cancellation in _requestCancellations.Values)
                {
                    cancellation.Cancellation.Cancel();
                }
                foreach (var cancellation in
                         _placeholderRequestCancellations.Values)
                {
                    cancellation.Cancel();
                }
                if (_activeCallbacks == 0)
                {
                    return _writebackSession?.DisposeAsync().AsTask() ?? Task.CompletedTask;
                }
                _callbacksDrained ??= new(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                return Task.WhenAll(_callbacksDrained.Task, _writebackSession?.DisposeAsync().AsTask() ?? Task.CompletedTask);
            }
        }

        private static void TryFailOperation(
            CloudFilesInterop.CallbackInfo info,
            uint operationType)
        {
            try
            {
                var operation = Operation(
                    operationType,
                    info.ConnectionKey,
                    info.TransferKey,
                    info.RequestKey);
                if (operationType == CloudFilesInterop.OperationTransferData)
                {
                    ExecuteTransferData(
                        operation,
                        IntPtr.Zero,
                        0,
                        0,
                        CloudFilesInterop.StatusUnsuccessful);
                }
                else
                {
                    Execute(
                        operation,
                        new CloudFilesInterop.TransferPlaceholdersParameters
                        {
                            ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(),
                            CompletionStatus = CloudFilesInterop.StatusUnsuccessful,
                        });
                }
            }
            catch
            {
                // 回调不能让异常越过原生边界。
            }
        }

        private async Task TransferDataAsync(
            CloudFilesInterop.ConnectionKey connectionKey,
            CloudFilesInterop.TransferKey transferKey,
            CloudFilesInterop.RequestKey requestKey,
            string remotePath,
            long offset,
            long length,
            long fileSize,
            long fileId,
            long syncRootFileId)
        {
            var operation = Operation(
                CloudFilesInterop.OperationTransferData,
                connectionKey,
                transferKey,
                requestKey);
            var transferLength = length == -1 &&
                                 offset >= 0 &&
                                 offset <= fileSize
                ? fileSize - offset
                : length;
            using var cancellation = new CancellationTokenSource();
            _requestCancellations[requestKey.Value] = new(
                cancellation,
                offset,
                transferLength);
            var transferGate = _rangeTransferGates.GetOrAdd(
                remotePath,
                static _ => new SemaphoreSlim(1, 1));
            var enteredTransferGate = false;
            try
            {
                (offset, transferLength) = CloudFileHydrationGuard.AlignRange(offset, transferLength, fileSize);
                EnsureFreeSpace(transferLength);
                await transferGate.WaitAsync(cancellation.Token)
                    .ConfigureAwait(false);
                enteredTransferGate = true;
                var knownVersion = await _syncStore.ReadVersionAsync(mapping, remotePath, cancellation.Token).ConfigureAwait(false);
                var placeholder = ReadPlaceholderState(remotePath);
                CloudFileHydrationGuard.Validate(placeholder, fileId, syncRootFileId, knownVersion, fileSize);
                var outcome = await CloudFileRangeTransfer.ExecuteAsync(
                    remotePath,
                    offset,
                    transferLength,
                    fileSize,
                    DownloadChunkBytes,
                    knownVersion?.Version,
                    knownVersion?.Length,
                    (requestOffset,
                        requestLength,
                        expectedContentVersion,
                        expectedTotalLength,
                        token) => repository.ReadFileRangeResultAsync(
                            remotePath,
                            requestOffset,
                            requestLength,
                            expectedContentVersion,
                            expectedTotalLength,
                            token),
                    (chunkOffset, data) =>
                    {
                        var handle = GCHandle.Alloc(data, GCHandleType.Pinned);
                        try
                        {
                            ExecuteTransferData(
                                operation,
                                handle.AddrOfPinnedObject(),
                                chunkOffset,
                                data.LongLength,
                                CloudFilesInterop.StatusSuccess);
                        }
                        finally
                        {
                            handle.Free();
                        }
                    },
                    (failureOffset, failureLength) => ExecuteTransferData(
                        operation,
                        IntPtr.Zero,
                        failureOffset,
                        failureLength,
                        CloudFilesInterop.StatusUnsuccessful),
                    cancellation.Token,
                    (version, total, token) => _syncStore.BindVersionAsync(mapping,
                        new(remotePath, version, total), token)).ConfigureAwait(false);
                if (outcome.Succeeded)
                {
                    try
                    {
                        await RecordCacheEntryAsync(remotePath, fileSize)
                            .ConfigureAwait(false);
                    }
                    catch
                    {
                        // 缓存统计失败不能把已完成的数据传输改写为第二个失败终态。
                    }
                }
            }
            catch (InsufficientLocalSpaceException)
            {
                ExecuteTransferData(
                    operation,
                    IntPtr.Zero,
                    offset,
                    transferLength,
                    CloudFilesInterop.StatusDiskFull);
            }
            catch
            {
                ExecuteTransferData(
                    operation,
                    IntPtr.Zero,
                    offset,
                    transferLength,
                    CloudFilesInterop.StatusUnsuccessful);
            }
            finally
            {
                if (enteredTransferGate)
                {
                    transferGate.Release();
                }
                _requestCancellations.TryRemove(requestKey.Value, out _);
            }
        }

        private async Task RecordAccessAsync(string remotePath)
        {
            var now = DateTimeOffset.UtcNow;
            if (_lastAccessWrites.TryGetValue(remotePath, out var previous) &&
                now - previous < TimeSpan.FromMinutes(1))
            {
                return;
            }
            _lastAccessWrites[remotePath] = now;
            await store.UpdateRuntimeAsync(mapping.Id, current =>
            {
                if (!current.CacheEntries.TryGetValue(remotePath, out var entry))
                {
                    return current;
                }
                var entries = current.CacheEntries.ToDictionary(
                    item => item.Key,
                    item => item.Value,
                    StringComparer.Ordinal);
                entries[remotePath] = entry with
                {
                    LastAccessedAt = now,
                    UpdatedAt = now,
                };
                return current with { CacheEntries = entries };
            }).ConfigureAwait(false);
            runtimeChanged(
                await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        }

        private async Task RecordCacheEntryAsync(
            string remotePath,
            long logicalSizeBytes, bool touch = true)
        {
            var allocated = AllocatedSize(LocalPath(remotePath));
            await store.UpdateRuntimeAsync(mapping.Id, current =>
            {
                var entries = current.CacheEntries.ToDictionary(
                    item => item.Key,
                    item => item.Value,
                    StringComparer.Ordinal);
                entries[remotePath] = new DesktopDriveCacheEntry(
                    remotePath,
                    current.KeepsOffline(remotePath)
                        ? DesktopDriveCacheEntryKind.KeptOffline
                        : DesktopDriveCacheEntryKind.Temporary,
                    Math.Max(logicalSizeBytes, 0),
                    allocated,
                    touch ? DateTimeOffset.UtcNow : current.CacheEntries.GetValueOrDefault(remotePath)?.LastAccessedAt ?? DateTimeOffset.UtcNow,
                    DateTimeOffset.UtcNow);
                return current with { CacheEntries = entries };
            }).ConfigureAwait(false);
            var current = await store.LoadRuntimeAsync(mapping.Id)
                .ConfigureAwait(false);
            runtimeChanged(current);
            await EnforceTemporaryLimitAsync(current).ConfigureAwait(false);
        }

        internal async Task EnforceTemporaryLimitAsync(
            DesktopDriveMappingRuntime state,
            long? limitBytes = null)
        {
            var paths = DesktopDriveCacheEvictionPlanner.TemporaryPathsToEvict(
                state.CacheEntries.Values,
                limitBytes ?? mapping.CachePolicy.TemporaryLimitBytes);
            if (paths.Count == 0)
            {
                return;
            }
            var released = Dehydrate(paths);
            if (released.Count == 0)
            {
                return;
            }
            await store.ApplyCacheReleaseAsync(mapping.Id, state, released).ConfigureAwait(false);
            runtimeChanged(
                await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
        }

        internal IReadOnlyList<string> Dehydrate(
            IEnumerable<string> remotePaths)
        {
            var released = new List<string>();
            foreach (var remotePath in remotePaths)
            {
                var localPath = LocalPath(remotePath);
                try { _ = File.GetAttributes(localPath); }
                catch (FileNotFoundException) { released.Add(remotePath); continue; }
                catch (DirectoryNotFoundException) { released.Add(remotePath); continue; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { continue; }
                try { if (CloudFilePlaceholderNative.ReleaseCachedContent(localPath, ItemIdentity(remotePath))) released.Add(remotePath); }
                catch (Exception error) when (error is IOException or InvalidDataException or ExternalException) { /* 保留失败项，调用方报告部分释放。 */ }
            }
            return released;
        }

        private static long AllocatedSize(string path)
        {
            Marshal.SetLastPInvokeError(0);
            var low = CloudFilesInterop.GetCompressedFileSize(path, out var high);
            if (low == uint.MaxValue && Marshal.GetLastWin32Error() != 0)
            {
                return 0;
            }
            return ((long)high << 32) + low;
        }

        internal long AllocatedSizeFor(string remotePath) =>
            AllocatedSize(LocalPath(remotePath));

        private async Task TransferPlaceholdersAsync(
            CloudFilesInterop.ConnectionKey connectionKey,
            CloudFilesInterop.TransferKey transferKey,
            CloudFilesInterop.RequestKey requestKey,
            string remotePath)
        {
            var operation = Operation(
                CloudFilesInterop.OperationTransferPlaceholders,
                connectionKey,
                transferKey,
                requestKey);
            var allocations = new List<IntPtr>();
            using var cancellation = new CancellationTokenSource();
            _placeholderRequestCancellations[requestKey.Value] = cancellation;
            try
            {
                var listPath =
                    remotePath == "/" && mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                        ? string.Empty
                        : remotePath;
                var directory = await CloudDriveRemoteRefresh.ReadDirectoryAsync(remotePath,
                    (offset, token) => repository.ListFilesAsync(listPath, offset, 500, token), cancellation.Token).ConfigureAwait(false);
                var allItems = directory.Values.ToList();
                await RegisterPathsAsync(allItems.Select(item => item.Path), cancellation.Token)
                    .ConfigureAwait(false);
                cancellation.Token.ThrowIfCancellationRequested();

                if (allItems.Count == 0)
                {
                    Execute(
                        operation,
                        new CloudFilesInterop.TransferPlaceholdersParameters
                        {
                            ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(),
                            CompletionStatus = CloudFilesInterop.StatusSuccess,
                            PlaceholderTotalCount = 0,
                            Flags = CloudFilesInterop.TransferPlaceholdersComplete,
                        });
                }
                foreach (var batch in allItems.Chunk(500))
                {
                    var placeholders = batch.Select(item =>
                        CreatePlaceholder(item, allocations)).ToArray();
                    var arrayPointer = AllocateStructureArray(placeholders);
                    allocations.Add(arrayPointer);
                    var parameters = new CloudFilesInterop.TransferPlaceholdersParameters
                    {
                        ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(),
                        CompletionStatus = CloudFilesInterop.StatusSuccess,
                        PlaceholderTotalCount = allItems.Count,
                        Flags = CloudFilesInterop.TransferPlaceholdersComplete,
                        PlaceholderArray = arrayPointer,
                        PlaceholderCount = (uint)placeholders.Length,
                    };
                    Execute(operation, parameters);
                }
                if (_writebackEnabled)
                    foreach (var item in allItems.Where(item => !item.IsDirectory))
                    {
                        try { await PrepareEditableFileAsync(item.Path, cancellation.Token).ConfigureAwait(false); }
                        catch (Exception error) { await ReportWritebackStateAsync(error).ConfigureAwait(false); }
                    }
            }
            catch
            {
                var parameters = new CloudFilesInterop.TransferPlaceholdersParameters
                {
                    ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(),
                    CompletionStatus = CloudFilesInterop.StatusUnsuccessful,
                };
                Execute(operation, parameters);
            }
            finally
            {
                _placeholderRequestCancellations.TryRemove(
                    requestKey.Value,
                    out _);
                foreach (var allocation in allocations)
                {
                    Marshal.FreeHGlobal(allocation);
                }
            }
        }

        private CloudFilesInterop.PlaceholderCreateInfo CreatePlaceholder(
            FileItem item,
            List<IntPtr> allocations)
        {
            var fileName = _safeSegments.GetValueOrDefault(item.Path)
                ?? DesktopDriveWindowsNameCodec.EscapeSegment(item.Name);
            var namePointer = Marshal.StringToHGlobalUni(fileName);
            allocations.Add(namePointer);
            var identityValue = ItemIdentity(item.Path);
            var identity = Encoding.UTF8.GetBytes(identityValue);
            var identityPointer = Marshal.AllocHGlobal(identity.Length);
            Marshal.Copy(identity, 0, identityPointer, identity.Length);
            allocations.Add(identityPointer);
            var timestamp = item.ModifiedAt?.UtcDateTime.ToFileTimeUtc() ?? 0;
            return new CloudFilesInterop.PlaceholderCreateInfo
            {
                RelativeFileName = namePointer,
                FileSystemMetadata = new()
                {
                    BasicInfo = new()
                    {
                        CreationTime = timestamp,
                        LastAccessTime = timestamp,
                        LastWriteTime = timestamp,
                        ChangeTime = timestamp,
                        FileAttributes = item.IsDirectory ? 0x11u : 0x1u,
                    },
                    FileSize = item.IsDirectory ? 0 : item.Size,
                },
                FileIdentity = identityPointer,
                FileIdentityLength = (uint)identity.Length,
                Flags = CloudFilesInterop.PlaceholderMarkInSync,
            };
        }

        private void EnsureFreeSpace(long requestedBytes)
        {
            var root = Path.GetPathRoot(localRoot)
                ?? throw new InsufficientLocalSpaceException();
            var drive = new DriveInfo(root);
            var decision = DesktopDriveCacheSpaceCalculator.Evaluate(
                [new DesktopDriveCacheCandidate(requestedBytes)],
                drive.TotalSize,
                drive.AvailableFreeSpace,
                0);
            if (decision.Kind != DesktopDriveCacheSpaceDecisionKind.Allowed)
            {
                throw new InsufficientLocalSpaceException();
            }
        }

        private static MappingRuntime FromContext(IntPtr context) =>
            (MappingRuntime)(GCHandle.FromIntPtr(context).Target
                ?? throw new InvalidOperationException());

        private static string CopyIdentity(IntPtr pointer, uint length)
        {
            var bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, checked((int)length));
            return Encoding.UTF8.GetString(bytes);
        }

        private string RemotePath(string identity)
        {
            if (_remotePaths.TryGetValue(identity, out var remotePath))
            {
                return remotePath;
            }
            throw new FileNotFoundException();
        }

        private string ItemIdentity(string path) => _remotePaths.SingleOrDefault(item => item.Value == path).Key
            ?? throw new InvalidDataException("cloud.sync.identity_missing");

        private async Task RegisterPathsAsync(IEnumerable<string> remotePaths, CancellationToken token = default)
        {
            var values = remotePaths.Distinct(StringComparer.Ordinal).ToArray();
            if (values.Any(path => DesktopDrivePath.Normalize(path) != path))
                throw new InvalidDataException("cloud.sync.invalid_path");
            var names = await _syncStore.RegisterLocalNamesAsync(mapping, _safeSegments, values, token).ConfigureAwait(false);
            var registered = await store.RegisterItemPathsAsync(mapping.Id, values).ConfigureAwait(false);
            foreach (var item in registered) _remotePaths[item.Key] = item.Value;
            foreach (var item in names)
            {
                _safeSegments[item.Key] = item.Value;
            }
            foreach (var path in values.Where(path => path != RootRemotePath()))
                _localRemotePaths[LocalPath(path)] = path;
        }

        internal async Task EnsurePlaceholderTreeAsync(
            DesktopDriveCachePlan plan,
            CancellationToken cancellationToken)
        {
            await RegisterPathsAsync(
                plan.Folders.Concat(plan.Files.Select(file => file.RemotePath)))
                .ConfigureAwait(false);
            foreach (var folder in plan.Folders
                         .OrderBy(path => path.Count(character => character == '/')))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (string.Equals(
                    folder,
                    RootRemotePath(),
                    StringComparison.Ordinal))
                {
                    continue;
                }
                EnsurePlaceholder(folder, true, 0, null);
            }
            foreach (var file in plan.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsurePlaceholder(
                    file.RemotePath,
                    false,
                    file.SizeBytes,
                    file.ModifiedAt);
            }
        }

        internal async Task<CloudDriveRefreshSummary> RefreshFilesAsync(CancellationToken cancellationToken)
        {
            if (!TryBeginCallback()) throw new InvalidOperationException("cloud.refresh.disconnected");
            using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _refreshLifetime.Token);
            var token = lifetime.Token;
            var refreshed = 0; var failed = 0; var removed = 0; var retained = 0;
            try
            {
                var knownPaths = _remotePaths.Values.Distinct(StringComparer.Ordinal).Where(path => path != RootRemotePath()).ToArray();
                var paths = knownPaths
                    .Where(path => File.Exists(LocalPath(path))).Order(StringComparer.Ordinal).ToArray();
                var directories = new Dictionary<string, Task<IReadOnlyDictionary<string, FileItem>>>(StringComparer.Ordinal);
                var blockedParents = new HashSet<string>(StringComparer.Ordinal);
                var parents = _remotePaths.Values.Where(path => Directory.Exists(LocalPath(path))).Append(RootRemotePath())
                    .Distinct(StringComparer.Ordinal).OrderBy(path => path.Count(value => value == '/')).ToArray();
                foreach (var parent in parents)
                {
                    token.ThrowIfCancellationRequested();
                    try
                    {
                        if (blockedParents.Any(blocked => DesktopDrivePath.IsAncestorOrSame(blocked, parent)))
                            throw new InvalidDataException("cloud.sync.parent_unavailable");
                        if (parent != RootRemotePath()) _ = ReadPlaceholderState(parent, directory: true);
                        var listing = CloudDriveRemoteRefresh.ReadDirectoryAsync(parent,
                            (offset, cancellation) => repository.ListFilesAsync(parent == "/" ? "" : parent, offset, 500, cancellation), token);
                        directories[parent] = listing;
                        var entries = await listing.ConfigureAwait(false);
                        await RegisterPathsAsync(entries.Keys, token).ConfigureAwait(false);
                        foreach (var item in entries.Values)
                        {
                            token.ThrowIfCancellationRequested();
                            var gate = _rangeTransferGates.GetOrAdd(item.Path, static _ => new SemaphoreSlim(1, 1));
                            await gate.WaitAsync(token).ConfigureAwait(false);
                            try
                            {
                                if (EnsurePlaceholder(item.Path, item.IsDirectory, item.Size, item.ModifiedAt))
                                {
                                    if (!item.IsDirectory)
                                    {
                                        // 重新创建的是空占位，不能沿用已消失旧占位的内容版本。
                                        var old = await _syncStore.ReadVersionAsync(mapping, item.Path, token).ConfigureAwait(false);
                                        if (old is not null) await _syncStore.RefreshVersionAsync(mapping, item.Path, old, null,
                                            _ => Task.CompletedTask, token).ConfigureAwait(false);
                                    }
                                    refreshed++;
                                }
                            }
                            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                            catch { failed++; }
                            finally { gate.Release(); }
                        }
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                    catch (DsmException error) when (error.AuthenticationFailure) { throw; }
                    catch { blockedParents.Add(parent); failed++; }
                }
                var absentRoots = knownPaths.Where(path =>
                {
                    var parent = path[..Math.Max(1, path.LastIndexOf('/'))];
                    return directories.TryGetValue(parent, out var listing) && listing.IsCompletedSuccessfully && !listing.Result.ContainsKey(path);
                }).ToArray();
                var removalCandidates = knownPaths.Where(path => absentRoots.Any(root => DesktopDrivePath.IsAncestorOrSame(root, path)))
                    .OrderByDescending(path => path.Count(value => value == '/')).ToArray();
                var handledRemovals = new HashSet<string>(StringComparer.Ordinal);
                foreach (var path in removalCandidates)
                {
                    token.ThrowIfCancellationRequested(); handledRemovals.Add(path);
                    try
                    {
                        if (await repository.ProbeFilePresenceAsync(path, token).ConfigureAwait(false) != FilePresence.Missing)
                            throw new InvalidDataException("cloud.remove.remote_changed");
                        if ((await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false)).KeepsOffline(path)) { retained++; continue; }
                        var gate = _rangeTransferGates.GetOrAdd(path, static _ => new SemaphoreSlim(1, 1));
                        await gate.WaitAsync(token).ConfigureAwait(false);
                        try
                        {
                            var local = LocalPath(path);
                            if (File.Exists(local) || Directory.Exists(local))
                            {
                                var parent = path[..Math.Max(1, path.LastIndexOf('/'))];
                                while (parent != RootRemotePath() && parent != "/")
                                {
                                    _ = ReadPlaceholderState(parent, directory: true);
                                    parent = parent[..Math.Max(1, parent.LastIndexOf('/'))];
                                }
                            }
                            var removedLocal = await _syncStore.TryRemoveLocalProjectionAsync(mapping, path,
                                cancellation => Task.Run(() =>
                                {
                                    cancellation.ThrowIfCancellationRequested();
                                    return CloudFilePlaceholderNative.Remove(local, ItemIdentity(path),
                                        Directory.Exists(local), _localRemovals);
                                }, cancellation), token).ConfigureAwait(false);
                            if (!removedLocal) { retained++; continue; }
                            await store.UnregisterItemPathAsync(mapping.Id, path).ConfigureAwait(false);
                            foreach (var item in _remotePaths.Where(item => DesktopDrivePath.IsAncestorOrSame(path, item.Value)).ToArray())
                                _remotePaths.TryRemove(item.Key, out _);
                            foreach (var item in _localRemotePaths.Where(item => DesktopDrivePath.IsAncestorOrSame(path, item.Value)).ToArray())
                                _localRemotePaths.TryRemove(item.Key, out _);
                            await store.UpdateRuntimeAsync(mapping.Id, state => state with
                            {
                                CacheEntries = state.CacheEntries.Where(item => !DesktopDrivePath.IsAncestorOrSame(path, item.Key))
                                    .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal)
                            }).ConfigureAwait(false);
                            runtimeChanged(await store.LoadRuntimeAsync(mapping.Id).ConfigureAwait(false));
                            removed++;
                        }
                        finally { gate.Release(); }
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                    catch (DsmException error) when (error.AuthenticationFailure) { throw; }
                    catch { failed++; }
                }
                foreach (var path in paths.Where(path => !handledRemovals.Contains(path)))
                {
                    token.ThrowIfCancellationRequested();
                    try
                    {
                        var parent = path[..Math.Max(1, path.LastIndexOf('/'))];
                        if (blockedParents.Any(blocked => DesktopDrivePath.IsAncestorOrSame(blocked, parent)))
                            throw new InvalidDataException("cloud.sync.parent_unavailable");
                        if (!directories.TryGetValue(parent, out var listing))
                        {
                            listing = CloudDriveRemoteRefresh.ReadDirectoryAsync(parent,
                                (offset, cancellation) => repository.ListFilesAsync(parent == "/" ? "" : parent, offset, 500, cancellation), token);
                            directories.Add(parent, listing);
                        }
                        var files = await listing.ConfigureAwait(false);
                        if (!files.TryGetValue(path, out var item) || item.IsDirectory)
                            throw new InvalidDataException("cloud.refresh.remote_missing");
                        var gate = _rangeTransferGates.GetOrAdd(path, static _ => new SemaphoreSlim(1, 1));
                        var rehydrate = false;
                        await gate.WaitAsync(token).ConfigureAwait(false);
                        try
                        {
                            await CloudDriveRemoteRefresh.RefreshAsync(mapping, item, repository, _syncStore,
                                (candidate, invalidate, cancellation) => Task.Run(() =>
                                {
                                    cancellation.ThrowIfCancellationRequested();
                                    rehydrate = CloudFilePlaceholderNative.Update(LocalPath(path),
                                        ItemIdentity(path), new()
                                        {
                                            FileSize = candidate.Item.Size,
                                            BasicInfo = new() { LastWriteTime = candidate.Item.ModifiedAt?.UtcDateTime.ToFileTimeUtc() ?? 0 }
                                        }, invalidate);
                                }, cancellation), token).ConfigureAwait(false);
                        }
                        finally { gate.Release(); }
                        if (rehydrate)
                        {
                            // 版本发布且独占句柄释放后，回调才能安全获取新版本的固定离线内容。
                            var file = new DesktopDrivePlannedFile(path, item.Size, item.ModifiedAt);
                            await Task.Run(() => HydrateAsync(new([file], [], [], item.Size, item.Size, 0), null, token), token).ConfigureAwait(false);
                        }
                        await RecordCacheEntryAsync(path, item.Size).ConfigureAwait(false);
                        refreshed++;
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
                    catch (DsmException error) when (error.AuthenticationFailure) { throw; }
                    catch { failed++; }
                }
                return new(refreshed, failed, removed, retained);
            }
            finally { EndCallback(); }
        }

        internal void SetPinned(
            IEnumerable<string> remotePaths,
            bool isPinned)
        {
            foreach (var remotePath in remotePaths)
            {
                var localPath = LocalPath(remotePath);
                var flags = CloudFilesInterop.FileFlagOpenReparsePoint;
                if (Directory.Exists(localPath))
                {
                    flags |= CloudFilesInterop.FileFlagBackupSemantics;
                }
                using var handle = CloudFilesInterop.CreateFile(
                    localPath,
                    CloudFilesInterop.GenericRead,
                    CloudFilesInterop.FileShareReadWriteDelete,
                    IntPtr.Zero,
                    CloudFilesInterop.OpenExisting,
                    flags,
                    IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    throw new IOException("The cloud drive item is unavailable.");
                }
                CloudFilesInterop.ThrowIfFailed(
                    CloudFilesInterop.CfSetPinState(
                        handle.DangerousGetHandle(),
                        isPinned
                            ? CloudFilesInterop.PinStatePinned
                            : CloudFilesInterop.PinStateUnpinned,
                        Directory.Exists(localPath)
                            ? CloudFilesInterop.SetPinRecurse
                            : 0,
                        IntPtr.Zero),
                    "CfSetPinState");
            }
        }

        internal async Task HydrateAsync(
            DesktopDriveCachePlan plan,
            IProgress<DesktopDriveOfflineProgress>? progress,
            CancellationToken cancellationToken)
        {
            using var cancellationRegistration =
                cancellationToken.Register(CancelActiveRequests);
            long completedBytes = 0;
            for (var index = 0; index < plan.Files.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var file = plan.Files[index];
                var localPath = LocalPath(file.RemotePath);
                using var handle = CloudFilesInterop.CreateFile(
                    localPath,
                    CloudFilesInterop.GenericRead,
                    CloudFilesInterop.FileShareReadWriteDelete,
                    IntPtr.Zero,
                    CloudFilesInterop.OpenExisting,
                    CloudFilesInterop.FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    throw new IOException("A cloud file could not be opened.");
                }
                var result = CloudFilesInterop.CfHydratePlaceholder(
                    handle.DangerousGetHandle(),
                    0,
                    file.SizeBytes,
                    0,
                    IntPtr.Zero);
                cancellationToken.ThrowIfCancellationRequested();
                CloudFilesInterop.ThrowIfFailed(result, "CfHydratePlaceholder");
                completedBytes = checked(completedBytes + file.SizeBytes);
                progress?.Report(new(
                    DesktopDriveOfflinePhase.Downloading,
                    index + 1,
                    plan.Files.Count,
                    completedBytes,
                    plan.TotalBytes));
                await Task.Yield();
            }
        }

        private void CancelActiveRequests()
        {
            foreach (var cancellation in _requestCancellations.Values)
            {
                cancellation.Cancellation.Cancel();
            }
            foreach (var cancellation in _placeholderRequestCancellations.Values)
            {
                cancellation.Cancel();
            }
        }

        private bool EnsurePlaceholder(
            string remotePath,
            bool isDirectory,
            long size,
            DateTimeOffset? modifiedAt)
        {
            var localPath = LocalPath(remotePath);
            if (File.Exists(localPath) || Directory.Exists(localPath))
            {
                var actualDirectory = (File.GetAttributes(localPath) & FileAttributes.Directory) != 0;
                if (actualDirectory != isDirectory) throw new InvalidDataException("cloud.sync.local_type_conflict");
                using var handle = CloudFilesInterop.CreateFile(localPath, 0x80, CloudFilesInterop.FileShareReadWriteDelete,
                    IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint |
                    (isDirectory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
                if (handle.IsInvalid) throw new IOException("cloud.sync.local_item_unavailable");
                _ = CloudFilePlaceholderNative.Read(handle, ItemIdentity(remotePath));
                return false;
            }
            var parentPath = Path.GetDirectoryName(localPath)
                ?? throw new IOException("The local cloud path is invalid.");
            if (!Directory.Exists(parentPath))
            {
                throw new DirectoryNotFoundException();
            }
            var allocations = new List<IntPtr>();
            try
            {
                var namePointer = Marshal.StringToHGlobalUni(
                    Path.GetFileName(localPath));
                allocations.Add(namePointer);
                var identityValue = ItemIdentity(remotePath);
                var identity = Encoding.UTF8.GetBytes(identityValue);
                var identityPointer = Marshal.AllocHGlobal(identity.Length);
                Marshal.Copy(identity, 0, identityPointer, identity.Length);
                allocations.Add(identityPointer);
                var timestamp = modifiedAt?.UtcDateTime.ToFileTimeUtc() ?? 0;
                var placeholders = new[]
                {
                    new CloudFilesInterop.PlaceholderCreateInfo
                    {
                        RelativeFileName = namePointer,
                        FileSystemMetadata = new()
                        {
                            BasicInfo = new()
                            {
                                CreationTime = timestamp,
                                LastAccessTime = timestamp,
                                LastWriteTime = timestamp,
                                ChangeTime = timestamp,
                                FileAttributes = isDirectory ? 0x11u : 0x1u,
                            },
                            FileSize = isDirectory ? 0 : size,
                        },
                        FileIdentity = identityPointer,
                        FileIdentityLength = (uint)identity.Length,
                        Flags = CloudFilesInterop.PlaceholderMarkInSync,
                    },
                };
                CloudFilesInterop.ThrowIfFailed(
                    CloudFilesInterop.CfCreatePlaceholders(
                        parentPath,
                        placeholders,
                        1,
                        0,
                        out var entriesProcessed),
                    "CfCreatePlaceholders");
                if (entriesProcessed != 1)
                {
                    throw new IOException("The cloud placeholder was not created.");
                }
                CloudFilesInterop.ThrowIfFailed(placeholders[0].Result, "CfCreatePlaceholders.item");
                return true;
            }
            finally
            {
                foreach (var allocation in allocations)
                {
                    Marshal.FreeHGlobal(allocation);
                }
            }
        }

        private string RootRemotePath() =>
            mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                ? "/"
                : DesktopDrivePath.Normalize(mapping.Scope.FolderPath) ?? "/";

        private CloudFilesInterop.PlaceholderStandardInfo ReadPlaceholderState(string remotePath, bool directory = false)
        {
            using var handle = CloudFilesInterop.CreateFile(LocalPath(remotePath), 0x80, // FILE_READ_ATTRIBUTES
                CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero, CloudFilesInterop.OpenExisting,
                CloudFilesInterop.FileFlagOpenReparsePoint | (directory ? CloudFilesInterop.FileFlagBackupSemantics : 0), IntPtr.Zero);
            if (handle.IsInvalid) throw new IOException("cloud.sync.placeholder_unavailable");
            return CloudFilePlaceholderNative.Read(handle, ItemIdentity(remotePath));
        }

        private string LocalPath(string remotePath)
        {
            var normalized = DesktopDrivePath.Normalize(remotePath)
                ?? throw new InvalidOperationException();
            var root = RootRemotePath();
            if (!DesktopDrivePath.IsAncestorOrSame(root, normalized))
            {
                throw new InvalidOperationException();
            }
            var relative = root == "/"
                ? normalized.TrimStart('/')
                : normalized[root.Length..].TrimStart('/');
            if (relative.Length == 0)
            {
                return localRoot;
            }
            var local = localRoot;
            var remote = root == "/" ? string.Empty : root;
            foreach (var segment in relative.Split(
                         '/',
                         StringSplitOptions.RemoveEmptyEntries))
            {
                remote = $"{remote}/{segment}";
                local = Path.Combine(
                    local,
                    _safeSegments.GetValueOrDefault(remote)
                        ?? DesktopDriveWindowsNameCodec.EscapeSegment(segment));
            }
            return local;
        }

        private static CloudFilesInterop.OperationInfo Operation(
            uint type,
            CloudFilesInterop.ConnectionKey connectionKey,
            CloudFilesInterop.TransferKey transferKey,
            CloudFilesInterop.RequestKey requestKey) =>
            new()
            {
                StructSize = (uint)Marshal.SizeOf<CloudFilesInterop.OperationInfo>(),
                Type = type,
                ConnectionKey = connectionKey,
                TransferKey = transferKey,
                RequestKey = requestKey,
            };

        private static void ExecuteTransferData(
            CloudFilesInterop.OperationInfo operation,
            IntPtr buffer,
            long offset,
            long length,
            int status)
        {
            var parameters = new CloudFilesInterop.TransferDataParameters
            {
                ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferDataParameters>(),
                CompletionStatus = status,
                Buffer = buffer,
                Offset = offset,
                Length = length,
            };
            Execute(operation, parameters);
        }

        private static void Execute<T>(
            CloudFilesInterop.OperationInfo operation,
            T parameters) where T : struct
        {
            var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
            try
            {
                Marshal.StructureToPtr(parameters, pointer, fDeleteOld: false);
                CloudFilesInterop.ThrowIfFailed(
                    CloudFilesInterop.CfExecute(operation, pointer),
                    "CfExecute");
            }
            finally
            {
                Marshal.FreeHGlobal(pointer);
            }
        }

        private static IntPtr AllocateStructureArray(
            CloudFilesInterop.PlaceholderCreateInfo[] values)
        {
            if (values.Length == 0)
            {
                return IntPtr.Zero;
            }
            var itemSize = Marshal.SizeOf<CloudFilesInterop.PlaceholderCreateInfo>();
            var pointer = Marshal.AllocHGlobal(itemSize * values.Length);
            for (var index = 0; index < values.Length; index++)
            {
                Marshal.StructureToPtr(
                    values[index],
                    IntPtr.Add(pointer, index * itemSize),
                    fDeleteOld: false);
            }
            return pointer;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct FetchDataCallbackParameters
        {
            [FieldOffset(0)] internal uint ParamSize;
            [FieldOffset(8)] internal uint Flags;
            [FieldOffset(16)] internal long RequiredFileOffset;
            [FieldOffset(24)] internal long RequiredLength;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct CancelFetchDataCallbackParameters
        {
            [FieldOffset(0)] internal uint ParamSize;
            [FieldOffset(8)] internal uint Flags;
            [FieldOffset(16)] internal long FileOffset;
            [FieldOffset(24)] internal long Length;
        }

        private sealed record ActiveRangeRequest(
            CancellationTokenSource Cancellation,
            long Offset,
            long Length);

    }

    internal sealed class InsufficientLocalSpaceException(
        long requiredBytes = 0,
        long availableBytes = 0,
        long shortageBytes = 0,
        string? volumeName = null) : IOException
    {
        internal long RequiredBytes { get; } = requiredBytes;
        internal long AvailableBytes { get; } = availableBytes;
        internal long ShortageBytes { get; } = shortageBytes;
        internal string? VolumeName { get; } = volumeName;
    }
}

internal static class DesktopCloudDriveCapabilityGate
{
    private const string RegistrationSwitch =
        "LanStash.ExperimentalCloudFilesRegistration";

    internal static bool IsRegistrationEnabled =>
        AppContext.TryGetSwitch(RegistrationSwitch, out var enabled) && enabled;

    // 用户确认后仅在本进程内开放只读测试，不写入设置，也不执行任何注册操作。
    internal static void EnableForCurrentProcess() => AppContext.SetSwitch(RegistrationSwitch, true);

    internal static void EnsureRegistrationEnabled()
    {
        if (!IsRegistrationEnabled)
        {
            throw new InvalidOperationException("CloudDrivePendingDeviceValidation");
        }
    }
}

internal sealed record CloudFileRangeTransferOutcome(
    bool Succeeded,
    string? StrongContentVersion,
    long TotalLength);

internal static class CloudFileCancelRange
{
    internal static bool CoversOutstandingRange(
        long requestOffset,
        long requestLength,
        long cancelledOffset,
        long cancelledLength)
    {
        if (requestOffset < 0 || requestLength <= 0 || cancelledOffset < 0)
        {
            return false;
        }
        if (cancelledOffset > requestOffset)
        {
            return false;
        }
        if (cancelledLength == -1)
        {
            return true;
        }
        if (cancelledLength <= 0)
        {
            return false;
        }

        var requestEnd = requestLength > long.MaxValue - requestOffset
            ? long.MaxValue
            : requestOffset + requestLength;
        var cancelledEnd = cancelledLength > long.MaxValue - cancelledOffset
            ? long.MaxValue
            : cancelledOffset + cancelledLength;
        return cancelledEnd >= requestEnd;
    }
}

internal static class CloudFileHydrationGuard
{
    internal static (long Offset, long Length) AlignRange(long offset, long length, long fileSize)
    {
        if (offset < 0 || length <= 0 || offset >= fileSize || length > fileSize - offset)
            throw new ArgumentOutOfRangeException(nameof(length));
        const long alignment = 4096;
        var start = offset / alignment * alignment;
        var end = offset + length;
        var padding = (alignment - end % alignment) % alignment;
        end = padding > fileSize - end ? fileSize : end + padding;
        return (start, end - start);
    }

    internal static void Validate(CloudFilesInterop.PlaceholderStandardInfo placeholder, long fileId,
        long syncRootFileId, CloudDriveContentVersion? knownVersion, long fileSize)
    {
        if (placeholder.FileId != fileId || placeholder.SyncRootFileId != syncRootFileId ||
            placeholder.OnDiskDataSize < 0 || placeholder.ValidatedDataSize < 0 || placeholder.ModifiedDataSize != 0)
            throw new InvalidDataException("cloud.sync.placeholder_changed");
        if (knownVersion is null && (placeholder.OnDiskDataSize != 0 || placeholder.ValidatedDataSize != 0))
            throw new InvalidDataException("cloud.sync.legacy_content_unverified");
        if (knownVersion is not null && knownVersion.Length != fileSize)
            throw new InvalidDataException("cloud.sync.version_conflict");
    }
}

internal static class CloudFileRangeTransfer
{
    internal const long MaximumBufferedTransferBytes = 64L * 1024 * 1024;

    internal static async Task<CloudFileRangeTransferOutcome> ExecuteAsync(
        string remotePath,
        long offset,
        long length,
        long fileSize,
        long chunkSize,
        string? expectedContentVersion,
        long? expectedTotalLength,
        Func<long, long, string?, long?, CancellationToken,
            Task<FileRangeReadResult>> readRange,
        Action<long, byte[]> submitData,
        Action<long, long> submitFailure,
        CancellationToken cancellationToken,
        Func<string, long, CancellationToken, Task>? persistVersion = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(remotePath);
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        if (length == -1 && offset <= fileSize)
        {
            length = fileSize - offset;
        }
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(length);
        ArgumentOutOfRangeException.ThrowIfNegative(fileSize);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chunkSize);

        var strongContentVersion = expectedContentVersion;
        var totalLength = expectedTotalLength;
        var currentOffset = offset;
        var remaining = length;
        try
        {
            if (persistVersion is null)
            {
                throw new FileRangeContractException(
                    FileRangeContractFailure.UnsafeSegmentedRead,
                    "Cloud Files hydration requires durable content version storage.");
            }
            if (offset > fileSize || length > fileSize - offset || totalLength is not null && totalLength != fileSize)
                throw new FileRangeContractException(FileRangeContractFailure.UnexpectedTotalLength, "The requested range is outside the placeholder.");

            var versionPersisted = false;
            while (remaining > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var requestLength = Math.Min(remaining, Math.Min(chunkSize, MaximumBufferedTransferBytes));
                var result = await readRange(
                    currentOffset,
                    requestLength,
                    strongContentVersion,
                    totalLength,
                    cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                ValidateResult(result, currentOffset, requestLength);

                if (totalLength is null)
                {
                    totalLength = result.TotalLength;
                    if (totalLength != fileSize)
                    {
                        throw new FileRangeContractException(
                            FileRangeContractFailure.UnexpectedTotalLength,
                            "The remote length differs from the placeholder length.",
                            result.StatusCode);
                    }
                }
                else if (result.TotalLength != totalLength)
                {
                    throw new FileRangeContractException(
                        FileRangeContractFailure.UnexpectedTotalLength,
                        "The remote length changed during hydration.",
                        result.StatusCode);
                }

                if (strongContentVersion is null)
                {
                    if (!result.CanSafelyReadInSegments ||
                        string.IsNullOrWhiteSpace(result.ServerContentVersion))
                    {
                        throw new FileRangeContractException(
                            FileRangeContractFailure.UnsafeSegmentedRead,
                            "Cloud Files hydration requires a strong remote content version before any data is submitted.",
                            result.StatusCode);
                    }
                    strongContentVersion = result.ServerContentVersion;
                }
                else if (!result.CanSafelyReadInSegments ||
                         !string.Equals(
                             result.ServerContentVersion,
                             strongContentVersion,
                             StringComparison.Ordinal))
                {
                    throw new FileRangeContractException(
                        FileRangeContractFailure.ContentVersionMismatch,
                        "The remote content version changed during hydration.",
                        result.StatusCode);
                }

                if (!versionPersisted)
                {
                    await persistVersion(strongContentVersion, totalLength.Value, cancellationToken).ConfigureAwait(false);
                    versionPersisted = true;
                }
                cancellationToken.ThrowIfCancellationRequested();
                // 官方允许同次回调多次交付；只交付已核对且版本先行落盘的块，不累计整个文件。
                submitData(currentOffset, result.Bytes);
                currentOffset = checked(currentOffset + result.ActualByteCount);
                remaining -= result.ActualByteCount;
            }

            return new(true, strongContentVersion, totalLength!.Value);
        }
        catch
        {
            try
            {
                submitFailure(currentOffset, remaining);
            }
            catch
            {
                // 原生终态提交失败也不能触发第二次终态提交。
            }
            return new(false, strongContentVersion, totalLength ?? fileSize);
        }
    }

    private static void ValidateResult(
        FileRangeReadResult result,
        long requestedOffset,
        long requestedLength)
    {
        if (result.StatusCode != 206)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedStatus,
                "A ranged read must return HTTP 206.",
                result.StatusCode);
        }
        if (result.RequestedStart != requestedOffset ||
            result.ResponseStart != requestedOffset)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedRangeStart,
                "The returned range starts at a different offset.",
                result.StatusCode);
        }
        if (result.RequestedLength != requestedLength ||
            result.ResponseLength != requestedLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedRangeLength,
                "The returned range length differs from the requested length.",
                result.StatusCode);
        }
        if (result.ActualByteCount != requestedLength ||
            result.Bytes.LongLength != requestedLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedBodyLength,
                "The returned body length differs from the requested length.",
                result.StatusCode);
        }
    }
}
