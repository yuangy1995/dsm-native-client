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
    private readonly HashSet<(Guid, SynologyPhotoIdentity)> _appliedPhotoChanges = [];
    private readonly HashSet<Guid> _appliedRequestChanges = [];
    private readonly Dictionary<Guid, (SynologyPhotoChangeState State, int Count)> _appliedRecognition = [];
    private bool _needsPeopleRefresh;
    private readonly List<SynologyPhotoCollection> _folderHistory = [];

    public SynologyPhotosWorkspace(ISynologyPhotosRepository repository)
    {
        _repository = repository;
        Preview = new(repository);
        Slideshow = new(repository, Preview);
        Deletion = new(repository, RemoveConfirmed);
        Automatic = new(repository, ApplyAutomaticPreviewAsync);
    }

    public event Action? ContentChanged;
    public event Action? RequestChanged;
    public ISynologyPhotosRepository Repository => _repository;
    public SynologyPhotoPreviewModel Preview { get; }
    public SynologyPhotoSlideshowModel Slideshow { get; }
    public SynologyPhotoAutomaticModel Automatic { get; }
    public bool CanStartSlideshow => !_disposed && !IsLoading && !Deletion.IsBusy && !Slideshow.IsPresented && (Preview.Photo is not null || Items.Count > 0);
    public Task StartSlideshowAsync() => CanStartSlideshow && (Preview.Photo ?? Items.FirstOrDefault()) is { } photo
        ? Slideshow.StartAsync(_timelineBase ?? _query, photo, Preview.SimilarDetail) : Task.CompletedTask;
    public SynologyPhotoDeletionModel Deletion { get; }
    public ObservableCollection<SynologyPhoto> Items { get; } = [];
    public ObservableCollection<SynologyPhotoCollection> Collections { get; } = [];
    public ObservableCollection<SynologyPhotoSharedEntry> SharedEntries { get; } = [];
    public bool IsRequestList => Section == SynologyPhotosSection.Sharing && ShareScope == SynologyPhotoShareScope.Requests && Album is null;
    public IReadOnlyList<SynologyPhotoSharedEntry> VisibleSharedEntries => IsRequestList && SearchText.Length > 0
        ? SharedEntries.Where(item => item.Title.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)).ToArray() : SharedEntries;
    public IReadOnlyList<SynologyPhotoSpace> Spaces { get; private set; } = [];
    public bool CanManageSharedSpace { get; private set; }
    public bool IsAdministrator { get; private set; }
    public SynologyPhotoDisplaySettings? DisplaySettings { get; private set; }
    public IReadOnlyList<SynologyPhotoSpace> ConditionSpaces => Spaces.Where(space => space == SynologyPhotoSpace.Personal || CanManageSharedSpace).ToArray();
    public SynologyPhotoSpace SelectedSpace { get; private set; }
    public bool HasOriginalSource => Spaces.Contains(SelectedSpace);
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
    public bool HasAccess { get; private set; }
    public bool CanRefreshChanges => HasAccess && !IsLoading && !_disposed;
    public bool IsActive => !_disposed;
    public bool IsFiltering => SearchText.Length != 0 || Filter.IsActive;
    public bool CanGoBack => _folderHistory.Count > 1 || Album is not null || Category is not null;
    public bool HasPrevious => PreviousMonthId is { } previous && Months.Any(month => month.Id > previous);
    public bool ShowsCategories => Section == SynologyPhotosSection.Albums && Album is null && Category is null;
    public bool ShowsTimeline => Section == SynologyPhotosSection.Timeline || Category is not null;
    public IReadOnlyList<SynologyPhotoCollection> FolderHistory => _folderHistory;

    public bool NeedsChangesRefresh { get; private set; }
    public async Task ApplyConfirmedChangesAsync(Guid operationId, IReadOnlyList<SynologyPhotoChangeItem> changes)
    {
        if (_disposed) return;
        var applied = false;
        foreach (var change in changes.Where(item => item.State == SynologyPhotoChangeState.Completed && item.Updated is not null && !_appliedPhotoChanges.Contains((operationId, item.Original.Id))))
        {
            var index = Items.ToList().FindIndex(photo => photo.IsSameDeletionTarget(change.Original) && photo.AlbumContext == change.Original.AlbumContext);
            if (index >= 0) { Items[index] = change.Updated!; _appliedPhotoChanges.Add((operationId, change.Original.Id)); applied = true; }
        }
        if (applied) ContentChanged?.Invoke();
        if (HasLoaded && (applied || NeedsChangesRefresh)) await ReloadChangedPhotoWindowAsync();
    }

    public Task LoadIfNeededAsync() => !HasLoaded && !IsLoading ? RefreshAsync() : Task.CompletedTask;

    public async Task ApplyRecognitionChangeAsync(SynologyPhotoRecognitionChange change)
    {
        if (change.SimilarGroups.Count > 0) { await ApplySimilarChangeAsync(change); return; }
        if (IsConceptChange(change.Kind)) { await ApplyConceptChangeAsync(change); return; }
        if (_disposed || IsLoading || change.Space != SelectedSpace || Category != SynologyPhotoCategory.People || change.CompletedCount == 0) return;
        var marker = (change.State, change.CompletedCount);
        if (_appliedRecognition.GetValueOrDefault(change.Id) == marker) return;
        if (CategoryItem is null)
        {
            _needsPeopleRefresh = true;
            await ReloadPeopleCollectionsAsync();
            if (!_needsPeopleRefresh) _appliedRecognition[change.Id] = marker;
        }
        else
        {
            var generation = _generation; var token = _request.Token; var id = CategoryItem.Id;
            try
            {
                var people = await _repository.PeopleAsync(SelectedSpace, false, token); EnsureCurrent(generation, token);
                if (CategoryItem?.Id == id && people.SingleOrDefault(person => person.Person.Id == id) is { } current)
                { CategoryItem = current.Person; Changed(content: true); }
                // 隐藏或合并不删除当前已读照片；历史记录也不能覆盖另一次修改后的姓名。
                _appliedRecognition[change.Id] = marker;
                if (change.Kind is SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.ReassignPersonFaces or SynologyPhotoRecognitionKind.ManualFaces && change.TargetIds.Contains(id))
                    await ReloadChangedPhotoWindowAsync();
            }
            catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
            catch (Exception error) { if (IsCurrent(generation, token)) { ErrorKey = FailureKey(error); Changed(); } }
        }
    }

    private async Task ReloadPeopleCollectionsAsync()
    {
        if (_disposed || IsLoading || IsLoadingMore || Category != SynologyPhotoCategory.People || CategoryItem is not null) return;
        var generation = _generation; var token = _request.Token; IsLoadingMore = true; Changed();
        try
        {
            var people = await _repository.PeopleAsync(SelectedSpace, false, token); EnsureCurrent(generation, token);
            if (people.Any(person => person.Person.Space != SelectedSpace) || people.DistinctBy(person => person.Person.Id).Count() != people.Count) throw Invalid();
            Collections.Clear(); foreach (var person in people) Collections.Add(person.Person);
            _collectionOffset = people.Count; HasMoreCollections = false; _needsPeopleRefresh = false; ErrorKey = null;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) ErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoadingMore = false; Changed(content: true); } }
    }

    public async Task ApplyRequestChangesAsync(IReadOnlyList<SynologyPhotoRequestChange> changes)
    {
        if (_disposed || IsLoading || !IsRequestList) return;
        var completed = changes.Where(change => change.State == SynologyPhotoChangeState.Completed && !_appliedRequestChanges.Contains(change.Id)).ToArray();
        if (completed.Length == 0) return;
        foreach (var change in completed) _appliedRequestChanges.Add(change.Id);
        await RefreshAsync();
        if (ErrorKey is not null) foreach (var change in completed) _appliedRequestChanges.Remove(change.Id);
    }

    public async Task RefreshAsync()
    {
        if (_disposed || Deletion.IsBusy) return;
        var (generation, token) = StartRequest();
        _needsPeopleRefresh = false; _needsConceptRefresh = false;
        IsLoading = true; HasLoaded = false; HasAccess = false; ErrorKey = null; CurrentAlbum = null; CanManageSharedSpace = false; IsAdministrator = false;
        Items.Clear(); _itemIds.Clear(); _pagedPhotoIds.Clear(); Collections.Clear(); SharedEntries.Clear();
        Days = []; Months = []; SelectedMonth = null; PreviousMonthId = null;
        _timelineBase = null; _nextOffset = 0; _collectionOffset = 0;
        HasMore = false; HasMoreCollections = false; PreviousErrorKey = null;
        Changed(content: true);
        try
        {
            var access = await _repository.AccessAsync(token);
            EnsureCurrent(generation, token);
            HasAccess = true;
            Spaces = access.Spaces.Where(Enum.IsDefined).Distinct().ToArray();
            CanManageSharedSpace = access.CanManageSharedSpace;
            IsAdministrator = access.IsAdministrator;
            DisplaySettings = access.DisplaySettings;
            if (!Spaces.Contains(SelectedSpace))
            {
                SelectedSpace = Spaces.FirstOrDefault();
                ResetSourceNavigation();
            }
            if (Spaces.Count == 0 && Section is SynologyPhotosSection.Timeline or SynologyPhotosSection.Folders)
                Section = SynologyPhotosSection.Albums;
            await ReadAlbumPreferencesAsync(generation, token);
            if (Section == SynologyPhotosSection.Sharing && Album is null)
            {
                do
                {
                    var entries = await ReadSharedPageAsync(_collectionOffset, token); EnsureCurrent(generation, token); AcceptShared(entries);
                } while (IsRequestList && SearchText.Length > 0 && HasMoreCollections);
                HasLoaded = true; return;
            }
            if (Section == SynologyPhotosSection.Albums && Album is null && Category is null)
            {
                try
                {
                    var categories = HasOriginalSource
                        ? await _repository.CategoriesAsync(token, SelectedSpace)
                        : new HashSet<SynologyPhotoCategory>();
                    EnsureCurrent(generation, token); Categories = categories;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                { EnsureCurrent(generation, token); ErrorKey = "PhotosCategoriesFailed"; }
                var collections = await ReadAlbumsPageAsync(0, token);
                EnsureCurrent(generation, token);
                AcceptCollections(collections); HasLoaded = true; return;
            }
            if (Category is { } selected && CategoryItem is null && selected is not (SynologyPhotoCategory.Recent or SynologyPhotoCategory.Videos or SynologyPhotoCategory.Similar))
            {
                var collections = await _repository.CategoryItemsAsync(selected, 0, PageSize, token, SelectedSpace);
                EnsureCurrent(generation, token);
                AcceptCollections(collections); HasLoaded = true; return;
            }
            SynologyPhotoQuery? timelineQuery = null;
            var needsTimeline = false;
            if (Category == SynologyPhotoCategory.Recent) _query = new SynologyPhotoQuery.Recent();
            else if (Category == SynologyPhotoCategory.Similar)
            { timelineQuery = new SynologyPhotoQuery.Category(SynologyPhotoCategory.Similar, 0, 0, long.MaxValue); needsTimeline = true; }
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
                    var root = await _repository.RootFolderAsync(token, SelectedSpace);
                    EnsureCurrent(generation, token); _folderHistory.Add(root);
                }
                var folderId = _folderHistory[^1].Id;
                SynologyPhotoSort? sort = null;
                if (_repository.SupportsFolderManagement)
                {
                    try
                    {
                        var current = await _repository.FolderAsync(folderId, SelectedSpace, token); EnsureCurrent(generation, token);
                        sort = current.Sort; _folderHistory[^1] = current.Collection;
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    { EnsureCurrent(generation, token); ErrorKey = "PhotosFolderSortUnavailable"; }
                }
                var folders = await _repository.FoldersAsync(folderId, 0, PageSize, sort?.Descending == true, token, SelectedSpace);
                EnsureCurrent(generation, token); AcceptCollections(folders);
                _query = new SynologyPhotoQuery.Folder(folderId, sort);
            }
            else if (Album is { } album)
            {
                if (_repository.SupportsAlbumManagement)
                {
                    try
                    {
                        var current = await _repository.AlbumAsync(album.Id, token); EnsureCurrent(generation, token);
                        CurrentAlbum = current; Album = current.Collection;
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    { EnsureCurrent(generation, token); ErrorKey = "PhotosAlbumPreferencesFailed"; }
                }
                _query = new SynologyPhotoQuery.Album(album.Id, CurrentAlbum?.Sort);
            }
            else
            {
                timelineQuery = SearchText.Length == 0 ? null : new SynologyPhotoQuery.Search(SearchText, 0, long.MaxValue);
                needsTimeline = true;
            }
            if (needsTimeline)
            {
                timelineQuery = (timelineQuery ?? new SynologyPhotoQuery.Timeline(0, long.MaxValue)) with { Space = SelectedSpace };
                var days = await _repository.TimelineAsync(timelineQuery, token);
                EnsureCurrent(generation, token);
                Days = days;
                Months = days.Where(day => day.Count > 0).Select(day => new SynologyPhotoMonth(day.Date.Year, day.Date.Month))
                    .Distinct().OrderByDescending(month => month.Id).ToArray();
                var dates = days.Where(day => day.Count > 0).Select(day => day.Date).ToArray();
                if (dates.Length == 0) { HasLoaded = true; return; }
                // 与 macOS timeRange 一致：套件日历日期不等于本机时区；初始范围覆盖时区边界。
                // 纪元附近的照片不能产生负数参数，否则月份成功后整个照片列表会被本地拒绝。
                var start = Math.Max(0, UtcStartOfDay(dates.Min()) - 86400);
                var end = UtcStartOfDay(dates.Max()) + 172800;
                _query = Constrain(timelineQuery ?? new SynologyPhotoQuery.Timeline(start, end), start, end);
                _timelineBase = _query;
            }
            _query = _query with { Space = SelectedSpace };
            var page = await _repository.PhotosAsync(_query, 0, PageSize, token);
            EnsureCurrent(generation, token);
            Accept(page, 0); HasLoaded = true;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error)
        {
            if (IsCurrent(generation, token))
            {
                if (error is DsmException { AuthenticationFailure: true }) HasAccess = false;
                ErrorKey = FailureKey(error);
            }
        }
        finally { if (IsCurrent(generation, token)) { IsLoading = false; Changed(content: true); } }
    }

    public async Task SelectSpaceAsync(SynologyPhotoSpace space)
    {
        if (_disposed || Deletion.IsBusy || !Spaces.Contains(space) || SelectedSpace == space) return;
        SelectedSpace = space; Album = null;
        ResetSourceNavigation();
        await RefreshAsync();
    }

    private void ResetSourceNavigation()
    {
        SearchText = ""; Filter = new(); Category = null; CategoryItem = null;
        _folderHistory.Clear(); Categories = new HashSet<SynologyPhotoCategory>();
        Options = new(); OptionsErrorKey = null;
    }

    public async Task SelectSectionAsync(SynologyPhotosSection section)
    {
        if (_disposed || Deletion.IsBusy) return;
        if (HasLoaded && !HasOriginalSource && section is SynologyPhotosSection.Timeline or SynologyPhotosSection.Folders) return;
        if (Section == section) { await LoadIfNeededAsync(); return; }
        Section = section; SearchText = ""; Filter = new(); Category = null; CategoryItem = null; Album = null;
        _folderHistory.Clear(); Categories = new HashSet<SynologyPhotoCategory>();
        await RefreshAsync();
    }

    public async Task SearchAsync(string text)
    {
        if (_disposed || Deletion.IsBusy || Section != SynologyPhotosSection.Timeline && !IsRequestList) return;
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
        ShareScope = scope; Album = null; SearchText = ""; await RefreshAsync();
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
            var options = await _repository.FilterOptionsAsync(token, SelectedSpace);
            EnsureCurrent(generation, token);
            if (request == _optionsGeneration) Options = options;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception) { if (IsCurrent(generation, token) && request == _optionsGeneration) OptionsErrorKey = "PhotosFiltersFailed"; }
        finally { if (request == _optionsGeneration) { IsLoadingOptions = false; Changed(); } }
    }

    private (long Generation, CancellationToken Token) StartRequest()
    {
        _memberReloadCount = null;
        NeedsChangesRefresh = false;
        var old = _request; _request = new(); _generation++; old.Cancel(); old.Dispose();
        _optionsRequest?.Cancel(); _optionsGeneration++; IsLoadingOptions = false;
        Options = new(); OptionsErrorKey = null;
        IsLoadingMore = false; IsLoadingPrevious = false;
        Slideshow.Stop(); Preview.Close(); Deletion.CancelCandidate(); RequestChanged?.Invoke();
        return (_generation, _request.Token);
    }

    public void Suspend()
    {
        if (_disposed) return;
        StartRequest(); HasLoaded = false; HasAccess = false; IsLoading = false;
        Deletion.CancelCandidate(); Changed();
    }

    private bool IsCurrent(long generation, CancellationToken token) => !_disposed && generation == _generation && !token.IsCancellationRequested;
    private void EnsureCurrent(long generation, CancellationToken token)
    { if (!IsCurrent(generation, token)) throw new OperationCanceledException(token); }
    private void Changed(bool content = false) { RaisePropertyChanged(string.Empty); if (content) ContentChanged?.Invoke(); }
    internal static string FailureKey(Exception error) => error switch
    {
        DsmException { AuthenticationFailure: true } => "PhotosSessionExpired",
        DsmException { Code: 105 } => "PhotosServicePermission",
        DsmException { Code: 102 or 103 or 104 } => "PhotosServiceUnavailable",
        SynologyPhotoException { Failure: SynologyPhotoFailure.Unavailable } => "PhotosServiceUnavailable",
        SynologyPhotoException { Failure: SynologyPhotoFailure.Permission } => "PhotosServicePermission",
        _ => "PhotosServiceInvalidResponse",
    };
    internal static long StartOfDay(DateOnly date)
    {
        var local = date.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds();
    }
    private static long UtcStartOfDay(DateOnly date) =>
        new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue), TimeSpan.Zero).ToUnixTimeSeconds();
    public void Dispose()
    {
        if (_disposed) return;
        Suspend(); _disposed = true; _request.Cancel(); _request.Dispose();
        _optionsRequest?.Dispose(); _optionsRequest = null; Automatic.Dispose(); Slideshow.Dispose(); Preview.Dispose(); Deletion.Dispose();
        Items.Clear(); Collections.Clear(); SharedEntries.Clear(); Days = []; Months = []; Spaces = []; Options = new();
        _itemIds.Clear(); _pagedPhotoIds.Clear(); _confirmedDeleted.Clear(); _folderHistory.Clear();
        Changed(content: true);
    }
}
