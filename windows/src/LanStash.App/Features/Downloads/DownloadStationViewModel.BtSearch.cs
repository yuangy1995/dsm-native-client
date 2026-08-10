using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public sealed partial class DownloadStationViewModel
{
    private const int BtSearchTextMaxLength = 200;
    private const string BtSearchAllCategoryId = "_allcat_";

    private CancellationTokenSource? _btSearchCancellation;
    private long _btSearchGeneration;
    private bool _isBtSearchSessionOpen;
    private bool _hasBtSearchCatalog;
    private bool _isBtSearchBusy;
    private bool _btSearchCreationHandled;
    private DownloadBtSearchContentState _btSearchContentState =
        DownloadBtSearchContentState.Ready;
    private string _btSearchKeyword = string.Empty;
    private string _btSearchTitleFilter = string.Empty;
    private DownloadBtSearchModuleScope _btSearchModuleScope =
        DownloadBtSearchModuleScope.Enabled;
    private IReadOnlySet<string> _btSearchSelectedModuleIds =
        new HashSet<string>(StringComparer.Ordinal);
    private string? _btSearchCategoryId;
    private DownloadBtSearchSort _btSearchSort = DownloadBtSearchSort.Seeds;
    private DownloadBtSearchDirection _btSearchDirection =
        DownloadBtSearchDirection.Descending;
    private DownloadBtSearchResultItem? _selectedBtSearchResult;

    public ObservableCollection<DownloadBtSearchModuleOption> BtSearchModules { get; } = [];
    public ObservableCollection<DownloadBtSearchCategoryOption> BtSearchCategories { get; } = [];
    public ObservableCollection<DownloadBtSearchResultItem> BtSearchResults { get; } = [];

    public IReadOnlyList<DownloadBtSearchModuleScopeOption> BtSearchModuleScopeOptions { get; } =
    [
        new(
            DownloadBtSearchModuleScope.Enabled,
            LocalizationService.Current.Get("DownloadStationBtSearchModuleEnabled")),
        new(
            DownloadBtSearchModuleScope.All,
            LocalizationService.Current.Get("DownloadStationBtSearchModuleAll")),
        new(
            DownloadBtSearchModuleScope.Selected,
            LocalizationService.Current.Get("DownloadStationBtSearchModuleSelected")),
    ];

    public IReadOnlyList<DownloadBtSearchSortOption> BtSearchSortOptions { get; } =
    [
        new(
            DownloadBtSearchSort.Seeds,
            LocalizationService.Current.Get("DownloadStationBtSearchSortSeeds")),
        new(
            DownloadBtSearchSort.Size,
            LocalizationService.Current.Get("DownloadStationBtSearchSortSize")),
        new(
            DownloadBtSearchSort.Date,
            LocalizationService.Current.Get("DownloadStationBtSearchSortDate")),
        new(
            DownloadBtSearchSort.Title,
            LocalizationService.Current.Get("DownloadStationBtSearchSortTitle")),
        new(
            DownloadBtSearchSort.Peers,
            LocalizationService.Current.Get("DownloadStationBtSearchSortPeers")),
        new(
            DownloadBtSearchSort.Provider,
            LocalizationService.Current.Get("DownloadStationBtSearchSortProvider")),
        new(
            DownloadBtSearchSort.Leeches,
            LocalizationService.Current.Get("DownloadStationBtSearchSortLeeches")),
    ];

    public IReadOnlyList<DownloadBtSearchDirectionOption> BtSearchDirectionOptions { get; } =
    [
        new(
            DownloadBtSearchDirection.Descending,
            LocalizationService.Current.Get("DownloadStationBtSearchDirectionDescending")),
        new(
            DownloadBtSearchDirection.Ascending,
            LocalizationService.Current.Get("DownloadStationBtSearchDirectionAscending")),
    ];

    public bool HasBtSearchCapability =>
        _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available }
            repository &&
        repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.BtSearch);
    public bool IsBtSearchSessionOpen => _isBtSearchSessionOpen;
    public bool HasBtSearchCatalog => _hasBtSearchCatalog;
    public bool IsBtSearchBusy => _isBtSearchBusy;
    public bool CanEditBtSearchCriteria => IsBtSearchSessionOpen && !IsBtSearchBusy;
    public DownloadBtSearchContentState BtSearchContentState => _btSearchContentState;
    public string BtSearchKeyword => _btSearchKeyword;
    public string BtSearchTitleFilter => _btSearchTitleFilter;
    public DownloadBtSearchModuleScope BtSearchModuleScope => _btSearchModuleScope;
    public IReadOnlySet<string> BtSearchSelectedModuleIds => _btSearchSelectedModuleIds;
    public string? BtSearchCategoryId => _btSearchCategoryId;
    public DownloadBtSearchSort BtSearchSort => _btSearchSort;
    public DownloadBtSearchDirection BtSearchDirection => _btSearchDirection;
    public DownloadBtSearchResultItem? SelectedBtSearchResult => _selectedBtSearchResult;
    public bool IsBtSearchLoading => BtSearchContentState == DownloadBtSearchContentState.Loading;
    public bool IsBtSearchReady => BtSearchContentState == DownloadBtSearchContentState.Ready;
    public bool HasNoBtSearchProviders =>
        BtSearchContentState == DownloadBtSearchContentState.NoProviders;
    public bool IsBtSearchEmpty => BtSearchContentState == DownloadBtSearchContentState.Empty;
    public bool IsBtSearchFilteredEmpty =>
        BtSearchContentState == DownloadBtSearchContentState.FilteredEmpty;
    public bool HasBtSearchError => BtSearchContentState == DownloadBtSearchContentState.Error;
    public bool HasBtSearchResults => BtSearchContentState == DownloadBtSearchContentState.Content;
    public bool CanSearchBt =>
        IsBtSearchSessionOpen &&
        HasBtSearchCapability &&
        HasBtSearchCatalog &&
        BtSearchModules.Count > 0 &&
        !IsBtSearchBusy &&
        IsStableBtSearchText(BtSearchKeyword, required: true) &&
        IsStableBtSearchText(BtSearchTitleFilter, required: false) &&
        HasCurrentBtSearchCategory() &&
        HasAvailableBtSearchModuleScope();
    public bool CanCreateSelectedBtSearchResult =>
        IsBtSearchSessionOpen &&
        SelectedBtSearchResult is not null &&
        !_btSearchCreationHandled &&
        !IsBtSearchBusy &&
        !IsCreatingTask &&
        CanCreateTask;

    public async Task BeginBtSearchSessionAsync()
    {
        ThrowIfDisposed();
        if (!HasBtSearchCapability)
        {
            return;
        }

        CancelBtSearch(resetSession: true);
        _isBtSearchSessionOpen = true;
        RaisePropertyChanged(nameof(IsBtSearchSessionOpen));
        RaiseBtSearchProperties();
        await LoadBtSearchCatalogAsync();
    }

    public void EndBtSearchSession()
    {
        if (_disposed)
        {
            return;
        }
        CancelBtSearch(resetSession: true);
    }

    public void SetBtSearchKeyword(string? value)
    {
        ThrowIfDisposed();
        var next = value ?? string.Empty;
        if (string.Equals(_btSearchKeyword, next, StringComparison.Ordinal))
        {
            return;
        }
        _btSearchKeyword = next;
        RaisePropertyChanged(nameof(BtSearchKeyword));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchTitleFilter(string? value)
    {
        ThrowIfDisposed();
        var next = value ?? string.Empty;
        if (string.Equals(_btSearchTitleFilter, next, StringComparison.Ordinal))
        {
            return;
        }
        _btSearchTitleFilter = next;
        RaisePropertyChanged(nameof(BtSearchTitleFilter));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchModuleScope(DownloadBtSearchModuleScope value)
    {
        ThrowIfDisposed();
        if (_btSearchModuleScope == value)
        {
            return;
        }
        _btSearchModuleScope = value;
        RaisePropertyChanged(nameof(BtSearchModuleScope));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchSelectedModules(IEnumerable<string> values)
    {
        ThrowIfDisposed();
        var available = BtSearchModules.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        var next = values
            .Where(available.Contains)
            .ToHashSet(StringComparer.Ordinal);
        if (_btSearchSelectedModuleIds.SetEquals(next))
        {
            return;
        }
        _btSearchSelectedModuleIds = next;
        RaisePropertyChanged(nameof(BtSearchSelectedModuleIds));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchCategory(string? value)
    {
        ThrowIfDisposed();
        var next = value is null ||
            (string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl))
                ? null
                : value;
        if (string.Equals(_btSearchCategoryId, next, StringComparison.Ordinal))
        {
            return;
        }
        _btSearchCategoryId = next;
        RaisePropertyChanged(nameof(BtSearchCategoryId));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchSort(DownloadBtSearchSort value)
    {
        ThrowIfDisposed();
        if (_btSearchSort == value)
        {
            return;
        }
        _btSearchSort = value;
        RaisePropertyChanged(nameof(BtSearchSort));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SetBtSearchDirection(DownloadBtSearchDirection value)
    {
        ThrowIfDisposed();
        if (_btSearchDirection == value)
        {
            return;
        }
        _btSearchDirection = value;
        RaisePropertyChanged(nameof(BtSearchDirection));
        InvalidateBtSearchResultsForCriteriaChange();
    }

    public void SelectBtSearchResult(DownloadBtSearchResultItem? value)
    {
        ThrowIfDisposed();
        _selectedBtSearchResult = value is null
            ? null
            : BtSearchResults.FirstOrDefault(item =>
                string.Equals(item.DownloadUri, value.DownloadUri, StringComparison.Ordinal));
        RaisePropertyChanged(nameof(SelectedBtSearchResult));
        RaiseBtSearchProperties();
    }

    public async Task SearchBtAsync()
    {
        ThrowIfDisposed();
        if (!CanSearchBt ||
            _repository is not { } repository)
        {
            return;
        }

        var request = new DownloadBtSearchRequest(
            repository.ProfileId,
            BtSearchKeyword.Trim(),
            BtSearchModuleScope,
            BtSearchSelectedModuleIds,
            BtSearchCategoryId,
            BtSearchSort,
            BtSearchDirection,
            BtSearchTitleFilter.Trim());
        var hasFilters = HasNonDefaultBtSearchFilters(request);
        var operation = BeginBtSearchOperation();
        SetBtSearchBusy(true);
        SetBtSearchContentState(DownloadBtSearchContentState.Loading);
        ClearBtSearchResults();
        try
        {
            var results = await repository.SearchBtAsync(
                request,
                operation.Cancellation.Token);
            if (!IsCurrentBtSearch(operation.Generation, repository))
            {
                return;
            }
            foreach (var result in results)
            {
                BtSearchResults.Add(new DownloadBtSearchResultItem(result));
            }
            SetBtSearchContentState(BtSearchResults.Count > 0
                ? DownloadBtSearchContentState.Content
                : hasFilters
                    ? DownloadBtSearchContentState.FilteredEmpty
                    : DownloadBtSearchContentState.Empty);
        }
        catch (OperationCanceledException) when (operation.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentBtSearch(operation.Generation, repository))
            {
                SetBtSearchContentState(DownloadBtSearchContentState.Error);
            }
        }
        finally
        {
            if (IsCurrentBtSearch(operation.Generation, repository))
            {
                SetBtSearchBusy(false);
            }
        }
    }

    public Task RetryBtSearchAsync()
    {
        ThrowIfDisposed();
        return !HasBtSearchCatalog || HasNoBtSearchProviders
            ? LoadBtSearchCatalogAsync()
            : SearchBtAsync();
    }

    public void CancelCurrentBtSearch()
    {
        ThrowIfDisposed();
        if (!IsBtSearchSessionOpen || !IsBtSearchBusy)
        {
            return;
        }
        var catalogWasLoaded = HasBtSearchCatalog;
        CancelBtSearchOperation();
        SetBtSearchContentState(catalogWasLoaded
            ? BtSearchModules.Count == 0
                ? DownloadBtSearchContentState.NoProviders
                : DownloadBtSearchContentState.Ready
            : DownloadBtSearchContentState.Error);
    }

    public async Task CreateSelectedBtSearchResultAsync()
    {
        ThrowIfDisposed();
        if (!CanCreateSelectedBtSearchResult || SelectedBtSearchResult is not { } selected)
        {
            return;
        }

        // 同一弹窗会话只提交一次；结果未知时必须先回到任务列表核对，不能自动重放。
        _btSearchCreationHandled = true;
        RaiseBtSearchProperties();
        await CreateTaskAsync(selected.DownloadUri);
        RaiseBtSearchProperties();
    }

    private async Task LoadBtSearchCatalogAsync()
    {
        if (!IsBtSearchSessionOpen ||
            !HasBtSearchCapability ||
            _repository is not { } repository)
        {
            return;
        }

        var operation = BeginBtSearchOperation();
        SetBtSearchBusy(true);
        SetBtSearchContentState(DownloadBtSearchContentState.Loading);
        try
        {
            var catalog = await repository.LoadBtSearchCatalogAsync(operation.Cancellation.Token);
            if (!IsCurrentBtSearch(operation.Generation, repository))
            {
                return;
            }
            ApplyBtSearchCatalog(catalog);
            SetBtSearchContentState(BtSearchModules.Count == 0
                ? DownloadBtSearchContentState.NoProviders
                : DownloadBtSearchContentState.Ready);
        }
        catch (OperationCanceledException) when (operation.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentBtSearch(operation.Generation, repository))
            {
                _hasBtSearchCatalog = false;
                RaisePropertyChanged(nameof(HasBtSearchCatalog));
                SetBtSearchContentState(DownloadBtSearchContentState.Error);
            }
        }
        finally
        {
            if (IsCurrentBtSearch(operation.Generation, repository))
            {
                SetBtSearchBusy(false);
            }
        }
    }

    private void ApplyBtSearchCatalog(DownloadBtSearchCatalog catalog)
    {
        BtSearchModules.Clear();
        foreach (var module in catalog.Modules)
        {
            BtSearchModules.Add(new(module.Id, module.Title, module.IsEnabled));
        }
        _btSearchSelectedModuleIds = catalog.Modules
            .Where(module => module.IsEnabled)
            .Select(module => module.Id)
            .ToHashSet(StringComparer.Ordinal);

        BtSearchCategories.Clear();
        BtSearchCategories.Add(new(
            null,
            LocalizationService.Current.Get("DownloadStationBtSearchCategoryAll")));
        foreach (var category in catalog.Categories.Where(category =>
                     !string.Equals(
                         category.Id,
                         BtSearchAllCategoryId,
                         StringComparison.Ordinal)))
        {
            BtSearchCategories.Add(new(category.Id, category.Title));
        }
        _btSearchCategoryId = null;
        _hasBtSearchCatalog = true;
        RaisePropertyChanged(nameof(BtSearchSelectedModuleIds));
        RaisePropertyChanged(nameof(BtSearchCategoryId));
        RaisePropertyChanged(nameof(HasBtSearchCatalog));
        RaiseBtSearchProperties();
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginBtSearchOperation()
    {
        CancelBtSearchOperation();
        var cancellation = _btSearchCancellation = new CancellationTokenSource();
        return (_btSearchGeneration, cancellation);
    }

    private void CancelBtSearchOperation()
    {
        _btSearchGeneration++;
        _btSearchCancellation?.Cancel();
        _btSearchCancellation?.Dispose();
        _btSearchCancellation = null;
        SetBtSearchBusy(false);
    }

    private void CancelBtSearch(bool resetSession)
    {
        CancelBtSearchOperation();
        if (resetSession)
        {
            ResetBtSearchSession();
        }
    }

    private void ResetBtSearchSession()
    {
        _isBtSearchSessionOpen = false;
        _hasBtSearchCatalog = false;
        _btSearchKeyword = string.Empty;
        _btSearchTitleFilter = string.Empty;
        _btSearchModuleScope = DownloadBtSearchModuleScope.Enabled;
        _btSearchSelectedModuleIds = new HashSet<string>(StringComparer.Ordinal);
        _btSearchCategoryId = null;
        _btSearchSort = DownloadBtSearchSort.Seeds;
        _btSearchDirection = DownloadBtSearchDirection.Descending;
        _btSearchCreationHandled = false;
        BtSearchModules.Clear();
        BtSearchCategories.Clear();
        ClearBtSearchResults();
        SetBtSearchContentState(DownloadBtSearchContentState.Ready);
        RaisePropertyChanged(nameof(IsBtSearchSessionOpen));
        RaisePropertyChanged(nameof(HasBtSearchCatalog));
        RaisePropertyChanged(nameof(BtSearchKeyword));
        RaisePropertyChanged(nameof(BtSearchTitleFilter));
        RaisePropertyChanged(nameof(BtSearchModuleScope));
        RaisePropertyChanged(nameof(BtSearchSelectedModuleIds));
        RaisePropertyChanged(nameof(BtSearchCategoryId));
        RaisePropertyChanged(nameof(BtSearchSort));
        RaisePropertyChanged(nameof(BtSearchDirection));
        RaiseBtSearchProperties();
    }

    private void ClearBtSearchResults()
    {
        BtSearchResults.Clear();
        _selectedBtSearchResult = null;
        _btSearchCreationHandled = false;
        RaisePropertyChanged(nameof(SelectedBtSearchResult));
        RaiseBtSearchProperties();
    }

    private void InvalidateBtSearchResultsForCriteriaChange()
    {
        if (!IsBtSearchSessionOpen)
        {
            RaiseBtSearchProperties();
            return;
        }

        CancelBtSearchOperation();
        ClearBtSearchResults();
        SetBtSearchContentState(HasBtSearchCatalog && BtSearchModules.Count == 0
            ? DownloadBtSearchContentState.NoProviders
            : DownloadBtSearchContentState.Ready);
        RaiseBtSearchProperties();
    }

    private bool IsCurrentBtSearch(long generation, IDownloadStationRepository repository) =>
        !_disposed &&
        IsBtSearchSessionOpen &&
        generation == _btSearchGeneration &&
        ReferenceEquals(repository, _repository) &&
        ActiveProfileId == repository.ProfileId;

    private static bool HasNonDefaultBtSearchFilters(DownloadBtSearchRequest request) =>
        request.ModuleScope != DownloadBtSearchModuleScope.Enabled ||
        request.CategoryId is not null ||
        request.Sort != DownloadBtSearchSort.Seeds ||
        request.Direction != DownloadBtSearchDirection.Descending ||
        !string.IsNullOrWhiteSpace(request.TitleFilter);

    private bool HasCurrentBtSearchCategory() =>
        BtSearchCategories.Any(item =>
            string.Equals(item.Id, BtSearchCategoryId, StringComparison.Ordinal));

    private bool HasAvailableBtSearchModuleScope()
    {
        var available = BtSearchModules
            .Select(item => item.Id)
            .ToHashSet(StringComparer.Ordinal);
        return BtSearchModuleScope switch
        {
            DownloadBtSearchModuleScope.Enabled => BtSearchModules.Any(item => item.IsEnabled),
            DownloadBtSearchModuleScope.All => available.Count > 0,
            DownloadBtSearchModuleScope.Selected =>
                BtSearchSelectedModuleIds.Count > 0 &&
                BtSearchSelectedModuleIds.All(available.Contains),
            _ => false,
        };
    }

    private static bool IsStableBtSearchText(string value, bool required)
    {
        if (value.Any(char.IsControl))
        {
            return false;
        }
        var normalized = value.Trim();
        if (normalized.Length == 0)
        {
            return !required;
        }
        return normalized.Length <= BtSearchTextMaxLength;
    }

    private void SetBtSearchBusy(bool value)
    {
        if (_isBtSearchBusy == value)
        {
            return;
        }
        _isBtSearchBusy = value;
        RaisePropertyChanged(nameof(IsBtSearchBusy));
        RaiseBtSearchProperties();
    }

    private void SetBtSearchContentState(DownloadBtSearchContentState value)
    {
        if (_btSearchContentState == value)
        {
            return;
        }
        _btSearchContentState = value;
        RaisePropertyChanged(nameof(BtSearchContentState));
        RaisePropertyChanged(nameof(IsBtSearchLoading));
        RaisePropertyChanged(nameof(IsBtSearchReady));
        RaisePropertyChanged(nameof(HasNoBtSearchProviders));
        RaisePropertyChanged(nameof(IsBtSearchEmpty));
        RaisePropertyChanged(nameof(IsBtSearchFilteredEmpty));
        RaisePropertyChanged(nameof(HasBtSearchError));
        RaisePropertyChanged(nameof(HasBtSearchResults));
    }

    private void RaiseBtSearchAvailabilityProperties()
    {
        RaisePropertyChanged(nameof(HasBtSearchCapability));
        RaiseBtSearchProperties();
    }

    private void RaiseBtSearchProperties()
    {
        RaisePropertyChanged(nameof(CanEditBtSearchCriteria));
        RaisePropertyChanged(nameof(CanSearchBt));
        RaisePropertyChanged(nameof(CanCreateSelectedBtSearchResult));
    }
}
