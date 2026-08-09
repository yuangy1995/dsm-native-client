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
        DesktopDriveCachePolicy? cachePolicy = null)
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
            true,
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
            return;
        }
        var state = Runtime(mapping);
        var paths = state.CacheEntries.Values
            .Where(entry => entry.Kind == DesktopDriveCacheEntryKind.Temporary)
            .Select(entry => entry.RemotePath)
            .ToArray();
        var released = runtime.Dehydrate(paths);
        var entries = state.CacheEntries
            .Where(item => !released.Contains(item.Key, StringComparer.Ordinal))
            .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
        await SetRuntimeAsync(
            mapping.Id,
            state with { CacheEntries = entries }).ConfigureAwait(false);
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
        var state = Runtime(mapping);
        runtime?.SetPinned(state.PinnedPaths, false);
        await SetRuntimeAsync(
            mapping.Id,
            state with { PinnedPaths = [] }).ConfigureAwait(false);
        if (runtime is not null)
        {
            var offlinePaths = state.CacheEntries.Values
                .Where(entry => entry.Kind == DesktopDriveCacheEntryKind.KeptOffline)
                .Select(entry => entry.RemotePath)
                .ToArray();
            var released = runtime.Dehydrate(offlinePaths);
            var entries = state.CacheEntries
                .Where(item => !released.Contains(item.Key, StringComparer.Ordinal))
                .ToDictionary(
                    item => item.Key,
                    item => item.Value with
                    {
                        Kind = DesktopDriveCacheEntryKind.Temporary,
                        UpdatedAt = DateTimeOffset.UtcNow,
                    },
                    StringComparer.Ordinal);
            await SetRuntimeAsync(
                mapping.Id,
                Runtime(mapping) with { CacheEntries = entries })
                .ConfigureAwait(false);
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
        runtime?.SetPinned(targets, false);
        var cachedPaths = state.CacheEntries.Values
            .Where(entry =>
                entry.Kind == DesktopDriveCacheEntryKind.KeptOffline &&
                targets.Any(target =>
                    DesktopDrivePath.IsAncestorOrSame(
                        target,
                        entry.RemotePath)))
            .Select(entry => entry.RemotePath)
            .ToArray();
        var released = runtime?.Dehydrate(cachedPaths) ?? [];
        var entries = state.CacheEntries
            .Where(item => !released.Contains(item.Key, StringComparer.Ordinal))
            .ToDictionary(
                item => item.Key,
                item => targets.Any(target =>
                    DesktopDrivePath.IsAncestorOrSame(target, item.Key))
                        ? item.Value with
                        {
                            Kind = DesktopDriveCacheEntryKind.Temporary,
                            UpdatedAt = DateTimeOffset.UtcNow,
                        }
                        : item.Value,
                StringComparer.Ordinal);
        await SetRuntimeAsync(
            mapping.Id,
            state with
            {
                PinnedPaths = remainingPins,
                CacheEntries = entries,
            }).ConfigureAwait(false);
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
        await Task.Run(() =>
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
                    Population = new() { Primary = 0, Modifier = 0 },
                    InSync = 0x00ffffff,
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
                    Type = CloudFilesInterop.CallbackNone,
                },
            };
            var result = CloudFilesInterop.CfConnectSyncRoot(
                path,
                callbacks,
                GCHandle.ToIntPtr(runtime.ContextHandle),
                CloudFilesInterop.ConnectRequireFullPath,
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

    private sealed class MappingRuntime(
        DesktopDriveMapping mapping,
        string localRoot,
        IDsmRepository repository,
        DesktopCloudDriveStore store,
        IReadOnlyDictionary<string, string> initialItemPaths,
        Action<DesktopDriveMappingRuntime> runtimeChanged)
    {
        private DesktopDriveMapping Mapping => mapping;
        internal readonly CloudFilesInterop.Callback FetchDataCallback =
            OnFetchData;
        internal readonly CloudFilesInterop.Callback FetchPlaceholdersCallback =
            OnFetchPlaceholders;
        internal readonly CloudFilesInterop.Callback CancelCallback =
            OnCancel;
        internal readonly CloudFilesInterop.Callback FileOpenedCallback =
            OnFileOpened;
        internal readonly CloudFilesInterop.Callback RejectDeleteCallback =
            OnRejectDelete;
        internal readonly CloudFilesInterop.Callback RejectRenameCallback =
            OnRejectRename;
        internal GCHandle ContextHandle;
        internal CloudFilesInterop.ConnectionKey ConnectionKey;
        internal CloudFilesInterop.CallbackRegistration[] Callbacks = [];
        private readonly ConcurrentDictionary<string, string> _remotePaths =
            new(initialItemPaths, StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, string> _safeSegments =
            new(
                DesktopDriveWindowsNameCodec.BuildSafeSegments(
                    initialItemPaths.Values),
                StringComparer.Ordinal);
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
                _ = runtime.RunCallbackAsync(() => runtime.TransferDataAsync(
                        connectionKey,
                        transferKey,
                        requestKey,
                        remotePath,
                        parameters.RequiredFileOffset,
                        parameters.RequiredLength,
                        fileSize));
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

        private static void OnRejectDelete(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer) =>
            RejectMutationWithLifetime(
                info,
                CloudFilesInterop.OperationAckDelete);

        private static void OnRejectRename(
            in CloudFilesInterop.CallbackInfo info,
            IntPtr parametersPointer) =>
            RejectMutationWithLifetime(
                info,
                CloudFilesInterop.OperationAckRename);

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
                    RejectMutation(info, operationType);
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
            uint operationType)
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
                    CompletionStatus = CloudFilesInterop.StatusAccessDenied,
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
                    return Task.CompletedTask;
                }
                _callbacksDrained ??= new(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                return _callbacksDrained.Task;
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
            long fileSize)
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
                EnsureFreeSpace(transferLength);
                await transferGate.WaitAsync(cancellation.Token)
                    .ConfigureAwait(false);
                enteredTransferGate = true;
                var outcome = await CloudFileRangeTransfer.ExecuteAsync(
                    remotePath,
                    offset,
                    transferLength,
                    fileSize,
                    DownloadChunkBytes,
                    null,
                    null,
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
                    cancellation.Token).ConfigureAwait(false);
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
            long logicalSizeBytes)
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
                    DateTimeOffset.UtcNow,
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
            await store.UpdateRuntimeAsync(mapping.Id, current =>
            {
                var entries = current.CacheEntries
                    .Where(item => !released.Contains(
                        item.Key,
                        StringComparer.Ordinal))
                    .ToDictionary(
                        item => item.Key,
                        item => item.Value,
                        StringComparer.Ordinal);
                return current with { CacheEntries = entries };
            }).ConfigureAwait(false);
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
                if (!File.Exists(localPath))
                {
                    released.Add(remotePath);
                    continue;
                }
                using var handle = CloudFilesInterop.CreateFile(
                    localPath,
                    0,
                    CloudFilesInterop.FileShareReadWriteDelete,
                    IntPtr.Zero,
                    CloudFilesInterop.OpenExisting,
                    CloudFilesInterop.FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                if (handle.IsInvalid)
                {
                    continue;
                }
                if (CloudFilesInterop.CfDehydratePlaceholder(
                    handle.DangerousGetHandle(),
                    0,
                    -1,
                    0,
                    IntPtr.Zero) >= 0)
                {
                    released.Add(remotePath);
                }
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
                var offset = 0;
                var allItems = new List<FileItem>();
                do
                {
                    var page = await repository.ListFilesAsync(
                        listPath,
                        offset,
                        500,
                        cancellation.Token).ConfigureAwait(false);
                    allItems.AddRange(page.Items);
                    offset += page.Items.Count;
                    if (page.Items.Count == 0 || offset >= page.Total)
                    {
                        break;
                    }
                } while (true);
                await RegisterPathsAsync(allItems.Select(item => item.Path))
                    .ConfigureAwait(false);

                if (allItems.Count == 0)
                {
                    Execute(
                        operation,
                        new CloudFilesInterop.TransferPlaceholdersParameters
                        {
                            ParamSize = (uint)Marshal.SizeOf<CloudFilesInterop.TransferPlaceholdersParameters>(),
                            CompletionStatus = CloudFilesInterop.StatusSuccess,
                            PlaceholderTotalCount = 0,
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
                        PlaceholderArray = arrayPointer,
                        PlaceholderCount = (uint)placeholders.Length,
                    };
                    Execute(operation, parameters);
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
            var identityValue = DesktopDriveItemIdentity.Identifier(
                    mapping.Id,
                    item.Path)
                ?? throw new InvalidOperationException();
            _remotePaths[identityValue] = item.Path;
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

        private async Task RegisterPathsAsync(IEnumerable<string> remotePaths)
        {
            var values = remotePaths
                .Select(DesktopDrivePath.Normalize)
                .OfType<string>()
                .Distinct(StringComparer.Ordinal)
                .ToArray();
            foreach (var path in values)
            {
                var identity = DesktopDriveItemIdentity.Identifier(mapping.Id, path);
                if (identity is not null)
                {
                    _remotePaths[identity] = path;
                }
            }
            foreach (var item in DesktopDriveWindowsNameCodec.BuildSafeSegments(
                         _remotePaths.Values))
            {
                _safeSegments[item.Key] = item.Value;
            }
            await store.RegisterItemPathsAsync(mapping.Id, values)
                .ConfigureAwait(false);
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

        private void EnsurePlaceholder(
            string remotePath,
            bool isDirectory,
            long size,
            DateTimeOffset? modifiedAt)
        {
            var localPath = LocalPath(remotePath);
            if (File.Exists(localPath) || Directory.Exists(localPath))
            {
                return;
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
                var identityValue = DesktopDriveItemIdentity.Identifier(
                        mapping.Id,
                        remotePath)
                    ?? throw new InvalidOperationException();
                _remotePaths[identityValue] = remotePath;
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
        CancellationToken cancellationToken)
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
        try
        {
            if (offset != 0 ||
                length != fileSize ||
                length > MaximumBufferedTransferBytes)
            {
                throw new FileRangeContractException(
                    FileRangeContractFailure.UnsafeSegmentedRead,
                    "Cloud Files hydration remains disabled for partial or unbounded transfers until content versions can be persisted across callbacks.");
            }

            var buffered = new byte[checked((int)length)];
            var currentOffset = offset;
            var remaining = length;
            while (remaining > 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var requestLength = Math.Min(remaining, chunkSize);
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

                Buffer.BlockCopy(
                    result.Bytes,
                    0,
                    buffered,
                    checked((int)(currentOffset - offset)),
                    checked((int)result.ActualByteCount));
                currentOffset = checked(currentOffset + result.ActualByteCount);
                remaining -= result.ActualByteCount;
            }

            cancellationToken.ThrowIfCancellationRequested();
            submitData(offset, buffered);
            return new(true, strongContentVersion, totalLength!.Value);
        }
        catch
        {
            try
            {
                submitFailure(offset, length);
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
