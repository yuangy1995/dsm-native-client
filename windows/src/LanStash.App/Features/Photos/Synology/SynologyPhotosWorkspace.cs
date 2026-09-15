using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public enum SynologyPhotosSection { Timeline, Folders, Albums, Sharing }
public sealed record SynologyPhotoMonth(int Year, int Month)
{
    public int Id => Year * 100 + Month;
    public DateOnly Date => new(Year, Month, 1);
    public override string ToString() => Date.ToString("Y", System.Globalization.CultureInfo.CurrentCulture);
}

/// <summary>Photos 的会话级状态；只请求当前页，刷新、导航和注销均隔离迟到响应。</summary>
public sealed partial class SynologyPhotosWorkspace : ObservableObject, IDisposable
{
    public const int PageSize = 100;
    private readonly ISynologyPhotosRepository _repository;
    private CancellationTokenSource _request = new();
    private CancellationTokenSource? _optionsRequest;
    private long _generation;
    private long _optionsGeneration;
    private bool _disposed;
    private int _nextOffset;
    private int _collectionOffset;
    private SynologyPhotoQuery _query = new SynologyPhotoQuery.Recent();
    private SynologyPhotoQuery? _timelineBase;
    private readonly HashSet<SynologyPhotoIdentity> _confirmedDeleted = [];
    private readonly HashSet<SynologyPhotoIdentity> _itemIds = [];
    private readonly List<SynologyPhotoCollection> _folderHistory = [];

    public SynologyPhotosWorkspace(ISynologyPhotosRepository repository)
    {
        _repository = repository;
        Preview = new(repository);
        Deletion = new(repository, RemoveConfirmed);
    }

    public event Action? ContentChanged;
    public event Action? RequestChanged;
    public ISynologyPhotosRepository Repository => _repository;
    public SynologyPhotoPreviewModel Preview { get; }
    public SynologyPhotoDeletionModel Deletion { get; }
    public ObservableCollection<SynologyPhoto> Items { get; } = [];
    public ObservableCollection<SynologyPhotoCollection> Collections { get; } = [];
    public ObservableCollection<SynologyPhotoSharedEntry> SharedEntries { get; } = [];
    public IReadOnlyList<SynologyPhotoSpace> Spaces { get; private set; } = [];
    public IReadOnlyList<SynologyPhotoDay> Days { get; private set; } = [];
    public IReadOnlyList<SynologyPhotoMonth> Months { get; private set; } = [];
    public IReadOnlySet<SynologyPhotoCategory> Categories { get; private set; } = new HashSet<SynologyPhotoCategory>();
    public SynologyPhotosSection Section { get; private set; }
    public SynologyPhotoCategory? Category { get; private set; }
    public SynologyPhotoCollection? CategoryItem { get; private set; }
    public SynologyPhotoCollection? Album { get; private set; }
    public SynologyPhotoShareScope ShareScope { get; private set; }
    public SynologyPhotoFilter Filter { get; private set; } = new();
    public SynologyPhotoFilterOptions Options { get; private set; } = new();
    public SynologyPhotoMonth? SelectedMonth { get; private set; }
    public int? PreviousMonthId { get; private set; }
    public string SearchText { get; private set; } = "";
    public string? ErrorKey { get; private set; }
    public string? PreviousErrorKey { get; private set; }
    public string? OptionsErrorKey { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsLoadingMore { get; private set; }
    public bool IsLoadingPrevious { get; private set; }
    public bool IsLoadingOptions { get; private set; }
    public bool HasMore { get; private set; }
    public bool HasMoreCollections { get; private set; }
    public bool HasLoaded { get; private set; }
    public bool IsActive => !_disposed;
    public bool IsFiltering => SearchText.Length != 0 || Filter.IsActive;
    public bool CanGoBack => _folderHistory.Count > 1 || Album is not null || Category is not null;
    public bool HasPrevious => PreviousMonthId is { } previous && Months.Any(month => month.Id > previous);
    public bool ShowsCategories => Section == SynologyPhotosSection.Albums && Album is null && Category is null;
    public bool ShowsTimeline => Section == SynologyPhotosSection.Timeline || Category is not null;
    public IReadOnlyList<SynologyPhotoCollection> FolderHistory => _folderHistory;

    public Task LoadIfNeededAsync() => !HasLoaded && !IsLoading ? RefreshAsync() : Task.CompletedTask;

    public async Task RefreshAsync()
    {
        if (_disposed || Deletion.IsBusy) return;
        var (generation, token) = StartRequest();
        IsLoading = true; HasLoaded = false; ErrorKey = null;
        Items.Clear(); _itemIds.Clear(); Collections.Clear(); SharedEntries.Clear();
        Days = []; Months = []; SelectedMonth = null; PreviousMonthId = null;
        _timelineBase = null; _nextOffset = 0; _collectionOffset = 0;
        HasMore = false; HasMoreCollections = false; PreviousErrorKey = null;
        Changed(content: true);
        try
        {
            var access = await _repository.AccessAsync(token);
            EnsureCurrent(generation, token);
            Spaces = access.Spaces.Where(space => space == SynologyPhotoSpace.Personal).ToArray();
            if (Spaces.Count == 0) { HasLoaded = true; return; }
            if (Section == SynologyPhotosSection.Sharing && Album is null)
            {
                var entries = await _repository.SharedEntriesAsync(ShareScope, 0, PageSize, token);
                EnsureCurrent(generation, token);
                AcceptShared(entries); HasLoaded = true; return;
            }
            if (Section == SynologyPhotosSection.Albums && Album is null && Category is null)
            {
                try
                {
                    var categories = await _repository.CategoriesAsync(token);
                    EnsureCurrent(generation, token); Categories = categories;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                { EnsureCurrent(generation, token); ErrorKey = "PhotosCategoriesFailed"; }
                var collections = await _repository.AlbumsAsync(0, PageSize, token);
                EnsureCurrent(generation, token);
                AcceptCollections(collections); HasLoaded = true; return;
            }
            if (Category is { } selected && CategoryItem is null && selected is not (SynologyPhotoCategory.Recent or SynologyPhotoCategory.Videos))
            {
                var collections = await _repository.CategoryItemsAsync(selected, 0, PageSize, token);
                EnsureCurrent(generation, token);
                AcceptCollections(collections); HasLoaded = true; return;
            }
            SynologyPhotoQuery? timelineQuery = null;
            var needsTimeline = false;
            if (Category == SynologyPhotoCategory.Recent) _query = new SynologyPhotoQuery.Recent();
            else if (Category is SynologyPhotoCategory.Subjects or SynologyPhotoCategory.Tags && CategoryItem is { } categoryItem)
            {
                timelineQuery = new SynologyPhotoQuery.Category(Category.Value, categoryItem.Id, 0, long.MaxValue);
                needsTimeline = true;
            }
            else if (Filter.IsActive)
            {
                timelineQuery = new SynologyPhotoQuery.Filtered(Filter, 0, long.MaxValue);
                needsTimeline = true;
            }
            else if (Section == SynologyPhotosSection.Folders)
            {
                if (_folderHistory.Count == 0)
                {
                    var root = await _repository.RootFolderAsync(token);
                    EnsureCurrent(generation, token); _folderHistory.Add(root);
                }
                var folderId = _folderHistory[^1].Id;
                var folders = await _repository.FoldersAsync(folderId, 0, PageSize, token);
                EnsureCurrent(generation, token); AcceptCollections(folders);
                _query = new SynologyPhotoQuery.Folder(folderId);
            }
            else if (Album is { } album) _query = new SynologyPhotoQuery.Album(album.Id);
            else
            {
                timelineQuery = SearchText.Length == 0 ? null : new SynologyPhotoQuery.Search(SearchText, 0, long.MaxValue);
                needsTimeline = true;
            }
            if (needsTimeline)
            {
                var days = await _repository.TimelineAsync(timelineQuery, token);
                EnsureCurrent(generation, token);
                Days = days;
                Months = days.Where(day => day.Count > 0).Select(day => new SynologyPhotoMonth(day.Date.Year, day.Date.Month))
                    .Distinct().OrderByDescending(month => month.Id).ToArray();
                var dates = days.Where(day => day.Count > 0).Select(day => day.Date).ToArray();
                if (dates.Length == 0) { HasLoaded = true; return; }
                var start = StartOfDay(dates.Min());
                var end = StartOfDay(dates.Max().AddDays(1)) - 1;
                _query = Constrain(timelineQuery ?? new SynologyPhotoQuery.Timeline(start, end), start, end);
                _timelineBase = _query;
            }
            var page = await _repository.PhotosAsync(_query, 0, PageSize, token);
            EnsureCurrent(generation, token);
            Accept(page, 0); HasLoaded = true;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) ErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoading = false; Changed(content: true); } }
    }

    public async Task SelectSectionAsync(SynologyPhotosSection section)
    {
        if (_disposed || Deletion.IsBusy) return;
        if (Section == section) { await LoadIfNeededAsync(); return; }
        Section = section; SearchText = ""; Filter = new(); Category = null; CategoryItem = null; Album = null;
        _folderHistory.Clear(); Categories = new HashSet<SynologyPhotoCategory>();
        await RefreshAsync();
    }

    public async Task SearchAsync(string text)
    {
        if (_disposed || Deletion.IsBusy || Section != SynologyPhotosSection.Timeline) return;
        SearchText = text.Trim(); Filter = new();
        await RefreshAsync();
    }

    public async Task ApplyFilterAsync(SynologyPhotoFilter filter)
    {
        if (_disposed || Deletion.IsBusy || Section != SynologyPhotosSection.Timeline) return;
        Filter = filter; SearchText = "";
        await RefreshAsync();
    }

    public async Task OpenCollectionAsync(SynologyPhotoCollection collection)
    {
        if (_disposed || Deletion.IsBusy || !Collections.Any(item => item.Id == collection.Id)) return;
        SearchText = "";
        if (Section == SynologyPhotosSection.Folders) _folderHistory.Add(collection);
        else if (Category is { } category)
        {
            CategoryItem = collection;
            if (category == SynologyPhotoCategory.People) Filter = new() { PersonId = collection.Id };
            if (category == SynologyPhotoCategory.Locations) Filter = new() { LocationId = collection.Id };
        }
        else Album = collection;
        await RefreshAsync();
    }

    public async Task OpenSharedAsync(SynologyPhotoSharedEntry entry)
    {
        if (_disposed || Deletion.IsBusy || entry.AlbumId is not { } id || !SharedEntries.Any(item => item.Id == entry.Id)) return;
        Album = new(id, entry.Title); await RefreshAsync();
    }

    public async Task OpenCategoryAsync(SynologyPhotoCategory category)
    {
        if (_disposed || Deletion.IsBusy || !Categories.Contains(category)) return;
        Category = category; CategoryItem = null; Album = null; SearchText = "";
        Filter = category == SynologyPhotoCategory.Videos ? new() { MediaType = 1 } : new();
        await RefreshAsync();
    }

    public async Task SelectShareScopeAsync(SynologyPhotoShareScope scope)
    {
        if (_disposed || Deletion.IsBusy || Section != SynologyPhotosSection.Sharing) return;
        ShareScope = scope; Album = null; await RefreshAsync();
    }

    public async Task GoBackAsync()
    {
        if (_disposed || Deletion.IsBusy) return;
        if (CategoryItem is not null) { CategoryItem = null; Filter = new(); }
        else if (Category is not null) { Category = null; Filter = new(); }
        else if (Album is not null) Album = null;
        else if (_folderHistory.Count > 1) _folderHistory.RemoveAt(_folderHistory.Count - 1);
        else return;
        await RefreshAsync();
    }

    public async Task LoadFilterOptionsAsync()
    {
        if (_disposed || IsLoadingOptions) return;
        _optionsRequest?.Cancel(); _optionsRequest?.Dispose();
        _optionsRequest = CancellationTokenSource.CreateLinkedTokenSource(_request.Token);
        var token = _optionsRequest.Token; var generation = _generation; var request = ++_optionsGeneration;
        IsLoadingOptions = true; OptionsErrorKey = null; Changed();
        try
        {
            var options = await _repository.FilterOptionsAsync(token);
            EnsureCurrent(generation, token);
            if (request == _optionsGeneration) Options = options;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception) { if (IsCurrent(generation, token) && request == _optionsGeneration) OptionsErrorKey = "PhotosFiltersFailed"; }
        finally { if (request == _optionsGeneration) { IsLoadingOptions = false; Changed(); } }
    }

    private (long Generation, CancellationToken Token) StartRequest()
    {
        var old = _request; _request = new(); _generation++; old.Cancel(); old.Dispose();
        _optionsRequest?.Cancel(); _optionsGeneration++; IsLoadingOptions = false;
        IsLoadingMore = false; IsLoadingPrevious = false;
        Preview.Close(); Deletion.CancelCandidate(); RequestChanged?.Invoke();
        return (_generation, _request.Token);
    }

    public void Suspend()
    {
        if (_disposed) return;
        StartRequest(); HasLoaded = false; IsLoading = false;
        Deletion.CancelCandidate(); Changed();
    }

    private bool IsCurrent(long generation, CancellationToken token) => !_disposed && generation == _generation && !token.IsCancellationRequested;
    private void EnsureCurrent(long generation, CancellationToken token)
    { if (!IsCurrent(generation, token)) throw new OperationCanceledException(token); }
    private void Changed(bool content = false) { RaisePropertyChanged(string.Empty); if (content) ContentChanged?.Invoke(); }
    internal static string FailureKey(Exception error) => error switch
    {
        SynologyPhotoException { Failure: SynologyPhotoFailure.Unavailable } => "PhotosServiceUnavailable",
        SynologyPhotoException { Failure: SynologyPhotoFailure.Permission } => "PhotosServicePermission",
        _ => "PhotosServiceInvalidResponse",
    };
    internal static long StartOfDay(DateOnly date)
    {
        var local = date.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds();
    }
    public void Dispose()
    {
        if (_disposed) return;
        Suspend(); _disposed = true; _request.Cancel(); _request.Dispose();
        _optionsRequest?.Dispose(); _optionsRequest = null; Preview.Dispose(); Deletion.Dispose();
        Items.Clear(); Collections.Clear(); SharedEntries.Clear(); Days = []; Months = []; Spaces = []; Options = new();
        _itemIds.Clear(); _confirmedDeleted.Clear(); _folderHistory.Clear();
        Changed(content: true);
    }
}
