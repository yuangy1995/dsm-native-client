using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos;

public sealed class PhotoBrowserViewModel : ObservableObject, IDisposable
{
    public const int DefaultPageSize = 300;
    public const int DefaultCachedPagesPerProfile = 24;

    private readonly int _pageSize;
    private readonly int _cachedPagesPerProfile;
    private readonly Dictionary<Guid, ProfileContext> _profiles = [];
    private IPhotoBrowserDataSource? _dataSource;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private Guid? _activeProfileId;
    private PhotoSpace? _selectedSpace;
    private string _currentPath = string.Empty;
    private PhotoBrowserFilter _filter;
    private PhotoBrowserContentState _contentState = PhotoBrowserContentState.Loading;
    private bool _isLoading;
    private bool _isLoadingMore;
    private bool _hasLoadMoreError;
    private PhotoBrowserEntry? _selectedItem;
    private bool _disposed;

    public PhotoBrowserViewModel(
        int pageSize = DefaultPageSize,
        int cachedPagesPerProfile = DefaultCachedPagesPerProfile)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(cachedPagesPerProfile, 1);
        _pageSize = pageSize;
        _cachedPagesPerProfile = cachedPagesPerProfile;
    }

    public ObservableCollection<PhotoSpace> Spaces { get; } = [];
    public ObservableCollection<PhotoBrowserEntry> Items { get; } = [];
    public ObservableCollection<PhotoBrowserBreadcrumb> Breadcrumbs { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public PhotoSpace? SelectedSpace
    {
        get => _selectedSpace;
        private set => SetProperty(ref _selectedSpace, value);
    }

    public string CurrentPath
    {
        get => _currentPath;
        private set => SetProperty(ref _currentPath, value);
    }

    public PhotoBrowserFilter Filter
    {
        get => _filter;
        private set => SetProperty(ref _filter, value);
    }

    public PhotoBrowserContentState ContentState
    {
        get => _contentState;
        private set
        {
            if (SetProperty(ref _contentState, value))
            {
                RaisePropertyChanged(nameof(HasContent));
                RaisePropertyChanged(nameof(IsEmpty));
                RaisePropertyChanged(nameof(IsFilteredEmpty));
                RaisePropertyChanged(nameof(HasError));
            }
        }
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set
        {
            if (SetProperty(ref _isLoading, value))
            {
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public bool IsLoadingMore
    {
        get => _isLoadingMore;
        private set
        {
            if (SetProperty(ref _isLoadingMore, value))
            {
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public bool HasLoadMoreError
    {
        get => _hasLoadMoreError;
        private set => SetProperty(ref _hasLoadMoreError, value);
    }

    public PhotoBrowserEntry? SelectedItem
    {
        get => _selectedItem;
        set => SetProperty(ref _selectedItem, value);
    }
    public bool CanGoBack => CurrentContext?.History.Count > 0;
    public bool CanGoUp => SelectedSpace is not null &&
        !string.Equals(CurrentPath, SelectedSpace.RootPath, StringComparison.Ordinal);
    public bool CanLoadMore => !IsLoading && !IsLoadingMore && (CurrentContext?.HasMore ?? false);
    public bool HasContent => ContentState == PhotoBrowserContentState.Content;
    public bool IsEmpty => ContentState == PhotoBrowserContentState.Empty;
    public bool IsFilteredEmpty => ContentState == PhotoBrowserContentState.FilteredEmpty;
    public bool HasError => ContentState == PhotoBrowserContentState.Error;

    private ProfileContext? CurrentContext => ActiveProfileId is Guid profileId &&
        _profiles.TryGetValue(profileId, out var context)
            ? context
            : null;

    private PhotoBrowserPageKey CurrentKey => new(
        ActiveProfileId ?? Guid.Empty,
        SelectedSpace?.Id ?? string.Empty,
        CurrentPath,
        Filter);

    public async Task ActivateAsync(IPhotoBrowserDataSource dataSource)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(dataSource);
        SaveCurrentPage();
        CancelCurrentRequest();
        _dataSource = dataSource;
        ActiveProfileId = dataSource.ProfileId;

        if (_profiles.TryGetValue(dataSource.ProfileId, out var cached))
        {
            RestoreContext(cached);
            return;
        }

        var context = new ProfileContext(_cachedPagesPerProfile);
        _profiles.Add(dataSource.ProfileId, context);
        RestoreContext(context);
        await DiscoverSpacesAsync(dataSource.ProfileId);
    }

    public void Deactivate()
    {
        ThrowIfDisposed();
        SaveCurrentPage();
        CancelCurrentRequest();
        _dataSource = null;
        ActiveProfileId = null;
        Spaces.Clear();
        Items.Clear();
        Breadcrumbs.Clear();
        SelectedSpace = null;
        CurrentPath = string.Empty;
        ContentState = PhotoBrowserContentState.Loading;
    }

    public async Task RefreshAsync()
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        if (SelectedSpace is null)
        {
            await DiscoverSpacesAsync(source.ProfileId);
            return;
        }

        CurrentContext!.Remove(CurrentKey);
        await LoadFirstPageAsync(source, SelectedSpace, CurrentPath);
    }

    public async Task SelectSpaceAsync(string spaceId)
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        var destination = Spaces.FirstOrDefault(space =>
            string.Equals(space.Id, spaceId, StringComparison.Ordinal));
        if (destination is null || SelectedSpace?.Id == destination.Id)
        {
            return;
        }

        SaveCurrentPage();
        CancelCurrentRequest();
        var context = CurrentContext!;
        context.History.Clear();
        SetLocation(destination, destination.RootPath, Filter);
        RaisePropertyChanged(nameof(CanGoBack));
        if (!TryRestoreCurrentPage())
        {
            await LoadFirstPageAsync(source, destination, destination.RootPath);
        }
    }

    public async Task OpenFolderAsync(PhotoBrowserEntry? entry)
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        if (entry is null || !entry.IsFolder || entry.Item.ProfileId != source.ProfileId ||
            !Items.Any(item => string.Equals(item.Path, entry.Path, StringComparison.Ordinal)))
        {
            return;
        }

        var context = CurrentContext!;
        SaveCurrentPage();
        context.History.Push(CaptureLocation());
        RaisePropertyChanged(nameof(CanGoBack));
        CancelCurrentRequest();
        SetLocation(SelectedSpace!, entry.Path, Filter);
        if (!TryRestoreCurrentPage())
        {
            await LoadFirstPageAsync(source, SelectedSpace!, entry.Path);
        }
    }

    public async Task GoBackAsync()
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        var context = CurrentContext!;
        if (context.History.Count == 0)
        {
            return;
        }

        SaveCurrentPage();
        var destination = context.History.Pop();
        RaisePropertyChanged(nameof(CanGoBack));
        var space = context.Spaces.First(space => space.Id == destination.SpaceId);
        CancelCurrentRequest();
        SetLocation(space, destination.Path, destination.Filter);
        if (TryRestoreCurrentPage(destination.SelectedPath))
        {
            return;
        }
        await LoadFirstPageAsync(source, space, destination.Path, destination.SelectedPath);
    }

    public async Task NavigateToBreadcrumbAsync(PhotoBrowserBreadcrumb? breadcrumb)
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        if (breadcrumb is null || SelectedSpace is null ||
            string.Equals(breadcrumb.Path, CurrentPath, StringComparison.Ordinal) ||
            !Breadcrumbs.Any(item =>
                string.Equals(item.Path, breadcrumb.Path, StringComparison.Ordinal)))
        {
            return;
        }

        var context = CurrentContext!;
        SaveCurrentPage();
        context.History.Push(CaptureLocation());
        RaisePropertyChanged(nameof(CanGoBack));
        CancelCurrentRequest();
        SetLocation(SelectedSpace, breadcrumb.Path, Filter);
        if (!TryRestoreCurrentPage())
        {
            await LoadFirstPageAsync(source, SelectedSpace, breadcrumb.Path);
        }
    }

    public async Task GoUpAsync()
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        if (!CanGoUp || SelectedSpace is null)
        {
            return;
        }

        var context = CurrentContext!;
        SaveCurrentPage();
        context.History.Push(CaptureLocation());
        RaisePropertyChanged(nameof(CanGoBack));
        var parent = ParentPath(CurrentPath, SelectedSpace.RootPath);
        CancelCurrentRequest();
        SetLocation(SelectedSpace, parent, Filter);
        if (!TryRestoreCurrentPage())
        {
            await LoadFirstPageAsync(source, SelectedSpace, parent);
        }
    }

    public void SetFilter(PhotoBrowserFilter filter)
    {
        ThrowIfDisposed();
        if (filter == Filter || CurrentContext is null)
        {
            return;
        }

        SaveCurrentPage();
        CancelCurrentRequest();
        Filter = filter;
        CurrentContext.Filter = filter;
        if (!TryRestoreCurrentPage())
        {
            ApplyVisibleItems();
            SaveCurrentPage();
        }
    }

    public async Task LoadMoreAsync()
    {
        ThrowIfDisposed();
        var source = RequireCurrentDataSource();
        var context = CurrentContext!;
        var space = SelectedSpace;
        if (!CanLoadMore || space is null)
        {
            return;
        }

        var key = CurrentKey;
        var requestedOffset = context.NextOffset;
        var request = BeginRequest();
        IsLoadingMore = true;
        HasLoadMoreError = false;
        try
        {
            var page = await source.LoadPageAsync(
                space,
                CurrentPath,
                requestedOffset,
                _pageSize,
                request.Token);
            if (!IsCurrent(request.Generation, key, source))
            {
                return;
            }

            ApplyPage(page, requestedOffset, append: true);
            SaveCurrentPage();
            ApplyVisibleItems();
        }
        catch (OperationCanceledException) when (
            request.Token.IsCancellationRequested || !IsCurrent(request.Generation, key, source))
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, key, source))
            {
                HasLoadMoreError = true;
                ApplyVisibleItems();
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, key, source))
            {
                IsLoadingMore = false;
            }
        }
    }

    private async Task DiscoverSpacesAsync(Guid profileId)
    {
        var source = RequireCurrentDataSource();
        var request = BeginRequest();
        IsLoading = true;
        ContentState = PhotoBrowserContentState.Loading;
        try
        {
            var spaces = await source.DiscoverSpacesAsync(request.Token);
            if (!IsCurrent(request.Generation, profileId, source))
            {
                return;
            }

            var context = CurrentContext!;
            context.Spaces = spaces.ToArray();
            ReplaceCollection(Spaces, context.Spaces);
            if (context.Spaces.Count == 0)
            {
                SetLocation(null, string.Empty, context.Filter);
                context.SourceItems.Clear();
                context.NextOffset = 0;
                context.SourceTotal = 0;
                context.HasMore = false;
                ApplyVisibleItems();
                return;
            }

            var destination = context.Spaces[0];
            SetLocation(destination, destination.RootPath, context.Filter);
            await LoadFirstPageWithinRequestAsync(
                source,
                destination,
                destination.RootPath,
                request.Generation,
                request.Token);
        }
        catch (OperationCanceledException) when (
            request.Token.IsCancellationRequested || !IsCurrent(request.Generation, profileId, source))
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, profileId, source))
            {
                Items.Clear();
                ContentState = PhotoBrowserContentState.Error;
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, profileId, source))
            {
                IsLoading = false;
            }
        }
    }

    private async Task LoadFirstPageAsync(
        IPhotoBrowserDataSource source,
        PhotoSpace space,
        string path,
        string? selectedPath = null)
    {
        var request = BeginRequest();
        IsLoading = true;
        IsLoadingMore = false;
        HasLoadMoreError = false;
        ContentState = PhotoBrowserContentState.Loading;
        try
        {
            await LoadFirstPageWithinRequestAsync(
                source,
                space,
                path,
                request.Generation,
                request.Token,
                selectedPath);
        }
        catch (OperationCanceledException) when (
            request.Token.IsCancellationRequested || !IsCurrent(request.Generation, CurrentKey, source))
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, CurrentKey, source))
            {
                var context = CurrentContext!;
                context.SourceItems.Clear();
                context.NextOffset = 0;
                context.SourceTotal = 0;
                context.HasMore = false;
                Items.Clear();
                ContentState = PhotoBrowserContentState.Error;
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, CurrentKey, source))
            {
                IsLoading = false;
            }
        }
    }

    private async Task LoadFirstPageWithinRequestAsync(
        IPhotoBrowserDataSource source,
        PhotoSpace space,
        string path,
        long generation,
        CancellationToken cancellationToken,
        string? selectedPath = null)
    {
        var key = CurrentKey;
        var page = await source.LoadPageAsync(space, path, 0, _pageSize, cancellationToken);
        if (!IsCurrent(generation, key, source))
        {
            return;
        }

        ApplyPage(page, 0, append: false);
        SaveCurrentPage();
        ApplyVisibleItems(selectedPath);
    }

    private void ApplyPage(PhotoPage page, int requestedOffset, bool append)
    {
        var profileId = ActiveProfileId ?? Guid.Empty;
        if (page.ProfileId != profileId || page.Items.Any(item => item.ProfileId != profileId) ||
            !string.Equals(page.FolderPath, CurrentPath, StringComparison.Ordinal) ||
            page.Offset != requestedOffset)
        {
            throw new InvalidDataException("Photo page does not match the active browser location.");
        }
        if (page.NextOffset < requestedOffset || page.SourceTotal < page.NextOffset ||
            page.HasMore != (page.NextOffset < page.SourceTotal) ||
            (page.HasMore && page.NextOffset == requestedOffset))
        {
            throw new InvalidDataException("Photo page did not provide a consistent raw offset.");
        }

        var context = CurrentContext!;
        if (!append)
        {
            context.SourceItems.Clear();
        }
        var paths = context.SourceItems.Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
        foreach (var item in page.Items)
        {
            if (paths.Add(item.Path))
            {
                context.SourceItems.Add(item);
            }
        }
        context.NextOffset = page.NextOffset;
        context.SourceTotal = page.SourceTotal;
        context.HasMore = page.HasMore;
        RaisePropertyChanged(nameof(CanLoadMore));
    }

    private void ApplyVisibleItems(string? selectedPath = null)
    {
        selectedPath ??= SelectedItem?.Path;
        var context = CurrentContext;
        var visible = context is null
            ? Array.Empty<PhotoBrowserEntry>()
            : context.SourceItems.Where(item => Filter switch
            {
                PhotoBrowserFilter.All => item.Kind is
                    PhotoItemKind.Folder or
                    PhotoItemKind.Image or
                    PhotoItemKind.Video,
                PhotoBrowserFilter.Images => item.Kind == PhotoItemKind.Image,
                _ => false,
            }).Select(item => new PhotoBrowserEntry(item)).ToArray();

        ReplaceCollection(Items, visible);
        SelectedItem = selectedPath is null
            ? null
            : Items.FirstOrDefault(item => string.Equals(item.Path, selectedPath, StringComparison.Ordinal));
        ContentState = Items.Count > 0
            ? PhotoBrowserContentState.Content
            : Filter == PhotoBrowserFilter.Images
                ? PhotoBrowserContentState.FilteredEmpty
                : PhotoBrowserContentState.Empty;
    }

    private void SaveCurrentPage()
    {
        var context = CurrentContext;
        if (context is null || SelectedSpace is null)
        {
            return;
        }
        context.SelectedPath = SelectedItem?.Path;
        context.Save(CurrentKey, new PageSnapshot(
            context.SourceItems.ToArray(),
            context.NextOffset,
            context.SourceTotal,
            context.HasMore,
            SelectedItem?.Path));
    }

    private bool TryRestoreCurrentPage(string? selectedPath = null)
    {
        var context = CurrentContext;
        if (context is null || !context.TryGet(CurrentKey, out var snapshot))
        {
            return false;
        }
        context.SourceItems.Clear();
        context.SourceItems.AddRange(snapshot.Items);
        context.NextOffset = snapshot.NextOffset;
        context.SourceTotal = snapshot.SourceTotal;
        context.HasMore = snapshot.HasMore;
        IsLoading = false;
        IsLoadingMore = false;
        HasLoadMoreError = false;
        ApplyVisibleItems(selectedPath ?? snapshot.SelectedPath);
        RaisePropertyChanged(nameof(CanLoadMore));
        return true;
    }

    private void RestoreContext(ProfileContext context)
    {
        ReplaceCollection(Spaces, context.Spaces);
        SetLocation(context.SelectedSpace, context.CurrentPath, context.Filter);
        HasLoadMoreError = false;
        IsLoading = false;
        IsLoadingMore = false;
        if (context.SelectedSpace is null)
        {
            context.SourceItems.Clear();
            ApplyVisibleItems();
        }
        else if (!TryRestoreCurrentPage(context.SelectedPath))
        {
            ApplyVisibleItems(context.SelectedPath);
        }
        RaisePropertyChanged(nameof(CanGoBack));
    }

    private void SetLocation(PhotoSpace? space, string path, PhotoBrowserFilter filter)
    {
        var context = CurrentContext!;
        context.SelectedSpace = space;
        context.CurrentPath = path;
        context.Filter = filter;
        SelectedSpace = space;
        CurrentPath = path;
        Filter = filter;
        SelectedItem = null;
        RebuildBreadcrumbs();
        RaisePropertyChanged(nameof(CanGoUp));
    }

    private PhotoBrowserLocation CaptureLocation()
    {
        var context = CurrentContext!;
        context.SelectedPath = SelectedItem?.Path;
        return new PhotoBrowserLocation(
            SelectedSpace!.Id,
            CurrentPath,
            Filter,
            SelectedItem?.Path);
    }

    private void RebuildBreadcrumbs()
    {
        Breadcrumbs.Clear();
        if (SelectedSpace is null)
        {
            return;
        }
        Breadcrumbs.Add(new PhotoBrowserBreadcrumb(SelectedSpace.Title, SelectedSpace.RootPath));
        var rootSegments = SelectedSpace.RootPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var segments = CurrentPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var path = SelectedSpace.RootPath;
        foreach (var segment in segments.Skip(rootSegments.Length))
        {
            path += "/" + segment;
            Breadcrumbs.Add(new PhotoBrowserBreadcrumb(segment, path));
        }
    }

    private (long Generation, CancellationToken Token) BeginRequest()
    {
        CancelCurrentRequest();
        _requestCancellation = new CancellationTokenSource();
        return (Volatile.Read(ref _generation), _requestCancellation.Token);
    }

    private void CancelCurrentRequest()
    {
        Interlocked.Increment(ref _generation);
        var cancellation = Interlocked.Exchange(ref _requestCancellation, null);
        if (cancellation is not null)
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
            cancellation.Dispose();
        }
        IsLoading = false;
        IsLoadingMore = false;
    }

    private bool IsCurrent(long generation, PhotoBrowserPageKey key, IPhotoBrowserDataSource source) =>
        !_disposed && ReferenceEquals(source, _dataSource) && source.ProfileId == ActiveProfileId &&
        generation == Volatile.Read(ref _generation) && key == CurrentKey;

    private bool IsCurrent(long generation, Guid profileId, IPhotoBrowserDataSource source) =>
        !_disposed && ReferenceEquals(source, _dataSource) && source.ProfileId == profileId &&
        ActiveProfileId == profileId && generation == Volatile.Read(ref _generation);

    private IPhotoBrowserDataSource RequireCurrentDataSource()
    {
        if (_dataSource is null || _dataSource.ProfileId != ActiveProfileId)
        {
            throw new InvalidOperationException("The photo browser is not bound to an active profile.");
        }
        return _dataSource;
    }

    private static string ParentPath(string path, string rootPath)
    {
        if (string.Equals(path, rootPath, StringComparison.Ordinal))
        {
            return rootPath;
        }
        var separator = path.LastIndexOf('/');
        return separator > rootPath.Length ? path[..separator] : rootPath;
    }

    private static void ReplaceCollection<T>(ObservableCollection<T> target, IEnumerable<T> source)
    {
        target.Clear();
        foreach (var item in source)
        {
            target.Add(item);
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        CancelCurrentRequest();
        _dataSource = null;
        foreach (var context in _profiles.Values)
        {
            context.Clear();
        }
        _profiles.Clear();
        Spaces.Clear();
        Items.Clear();
        Breadcrumbs.Clear();
    }

    private sealed class ProfileContext(int cacheLimit)
    {
        private readonly Dictionary<PhotoBrowserPageKey, CacheEntry> _cache = [];
        private readonly LinkedList<PhotoBrowserPageKey> _lru = [];

        public IReadOnlyList<PhotoSpace> Spaces { get; set; } = [];
        public PhotoSpace? SelectedSpace { get; set; }
        public string CurrentPath { get; set; } = string.Empty;
        public PhotoBrowserFilter Filter { get; set; }
        public string? SelectedPath { get; set; }
        public Stack<PhotoBrowserLocation> History { get; } = [];
        public List<PhotoItem> SourceItems { get; } = [];
        public int NextOffset { get; set; }
        public int SourceTotal { get; set; }
        public bool HasMore { get; set; }

        public void Save(PhotoBrowserPageKey key, PageSnapshot snapshot)
        {
            if (_cache.Remove(key, out var existing))
            {
                _lru.Remove(existing.Node);
            }
            var node = _lru.AddFirst(key);
            _cache[key] = new CacheEntry(snapshot, node);
            while (_cache.Count > cacheLimit)
            {
                var oldest = _lru.Last!;
                _lru.RemoveLast();
                _cache.Remove(oldest.Value);
            }
        }

        public bool TryGet(PhotoBrowserPageKey key, out PageSnapshot snapshot)
        {
            if (!_cache.TryGetValue(key, out var entry))
            {
                snapshot = default!;
                return false;
            }
            _lru.Remove(entry.Node);
            _lru.AddFirst(entry.Node);
            snapshot = entry.Snapshot;
            return true;
        }

        public void Remove(PhotoBrowserPageKey key)
        {
            if (_cache.Remove(key, out var entry))
            {
                _lru.Remove(entry.Node);
            }
        }

        public void Clear()
        {
            _cache.Clear();
            _lru.Clear();
            History.Clear();
            SourceItems.Clear();
        }

        private sealed record CacheEntry(
            PageSnapshot Snapshot,
            LinkedListNode<PhotoBrowserPageKey> Node);
    }

    private sealed record PageSnapshot(
        IReadOnlyList<PhotoItem> Items,
        int NextOffset,
        int SourceTotal,
        bool HasMore,
        string? SelectedPath);
}
