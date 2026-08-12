using System.Text.Json;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public enum FileLocationSource { Shares, Favorite, Recent, Remote, Recycle, Browser }
public enum FileLocationViewState { Idle, Loading, Content, Empty, Error }

public sealed record FileLocationSectionState<T>(
    FileLocationViewState State,
    IReadOnlyList<T> Items,
    bool IsRefreshing = false,
    bool IsPartial = false,
    bool IsTruncated = false,
    string? ErrorTag = null);

public sealed record RecentFileLocation(Guid ProfileId, string Path, string Name);

public sealed class FileLocationsViewModel : ObservableObject, IDisposable
{
    private const int RecentLimit = 12;
    private readonly Dictionary<Guid, ProfileState> _states = [];
    private Guid? _profileId;
    private IFileLocationsRepository? _repository;
    private FileBrowserViewModel? _browser;
    private CancellationTokenSource? _refreshCancellation;
    private CancellationTokenSource? _openCancellation;
    private long _generation;
    private long _openGeneration;
    private FileBrowserViewModel? _suppressedBrowser;
    private string? _suppressedPath;
    private bool _disposed;

    // 只有当前活动 profile 的 repository 才能暴露远程挂载管理入口。
    public bool AllowsRemoteMountManagement =>
        _profileId is { } profileId &&
        _repository is { } repository &&
        repository.ProfileId == profileId &&
        repository.AllowsRemoteMountManagement;
    public bool IsCreatingRemoteMount { get; private set; }
    public bool IsEditingRemoteMount { get; private set; }
    public FileRemoteLocation? EditingRemoteLocation { get; private set; }

    public async Task<MutationResult> AddFavoriteAsync(string path, string? name = null,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var (repository, profileId) = RequireActiveRepository();
        if (!repository.CanWriteFavorites)
        {
            return UnsupportedMutation("addFavorite");
        }
        var result = await repository.AddFavoriteAsync(path, name, cancellationToken);
        await RefreshAfterMutationAsync(repository, profileId, result);
        return result;
    }

    public async Task<MutationResult> RemoveFavoriteAsync(string path,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var (repository, profileId) = RequireActiveRepository();
        if (!repository.CanWriteFavorites)
        {
            return UnsupportedMutation("removeFavorite");
        }
        var result = await repository.RemoveFavoriteAsync(path, cancellationToken);
        await RefreshAfterMutationAsync(repository, profileId, result);
        return result;
    }

    public async Task<MutationResult> CreateRemoteMountAsync(RemoteMountDraft draft,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var (repository, profileId) = RequireActiveRepository();
        if (!AllowsRemoteMountManagement)
        {
            return UnsupportedMutation("createRemoteMount");
        }
        IsCreatingRemoteMount = true;
        RaisePropertyChanged(nameof(IsCreatingRemoteMount));
        try
        {
            var result = await repository.CreateRemoteMountAsync(draft, cancellationToken);
            await RefreshAfterMutationAsync(repository, profileId, result);
            return result;
        }
        finally
        {
            IsCreatingRemoteMount = false;
            RaisePropertyChanged(nameof(IsCreatingRemoteMount));
        }
    }

    public async Task<MutationResult> UpdateRemoteMountAsync(RemoteMountDraft draft,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var (repository, profileId) = RequireActiveRepository();
        if (!AllowsRemoteMountManagement)
        {
            return UnsupportedMutation("updateRemoteMount");
        }
        IsEditingRemoteMount = true;
        RaisePropertyChanged(nameof(IsEditingRemoteMount));
        try
        {
            var result = await repository.UpdateRemoteMountAsync(draft, cancellationToken);
            await RefreshAfterMutationAsync(repository, profileId, result);
            return result;
        }
        finally
        {
            IsEditingRemoteMount = false;
            EditingRemoteLocation = null;
            RaisePropertyChanged(nameof(IsEditingRemoteMount));
            RaisePropertyChanged(nameof(EditingRemoteLocation));
        }
    }

    public async Task<MutationResult> DeleteRemoteMountAsync(string mountPoint,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var (repository, profileId) = RequireActiveRepository();
        if (!AllowsRemoteMountManagement)
        {
            return UnsupportedMutation("deleteRemoteMount");
        }
        var result = await repository.DeleteRemoteMountAsync(mountPoint, cancellationToken);
        await RefreshAfterMutationAsync(repository, profileId, result);
        return result;
    }

    public void BeginEditRemoteMount(FileRemoteLocation location)
    {
        ThrowIfDisposed();
        if (!AllowsRemoteMountManagement || _profileId != location.ProfileId)
        {
            return;
        }
        EditingRemoteLocation = location;
        IsEditingRemoteMount = true;
        RaisePropertyChanged(nameof(EditingRemoteLocation));
        RaisePropertyChanged(nameof(IsEditingRemoteMount));
    }

    public void CancelEditRemoteMount()
    {
        EditingRemoteLocation = null;
        IsEditingRemoteMount = false;
        RaisePropertyChanged(nameof(EditingRemoteLocation));
        RaisePropertyChanged(nameof(IsEditingRemoteMount));
    }

    public FileLocationSectionState<FileFavoriteLocation> Favorites { get; private set; } = Idle<FileFavoriteLocation>();
    public FileLocationSectionState<FileRecycleLocation> Recycle { get; private set; } = Idle<FileRecycleLocation>();
    public FileLocationSectionState<FileRemoteLocation> Remote { get; private set; } = Idle<FileRemoteLocation>();
    public IReadOnlyList<RecentFileLocation> RecentLocations => CurrentState?.Recent ?? [];
    public FileLocationSource SelectedSource => CurrentState?.SelectedSource ?? FileLocationSource.Shares;
    public Guid? ProfileId => _profileId;
    public FileLocationsAvailability? Availability => _repository?.Availability;
    public bool IsActive => _repository is not null;

    private ProfileState? CurrentState =>
        _profileId is { } id && _states.TryGetValue(id, out var state) ? state : null;

    public void Activate(Guid profileId, IFileLocationsRepository repository, FileBrowserViewModel browser)
    {
        ThrowIfDisposed();
        if (repository.ProfileId != profileId) throw new ArgumentException("Repository profile mismatch.", nameof(repository));
        Deactivate();
        _profileId = profileId;
        _repository = repository;
        _browser = browser;
        _browser.LocationCommitted += BrowserLocationCommitted;
        var state = GetState(profileId);
        Publish(state);
        RaisePropertyChanged(nameof(ProfileId));
        RaisePropertyChanged(nameof(Availability));
        RaisePropertyChanged(nameof(IsActive));
        RaisePropertyChanged(nameof(AllowsRemoteMountManagement));
    }

    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var repository = _repository ?? throw new InvalidOperationException("Locations are not active.");
        var profileId = _profileId!.Value;
        var generation = Interlocked.Increment(ref _generation);
        _refreshCancellation?.Cancel();
        _refreshCancellation?.Dispose();
        var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _refreshCancellation = requestCancellation;
        var requestToken = requestCancellation.Token;
        Favorites = Loading(Favorites); Recycle = Loading(Recycle); Remote = Loading(Remote); RaiseSections();
        try
        {
            var snapshot = await repository.LoadSnapshotAsync(requestToken);
            requestToken.ThrowIfCancellationRequested();
            if (!IsCurrent(profileId, repository, generation)) return;
            ValidateSnapshotProfile(snapshot, profileId);
            var state = GetState(profileId);
            state.Favorites = Map(snapshot.Favorites.Items, snapshot.Favorites.Status, false, snapshot.Favorites.Completion, snapshot.Favorites.FailureDiagnosticTag, state.Favorites);
            state.Recycle = Map(snapshot.RecycleBins.Items, snapshot.RecycleBins.Status, snapshot.RecycleBins.IsPartial, snapshot.RecycleBins.Completion, snapshot.RecycleBins.FailureDiagnosticTag, state.Recycle);
            state.Remote = Map(snapshot.RemoteLocations.Items, snapshot.RemoteLocations.Status, snapshot.RemoteLocations.IsPartial, snapshot.RemoteLocations.Completion, snapshot.RemoteLocations.FailureDiagnosticTag, state.Remote);
            Publish(state);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            if (IsCurrent(profileId, repository, generation)) Publish(GetState(profileId));
        }
        catch (OperationCanceledException)
        {
            if (IsCurrent(profileId, repository, generation)) Publish(GetState(profileId));
            throw;
        }
        catch (DsmException)
        {
            if (IsCurrent(profileId, repository, generation)) PublishFailure(GetState(profileId), "file.locations.refresh.failed");
        }
        catch (InvalidDataException)
        {
            if (IsCurrent(profileId, repository, generation)) PublishFailure(GetState(profileId), "file.locations.refresh.failed");
        }
        catch (IOException)
        {
            if (IsCurrent(profileId, repository, generation)) PublishFailure(GetState(profileId), "file.locations.refresh.failed");
        }
        catch (JsonException)
        {
            if (IsCurrent(profileId, repository, generation)) PublishFailure(GetState(profileId), "file.locations.refresh.failed");
        }
        finally
        {
            if (ReferenceEquals(_refreshCancellation, requestCancellation))
            {
                _refreshCancellation = null;
                requestCancellation.Dispose();
            }
        }
    }

    public async Task<bool> OpenLocationAsync(
        string path,
        FileLocationSource source,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var browser = _browser ?? throw new InvalidOperationException("Locations are not active.");
        var profileId = _profileId ?? throw new InvalidOperationException("Locations are not active.");
        _openCancellation?.Cancel();
        _openCancellation?.Dispose();
        _openCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var openGeneration = Interlocked.Increment(ref _openGeneration);
        _suppressedBrowser = browser;
        _suppressedPath = path;
        try
        {
            var committed = await browser.OpenLocationAsync(path, _openCancellation.Token);
            if (!committed || _profileId != profileId || !ReferenceEquals(_browser, browser) ||
                openGeneration != Volatile.Read(ref _openGeneration)) return false;
            var state = GetState(profileId);
            var effectiveSource = ResolveConstrainedSource(state, path, source);
            state.SelectedSource = effectiveSource;
            state.PathSources[path] = effectiveSource;
            if (path.Length > 0)
            {
                state.ExplicitRoots[path] = effectiveSource;
            }
            if (effectiveSource is FileLocationSource.Remote or FileLocationSource.Recycle)
            {
                state.Recent.RemoveAll(item => IsEqualOrDescendant(path, item.Path));
            }
            else if (ShouldRecordRecent(path, effectiveSource)) CommitRecent(state, profileId, path);
            RaisePropertyChanged(nameof(SelectedSource));
            RaisePropertyChanged(nameof(RecentLocations));
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return false; }
        catch (DsmException) { return false; }
        catch (InvalidDataException) { return false; }
        catch (IOException) { return false; }
        catch (JsonException) { return false; }
        finally
        {
            if (openGeneration == Volatile.Read(ref _openGeneration) &&
                ReferenceEquals(_suppressedBrowser, browser))
            {
                _suppressedBrowser = null;
                _suppressedPath = null;
            }
        }
    }

    public void Deactivate()
    {
        Interlocked.Increment(ref _generation);
        Interlocked.Increment(ref _openGeneration);
        _refreshCancellation?.Cancel(); _refreshCancellation?.Dispose(); _refreshCancellation = null;
        _openCancellation?.Cancel(); _openCancellation?.Dispose(); _openCancellation = null;
        _suppressedBrowser = null;
        _suppressedPath = null;
        if (_browser is not null) _browser.LocationCommitted -= BrowserLocationCommitted;
        _profileId = null; _repository = null; _browser = null;
        RaisePropertyChanged(nameof(ProfileId));
        RaisePropertyChanged(nameof(Availability));
        RaisePropertyChanged(nameof(IsActive));
        RaisePropertyChanged(nameof(AllowsRemoteMountManagement));
    }

    public void PurgeProfile(Guid profileId)
    {
        var wasActive = _profileId == profileId;
        if (wasActive) Deactivate();
        _states.Remove(profileId);
        if (wasActive)
        {
            Favorites = Idle<FileFavoriteLocation>();
            Recycle = Idle<FileRecycleLocation>();
            Remote = Idle<FileRemoteLocation>();
            RaiseSections();
            RaisePropertyChanged(nameof(RecentLocations));
            RaisePropertyChanged(nameof(SelectedSource));
        }
    }

    private void BrowserLocationCommitted(string path)
    {
        if (ReferenceEquals(_suppressedBrowser, _browser) &&
            string.Equals(_suppressedPath, path, StringComparison.Ordinal)) return;
        if (_profileId is not { } profileId) return;
        var state = GetState(profileId);
        if (string.IsNullOrWhiteSpace(path))
        {
            state.SelectedSource = FileLocationSource.Shares;
            state.PathSources[string.Empty] = FileLocationSource.Shares;
            RaisePropertyChanged(nameof(SelectedSource));
            return;
        }
        try { _ = FileBrowserViewModel.CanonicalLocationPath(path); }
        catch (ArgumentException) { return; }
        if (HasRecycleSegment(path))
        {
            state.SelectedSource = FileLocationSource.Recycle;
            state.PathSources[path] = FileLocationSource.Recycle;
        }
        else if (FindReadOnlyRootSource(state, path) is { } readOnlySource)
        {
            state.SelectedSource = readOnlySource;
            state.PathSources[path] = readOnlySource;
        }
        else
        {
            var inherited = state.ExplicitRoots
            .Where(pair => IsEqualOrDescendant(pair.Key, path))
            .OrderByDescending(pair => pair.Key.Length)
            .Select(pair => (FileLocationSource?)pair.Value)
            .FirstOrDefault();
            if (inherited is { } explicitSource)
            {
                state.SelectedSource = explicitSource;
                state.PathSources[path] = explicitSource;
            }
            else if (state.PathSources.TryGetValue(path, out var knownSource))
            {
                state.SelectedSource = knownSource;
            }
            else
            {
                state.SelectedSource = FileLocationSource.Browser;
                state.PathSources[path] = state.SelectedSource;
            }
        }
        if (state.SelectedSource is FileLocationSource.Remote or FileLocationSource.Recycle)
        {
            state.Recent.RemoveAll(item => string.Equals(item.Path, path, StringComparison.Ordinal));
        }
        else if (ShouldRecordRecent(path, state.SelectedSource)) CommitRecent(state, profileId, path);
        RaisePropertyChanged(nameof(RecentLocations));
        RaisePropertyChanged(nameof(SelectedSource));
    }

    private static bool ShouldRecordRecent(string path, FileLocationSource source) =>
        source is not (FileLocationSource.Remote or FileLocationSource.Recycle) &&
        !string.IsNullOrWhiteSpace(path) && path != "/" && path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .All(segment => !string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));

    private static bool IsEqualOrDescendant(string root, string path) =>
        string.Equals(root, path, StringComparison.Ordinal) ||
        path.StartsWith($"{root}/", StringComparison.Ordinal);

    private static FileLocationSource ResolveConstrainedSource(
        ProfileState state,
        string path,
        FileLocationSource requestedSource)
    {
        if (HasRecycleSegment(path)) return FileLocationSource.Recycle;
        return FindReadOnlyRootSource(state, path) ?? requestedSource;
    }

    private static FileLocationSource? FindReadOnlyRootSource(ProfileState state, string path) =>
        state.ExplicitRoots
            .Where(pair => (pair.Value is FileLocationSource.Remote or FileLocationSource.Recycle) &&
                IsEqualOrDescendant(pair.Key, path))
            .OrderByDescending(pair => pair.Key.Length)
            .Select(pair => (FileLocationSource?)pair.Value)
            .FirstOrDefault();

    private static bool HasRecycleSegment(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));

    private static void CommitRecent(ProfileState state, Guid profileId, string path)
    {
        state.Recent.RemoveAll(item => string.Equals(item.Path, path, StringComparison.Ordinal));
        state.Recent.Insert(0, new RecentFileLocation(profileId, path, path[(path.LastIndexOf('/') + 1)..]));
        if (state.Recent.Count > RecentLimit) state.Recent.RemoveRange(RecentLimit, state.Recent.Count - RecentLimit);
    }

    private bool IsCurrent(Guid profileId, IFileLocationsRepository repository, long generation) =>
        _profileId == profileId && ReferenceEquals(_repository, repository) && generation == Volatile.Read(ref _generation);

    private (IFileLocationsRepository Repository, Guid ProfileId) RequireActiveRepository()
    {
        if (_repository is not { } repository || _profileId is not { } profileId ||
            repository.ProfileId != profileId)
        {
            throw new InvalidOperationException("Locations are not active.");
        }
        return (repository, profileId);
    }

    private async Task RefreshAfterMutationAsync(
        IFileLocationsRepository repository,
        Guid profileId,
        MutationResult result)
    {
        if (result.Status != MutationResultStatus.ConfirmedSuccess && !result.RequiresRefresh ||
            !IsCurrentProfile(profileId, repository))
        {
            return;
        }

        try
        {
            // 提交后取消或网络未知只能用独立回读确认，不能把写请求再次发送。
            await RefreshAsync(CancellationToken.None);
        }
        catch (OperationCanceledException) when (!IsCurrentProfile(profileId, repository))
        {
        }
    }

    private bool IsCurrentProfile(Guid profileId, IFileLocationsRepository repository) =>
        _profileId == profileId && ReferenceEquals(_repository, repository) && repository.ProfileId == profileId;

    private static MutationResult UnsupportedMutation(string operation) =>
        new(
            1,
            MutationResultStatus.Unsupported,
            operation,
            submitted: false,
            requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "file.locations.write.unsupported");

    private static void ValidateSnapshotProfile(FileLocationsSnapshot snapshot, Guid profileId)
    {
        if (snapshot.ProfileId != profileId ||
            snapshot.Favorites.Items.Any(item => item.ProfileId != profileId) ||
            snapshot.RecycleBins.Items.Any(item => item.ProfileId != profileId) ||
            snapshot.RemoteLocations.Items.Any(item => item.ProfileId != profileId))
        {
            throw new InvalidDataException("The file-location snapshot does not belong to the active profile.");
        }
    }

    private ProfileState GetState(Guid id)
    {
        if (!_states.TryGetValue(id, out var state)) _states[id] = state = new();
        return state;
    }

    private void Publish(ProfileState state)
    {
        Favorites = state.Favorites; Recycle = state.Recycle; Remote = state.Remote; RaiseSections();
        RaisePropertyChanged(nameof(RecentLocations)); RaisePropertyChanged(nameof(SelectedSource));
    }

    private void PublishFailure(ProfileState state, string errorTag)
    {
        state.Favorites = Failure(state.Favorites, errorTag);
        state.Recycle = Failure(state.Recycle, errorTag);
        state.Remote = Failure(state.Remote, errorTag);
        Publish(state);
    }

    private void RaiseSections()
    {
        RaisePropertyChanged(nameof(Favorites)); RaisePropertyChanged(nameof(Recycle)); RaisePropertyChanged(nameof(Remote));
    }

    private static FileLocationSectionState<T> Idle<T>() => new(FileLocationViewState.Idle, []);
    private static FileLocationSectionState<T> Loading<T>(FileLocationSectionState<T> baseline) =>
        baseline.Items.Count == 0
            ? new(FileLocationViewState.Loading, [])
            : baseline with { IsRefreshing = true, ErrorTag = null };
    private static FileLocationSectionState<T> Failure<T>(FileLocationSectionState<T> baseline, string errorTag) =>
        baseline with { State = FileLocationViewState.Error, IsRefreshing = false, ErrorTag = errorTag };
    private static FileLocationSectionState<T> Map<T>(IReadOnlyList<T> items, FileLocationSectionStatus status, bool partial, FileLocationCompletion completion, string? error, FileLocationSectionState<T> baseline) =>
        status switch
        {
            FileLocationSectionStatus.Failed => new(
                FileLocationViewState.Error,
                baseline.Items,
                IsPartial: baseline.IsPartial,
                IsTruncated: baseline.IsTruncated,
                ErrorTag: error),
            FileLocationSectionStatus.Unavailable => Idle<T>(),
            _ => new(
                items.Count == 0 ? FileLocationViewState.Empty : FileLocationViewState.Content,
                items,
                IsPartial: partial,
                IsTruncated: completion == FileLocationCompletion.Truncated),
        };

    private sealed class ProfileState
    {
        public FileLocationSectionState<FileFavoriteLocation> Favorites = Idle<FileFavoriteLocation>();
        public FileLocationSectionState<FileRecycleLocation> Recycle = Idle<FileRecycleLocation>();
        public FileLocationSectionState<FileRemoteLocation> Remote = Idle<FileRemoteLocation>();
        public List<RecentFileLocation> Recent { get; } = [];
        public FileLocationSource SelectedSource = FileLocationSource.Shares;
        public Dictionary<string, FileLocationSource> PathSources { get; } = new(StringComparer.Ordinal)
        {
            [string.Empty] = FileLocationSource.Shares,
        };
        public Dictionary<string, FileLocationSource> ExplicitRoots { get; } = new(StringComparer.Ordinal);
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);
    public void Dispose() { if (_disposed) return; Deactivate(); _disposed = true; }
}
