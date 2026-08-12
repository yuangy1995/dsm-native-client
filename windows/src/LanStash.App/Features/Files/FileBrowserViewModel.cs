using System.Collections.ObjectModel;
using System.Globalization;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files;

public sealed class FileBrowserViewModel : ObservableObject, IDisposable
{
    public const int DefaultPageSize = 100;

    private readonly IFileBrowserDataSource _dataSource;
    private readonly int _pageSize;
    private readonly Stack<FileBrowserLocation> _backHistory = new();
    private readonly Dictionary<FileBrowserRequestKey, PageSnapshot> _pageCache = [];
    private readonly Dictionary<string, FileListOptions> _preferredOptionsByPath =
        new(StringComparer.Ordinal);
    private readonly List<FileBrowserEntry> _loadedItems = [];
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private int _nextOffset;
    private int _total;
    private bool _isLoading;
    private bool _isLoadingMore;
    private bool _hasLoadMoreError;
    private string _currentPath = string.Empty;
    private string _filterText = string.Empty;
    private FileListOptions _preferredOptions = FileListOptions.Default;
    private FileListOptions _currentOptions = FileListOptions.Default.NormalizeForSharedRoot();
    private FileBrowserContentState _contentState = FileBrowserContentState.Loading;
    private FileBrowserLayout _layout = FileBrowserLayout.List;
    private FileBrowserEntry? _selectedItem;
    private StorageSpaceSummary? _storageSpace;
    private bool _isLoadingStorageSpace;
    private bool _hasLoadedStorageSpace;
    private bool _disposed;

    public event Action<string>? LocationCommitted;

    public FileBrowserViewModel(
        IFileBrowserDataSource dataSource,
        int pageSize = DefaultPageSize)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        _dataSource = dataSource;
        _pageSize = pageSize;
        RebuildBreadcrumbs();
    }

    public ObservableCollection<FileBrowserEntry> Items { get; } = [];
    public ObservableCollection<FileBrowserBreadcrumb> Breadcrumbs { get; } = [];

    public string CurrentPath
    {
        get => _currentPath;
        private set => SetProperty(ref _currentPath, value);
    }

    public string FilterText
    {
        get => _filterText;
        private set => SetProperty(ref _filterText, value);
    }

    public FileListOptions CurrentOptions
    {
        get => _currentOptions;
        private set
        {
            if (SetProperty(ref _currentOptions, value))
            {
                RaisePropertyChanged(nameof(SortField));
                RaisePropertyChanged(nameof(SortDirection));
                RaisePropertyChanged(nameof(TypeFilter));
            }
        }
    }

    public FileListSortField SortField => CurrentOptions.SortField;
    public FileListSortDirection SortDirection => CurrentOptions.SortDirection;
    public FileListTypeFilter TypeFilter => CurrentOptions.TypeFilter;

    public FileBrowserContentState ContentState
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

    public FileBrowserLayout Layout
    {
        get => _layout;
        set
        {
            if (SetProperty(ref _layout, value))
            {
                RaisePropertyChanged(nameof(IsListLayout));
                RaisePropertyChanged(nameof(IsGridLayout));
            }
        }
    }

    public FileBrowserEntry? SelectedItem
    {
        get => _selectedItem;
        set => SetProperty(ref _selectedItem, value);
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set => SetProperty(ref _isLoading, value);
    }

    public StorageSpaceSummary? StorageSpace
    {
        get => _storageSpace;
        private set
        {
            if (SetProperty(ref _storageSpace, value))
            {
                RaiseStorageSpaceProperties();
            }
        }
    }

    public bool IsLoadingStorageSpace
    {
        get => _isLoadingStorageSpace;
        private set
        {
            if (SetProperty(ref _isLoadingStorageSpace, value))
            {
                RaiseStorageSpaceProperties();
            }
        }
    }

    public bool HasStorageSpace => StorageSpace is not null;
    public bool IsStorageSpaceUnavailable =>
        _hasLoadedStorageSpace && !IsLoadingStorageSpace && StorageSpace is null;
    public double StorageUsedPercent => (StorageSpace?.UsedFraction ?? 0) * 100;
    public string StorageUsageText => StorageSpace is { } summary
        ? LocalizationService.Current.Format(
            "FileBrowserStorageUsage",
            FormatBytes(summary.UsedBytes),
            FormatBytes(summary.TotalBytes))
        : string.Empty;
    public string StorageRemainingText => StorageSpace is { } summary
        ? LocalizationService.Current.Format(
            "FileBrowserStorageRemaining",
            FormatBytes(summary.RemainingBytes))
        : string.Empty;
    public string StorageScopeText => StorageSpace is { } summary
        ? LocalizationService.Current.Format(
            summary.VolumeCount == 1
                ? "FileBrowserStorageScopeOne"
                : "FileBrowserStorageScopeMany",
            summary.VolumeCount)
        : string.Empty;

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

    public bool CanGoBack => _backHistory.Count > 0;
    public bool CanGoUp => !string.IsNullOrWhiteSpace(CurrentPath);
    public bool CanLoadMore => !IsLoading && !IsLoadingMore && _nextOffset < _total;
    public bool CanChooseNonNameSort => !IsSharedRoot;
    public bool CanChooseTypeFilter => !IsSharedRoot;
    public bool HasContent => ContentState == FileBrowserContentState.Content;
    public bool IsEmpty => ContentState == FileBrowserContentState.Empty;
    public bool IsFilteredEmpty => ContentState == FileBrowserContentState.FilteredEmpty;
    public bool HasError => ContentState == FileBrowserContentState.Error;
    public bool IsListLayout => Layout == FileBrowserLayout.List;
    public bool IsGridLayout => Layout == FileBrowserLayout.Grid;

    private bool IsSharedRoot => string.IsNullOrWhiteSpace(CurrentPath);
    private FileBrowserRequestKey CurrentRequestKey => new(CurrentPath, CurrentOptions);

    public Task InitializeAsync() => RefreshAsync();

    public async Task<bool> OpenLocationAsync(
        string path,
        CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        var normalized = CanonicalLocationPath(path);
        var destinationOptions = _preferredOptionsByPath.TryGetValue(normalized, out var savedOptions)
            ? savedOptions
            : _preferredOptions;
        var effectiveOptions = EffectiveOptions(normalized, destinationOptions);
        CancelCurrentRequest();
        _requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var generation = Interlocked.Increment(ref _generation);
        var token = _requestCancellation.Token;
        var loadsStorageSpace = string.IsNullOrWhiteSpace(normalized);
        if (loadsStorageSpace)
        {
            IsLoadingStorageSpace = true;
        }
        try
        {
            var page = await _dataSource.LoadPageAsync(
                normalized,
                0,
                _pageSize,
                effectiveOptions,
                token);
            var staged = CreateFirstPageSnapshot(page);
            cancellationToken.ThrowIfCancellationRequested();
            if (_disposed || generation != Volatile.Read(ref _generation)) return false;

            _backHistory.Push(CaptureLocation());
            _preferredOptionsByPath[CurrentPath] = _preferredOptions;
            CurrentPath = normalized;
            _preferredOptions = destinationOptions;
            _preferredOptionsByPath[CurrentPath] = _preferredOptions;
            CurrentOptions = effectiveOptions;
            FilterText = string.Empty;
            SelectedItem = null;
            _loadedItems.Clear();
            _loadedItems.AddRange(staged.Items);
            _nextOffset = staged.NextOffset;
            _total = staged.Total;
            HasLoadMoreError = false;
            RebuildBreadcrumbs();
            SaveCurrentPage();
            ApplyQuickFilter();
            if (loadsStorageSpace)
            {
                StorageSpace = page.StorageSpace;
                _hasLoadedStorageSpace = true;
                RaisePropertyChanged(nameof(IsStorageSpaceUnavailable));
            }
            RaisePropertyChanged(nameof(CanGoBack));
            RaisePropertyChanged(nameof(CanGoUp));
            RaisePropertyChanged(nameof(CanChooseNonNameSort));
            RaisePropertyChanged(nameof(CanChooseTypeFilter));
            LocationCommitted?.Invoke(CurrentPath);
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is DsmException or IOException or InvalidOperationException)
        {
            if (loadsStorageSpace && generation == Volatile.Read(ref _generation))
            {
                _hasLoadedStorageSpace = true;
                RaisePropertyChanged(nameof(IsStorageSpaceUnavailable));
            }
            return false;
        }
        finally
        {
            if (loadsStorageSpace && generation == Volatile.Read(ref _generation))
            {
                IsLoadingStorageSpace = false;
            }
        }
    }

    public async Task RefreshAsync()
    {
        ThrowIfDisposed();
        _pageCache.Remove(CurrentRequestKey);
        await LoadFirstPageAsync();
    }

    public async Task OpenAsync(FileBrowserEntry? entry)
    {
        ThrowIfDisposed();
        if (entry is null || !entry.IsDirectory)
        {
            return;
        }

        await NavigateAsync(entry.Path, recordHistory: true);
    }

    public async Task NavigateToBreadcrumbAsync(FileBrowserBreadcrumb? breadcrumb)
    {
        ThrowIfDisposed();
        if (breadcrumb is null || string.Equals(breadcrumb.Path, CurrentPath, StringComparison.Ordinal))
        {
            return;
        }

        await NavigateAsync(breadcrumb.Path, recordHistory: true);
    }

    public async Task GoBackAsync()
    {
        ThrowIfDisposed();
        if (_backHistory.Count == 0)
        {
            return;
        }

        var destination = _backHistory.Pop();
        RaisePropertyChanged(nameof(CanGoBack));
        await NavigateAsync(destination.Path, recordHistory: false, destination);
    }

    public async Task GoUpAsync()
    {
        ThrowIfDisposed();
        if (IsSharedRoot)
        {
            return;
        }

        await NavigateAsync(ParentPath(CurrentPath), recordHistory: true);
    }

    public async Task LoadMoreAsync()
    {
        ThrowIfDisposed();
        if (!CanLoadMore)
        {
            return;
        }

        var key = CurrentRequestKey;
        var request = BeginRequest();
        IsLoadingMore = true;
        HasLoadMoreError = false;
        try
        {
            var requestedOffset = _nextOffset;
            var page = await _dataSource.LoadPageAsync(
                key.Path,
                requestedOffset,
                _pageSize,
                key.Options,
                request.Token);
            if (!IsCurrent(request.Generation, key))
            {
                return;
            }

            AppendPage(page, requestedOffset);
            SaveCurrentPage();
            ApplyQuickFilter();
        }
        catch (OperationCanceledException) when (!IsCurrent(request.Generation, key) || request.Token.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, key))
            {
                HasLoadMoreError = true;
                ApplyQuickFilter();
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, key))
            {
                IsLoadingMore = false;
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public void SetFilter(string? value)
    {
        ThrowIfDisposed();
        FilterText = value?.Trim() ?? string.Empty;
        ApplyQuickFilter();
    }

    public Task SetSortFieldAsync(FileListSortField value)
    {
        ThrowIfDisposed();
        return IsSharedRoot
            ? Task.CompletedTask
            : ChangeOptionsAsync(_preferredOptions with { SortField = value });
    }

    public Task SetSortDirectionAsync(FileListSortDirection value)
    {
        ThrowIfDisposed();
        return ChangeOptionsAsync(_preferredOptions with { SortDirection = value });
    }

    public Task SetTypeFilterAsync(FileListTypeFilter value)
    {
        ThrowIfDisposed();
        return IsSharedRoot
            ? Task.CompletedTask
            : ChangeOptionsAsync(_preferredOptions with { TypeFilter = value });
    }

    public async Task ClearFiltersAsync()
    {
        ThrowIfDisposed();
        FilterText = string.Empty;
        if (!IsSharedRoot && _preferredOptions.TypeFilter != FileListTypeFilter.All)
        {
            await ChangeOptionsAsync(_preferredOptions with { TypeFilter = FileListTypeFilter.All });
            return;
        }
        ApplyQuickFilter();
    }

    private async Task ChangeOptionsAsync(FileListOptions preferredOptions)
    {
        var effectiveOptions = EffectiveOptions(CurrentPath, preferredOptions);
        if (_preferredOptions == preferredOptions && CurrentOptions == effectiveOptions)
        {
            return;
        }

        var selectedPath = SelectedItem?.Path;
        _preferredOptions = preferredOptions;
        _preferredOptionsByPath[CurrentPath] = preferredOptions;
        CurrentOptions = effectiveOptions;
        CancelCurrentRequest();
        if (TryRestorePage(CurrentRequestKey, selectedPath))
        {
            return;
        }
        await LoadFirstPageAsync(selectedPath);
    }

    private async Task NavigateAsync(
        string path,
        bool recordHistory,
        FileBrowserLocation? restoredLocation = null)
    {
        var normalized = NormalizePath(path);
        if (string.Equals(normalized, CurrentPath, StringComparison.Ordinal) && restoredLocation is null)
        {
            return;
        }

        if (recordHistory)
        {
            _backHistory.Push(CaptureLocation());
            RaisePropertyChanged(nameof(CanGoBack));
        }

        _preferredOptionsByPath[CurrentPath] = _preferredOptions;
        var destinationOptions = restoredLocation?.PreferredOptions ??
            (_preferredOptionsByPath.TryGetValue(normalized, out var savedOptions)
                ? savedOptions
                : _preferredOptions);
        CancelCurrentRequest();
        CurrentPath = normalized;
        _preferredOptions = destinationOptions;
        _preferredOptionsByPath[CurrentPath] = _preferredOptions;
        CurrentOptions = EffectiveOptions(CurrentPath, _preferredOptions);
        FilterText = restoredLocation?.QuickFilterText ?? string.Empty;
        SelectedItem = null;
        RebuildBreadcrumbs();
        RaisePropertyChanged(nameof(CanGoUp));
        RaisePropertyChanged(nameof(CanChooseNonNameSort));
        RaisePropertyChanged(nameof(CanChooseTypeFilter));

        if (TryRestorePage(CurrentRequestKey, restoredLocation?.SelectedPath))
        {
            LocationCommitted?.Invoke(CurrentPath);
            return;
        }
        await LoadFirstPageAsync(restoredLocation?.SelectedPath);
        if (string.Equals(CurrentPath, normalized, StringComparison.Ordinal) &&
            ContentState != FileBrowserContentState.Error)
        {
            LocationCommitted?.Invoke(CurrentPath);
        }
    }

    private async Task LoadFirstPageAsync(string? selectedPath = null)
    {
        var key = CurrentRequestKey;
        var request = BeginRequest();
        var loadsStorageSpace = string.IsNullOrWhiteSpace(key.Path);
        if (loadsStorageSpace)
        {
            IsLoadingStorageSpace = true;
        }
        IsLoading = true;
        IsLoadingMore = false;
        HasLoadMoreError = false;
        ContentState = FileBrowserContentState.Loading;
        try
        {
            var page = await _dataSource.LoadPageAsync(
                key.Path,
                0,
                _pageSize,
                key.Options,
                request.Token);
            if (!IsCurrent(request.Generation, key))
            {
                return;
            }

            _loadedItems.Clear();
            Items.Clear();
            _nextOffset = 0;
            _total = 0;
            AppendPage(page, requestedOffset: 0);
            if (loadsStorageSpace)
            {
                StorageSpace = page.StorageSpace;
                _hasLoadedStorageSpace = true;
                RaisePropertyChanged(nameof(IsStorageSpaceUnavailable));
            }
            SaveCurrentPage();
            ApplyQuickFilter(selectedPath);
        }
        catch (OperationCanceledException) when (!IsCurrent(request.Generation, key) || request.Token.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, key))
            {
                _loadedItems.Clear();
                Items.Clear();
                _nextOffset = 0;
                _total = 0;
                ContentState = FileBrowserContentState.Error;
                if (loadsStorageSpace)
                {
                    _hasLoadedStorageSpace = true;
                    RaisePropertyChanged(nameof(IsStorageSpaceUnavailable));
                }
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, key))
            {
                IsLoading = false;
                if (loadsStorageSpace)
                {
                    IsLoadingStorageSpace = false;
                }
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    private void AppendPage(FilePage page, int requestedOffset)
    {
        if (page.Offset != requestedOffset)
        {
            throw new InvalidDataException(
                $"File page offset {page.Offset} does not match requested offset {requestedOffset}.");
        }
        if (page.Items.Count == 0 && page.Total > requestedOffset)
        {
            throw new InvalidDataException(
                "File page did not advance while more items were reported.");
        }

        foreach (var item in page.Items)
        {
            if (_loadedItems.Any(existing =>
                    string.Equals(existing.Path, item.Path, StringComparison.Ordinal)))
            {
                continue;
            }

            _loadedItems.Add(new FileBrowserEntry(item));
        }

        _nextOffset = checked(requestedOffset + page.Items.Count);
        _total = Math.Max(page.Total, _nextOffset);
        RaisePropertyChanged(nameof(CanLoadMore));
    }

    private static PageSnapshot CreateFirstPageSnapshot(FilePage page)
    {
        if (page.Offset != 0 || page.Total < 0 || page.Items.Count > page.Total ||
            page.Items.Count == 0 && page.Total > 0)
        {
            throw new InvalidDataException("The first file page violates the navigation contract.");
        }
        var items = page.Items
            .GroupBy(item => item.Path, StringComparer.Ordinal)
            .Select(group => new FileBrowserEntry(group.First()))
            .ToArray();
        return new PageSnapshot(items, page.Items.Count, Math.Max(page.Total, page.Items.Count));
    }

    private void ApplyQuickFilter(string? selectedPath = null)
    {
        selectedPath ??= SelectedItem?.Path;
        var filtered = string.IsNullOrWhiteSpace(FilterText)
            ? _loadedItems
            : _loadedItems
                .Where(item => item.Name.Contains(FilterText, StringComparison.CurrentCultureIgnoreCase))
                .ToList();

        Items.Clear();
        foreach (var item in filtered)
        {
            Items.Add(item);
        }

        SelectedItem = selectedPath is null
            ? null
            : Items.FirstOrDefault(item => string.Equals(item.Path, selectedPath, StringComparison.Ordinal));
        ContentState = Items.Count > 0
            ? FileBrowserContentState.Content
            : !string.IsNullOrWhiteSpace(FilterText) || CurrentOptions.TypeFilter != FileListTypeFilter.All
                ? FileBrowserContentState.FilteredEmpty
                : FileBrowserContentState.Empty;
    }

    private FileBrowserLocation CaptureLocation() => new(
        CurrentPath,
        _preferredOptions,
        FilterText,
        SelectedItem?.Path);

    private void SaveCurrentPage() => _pageCache[CurrentRequestKey] = new PageSnapshot(
        _loadedItems.ToArray(),
        _nextOffset,
        _total);

    private bool TryRestorePage(FileBrowserRequestKey key, string? selectedPath)
    {
        if (!_pageCache.TryGetValue(key, out var snapshot))
        {
            return false;
        }

        _loadedItems.Clear();
        _loadedItems.AddRange(snapshot.Items);
        _nextOffset = snapshot.NextOffset;
        _total = snapshot.Total;
        IsLoading = false;
        IsLoadingMore = false;
        HasLoadMoreError = false;
        ApplyQuickFilter(selectedPath);
        RaisePropertyChanged(nameof(CanLoadMore));
        return true;
    }

    private (long Generation, CancellationToken Token) BeginRequest()
    {
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = new CancellationTokenSource();
        var generation = Interlocked.Increment(ref _generation);
        return (generation, _requestCancellation.Token);
    }

    private void CancelCurrentRequest()
    {
        Interlocked.Increment(ref _generation);
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
        IsLoading = false;
        IsLoadingMore = false;
        IsLoadingStorageSpace = false;
    }

    private bool IsCurrent(long generation, FileBrowserRequestKey key) =>
        !_disposed &&
        generation == Volatile.Read(ref _generation) &&
        key == CurrentRequestKey;

    private void RebuildBreadcrumbs()
    {
        Breadcrumbs.Clear();
        Breadcrumbs.Add(new FileBrowserBreadcrumb("/", string.Empty));

        var segments = CurrentPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var path = string.Empty;
        foreach (var segment in segments)
        {
            path += "/" + segment;
            Breadcrumbs.Add(new FileBrowserBreadcrumb(segment, path));
        }
    }

    private static FileListOptions EffectiveOptions(string path, FileListOptions preferredOptions) =>
        string.IsNullOrWhiteSpace(path)
            ? preferredOptions.NormalizeForSharedRoot()
            : preferredOptions;

    private static string ParentPath(string path)
    {
        var normalized = NormalizePath(path);
        var separator = normalized.LastIndexOf('/');
        return separator > 0 ? normalized[..separator] : string.Empty;
    }

    private static string NormalizePath(string path)
    {
        var trimmed = path.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed == "/")
        {
            return string.Empty;
        }

        return "/" + trimmed.Trim('/');
    }

    internal static string CanonicalLocationPath(string path)
    {
        if (path.Length == 0)
        {
            return string.Empty;
        }
        if (string.IsNullOrWhiteSpace(path) || path.Length > 4_096 || path[0] != '/' ||
            path == "/" || path.EndsWith("/", StringComparison.Ordinal) ||
            path.Contains("//", StringComparison.Ordinal) || path.Contains('\\') ||
            path.Any(char.IsControl))
        {
            throw new ArgumentException("The location path is not canonical.", nameof(path));
        }
        if (path.Split('/', StringSplitOptions.RemoveEmptyEntries).Any(segment => segment is "." or ".."))
        {
            throw new ArgumentException("The location path is not canonical.", nameof(path));
        }
        return path;
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    private void RaiseStorageSpaceProperties()
    {
        RaisePropertyChanged(nameof(HasStorageSpace));
        RaisePropertyChanged(nameof(IsStorageSpaceUnavailable));
        RaisePropertyChanged(nameof(StorageUsedPercent));
        RaisePropertyChanged(nameof(StorageUsageText));
        RaisePropertyChanged(nameof(StorageRemainingText));
        RaisePropertyChanged(nameof(StorageScopeText));
    }

    private static string FormatBytes(long bytes)
    {
        string[] unitKeys =
        [
            "NasDetailsByteUnitB",
            "NasDetailsByteUnitKB",
            "NasDetailsByteUnitMB",
            "NasDetailsByteUnitGB",
            "NasDetailsByteUnitTB",
        ];
        var scaled = (double)Math.Max(0, bytes);
        var unit = 0;
        while (scaled >= 1024 && unit < unitKeys.Length - 1)
        {
            scaled /= 1024;
            unit++;
        }
        var format = unit == 0 ? "N0" : scaled >= 10 ? "N1" : "N2";
        return LocalizationService.Current.Format(
            unitKeys[unit],
            scaled.ToString(format, CultureInfo.CurrentCulture));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        CancelCurrentRequest();
        _pageCache.Clear();
        _preferredOptionsByPath.Clear();
    }

    private sealed record PageSnapshot(
        IReadOnlyList<FileBrowserEntry> Items,
        int NextOffset,
        int Total);
}
