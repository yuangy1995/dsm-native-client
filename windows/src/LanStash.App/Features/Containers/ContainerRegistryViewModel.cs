using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed record ContainerRegistryItem(ContainerRegistryImage Image)
{
    public string Name => Image.Name;
    public string Registry => Image.Registry;
    public string Description => Image.Description ?? "";
    public string StarsText => Image.StarCount is { } count ? LocalizationService.Current.Format("ContainerRegistryStars", count) : "";
    public string Badges => string.Join(" · ", new[]
    {
        Image.IsOfficial == true ? LocalizationService.Current.Get("ContainerRegistryOfficial") : null,
        Image.IsTrusted == true ? LocalizationService.Current.Get("ContainerRegistryTrusted") : null,
        Image.IsAutomated == true ? LocalizationService.Current.Get("ContainerRegistryAutomated") : null
    }.Where(value => value is not null));
}

public sealed class ContainerRegistryViewModel : ObservableObject, IDisposable
{
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    private IReadOnlyList<string> _allTags = [];
    public ObservableCollection<ContainerRegistryItem> Results { get; } = [];
    public ObservableCollection<string> Tags { get; } = [];
    public string Query { get; private set; } = "";
    public string TagFilter { get; private set; } = "";
    public string? SelectedTag { get; private set; }
    public ContainerRegistryItem? SelectedImage { get; private set; }
    public bool IsSearching { get; private set; }
    public bool IsLoadingTags { get; private set; }
    public bool HasSearched { get; private set; }
    public bool HasLoadedTags { get; private set; }
    public bool RequiresReconnect { get; private set; }
    public bool IsAvailable => !_disposed && _repository?.CanBrowseRegistry == true && !RequiresReconnect;
    public bool CanSearch => IsAvailable && !IsSearching && ContainerRegistryRules.IsValidQuery(Query);
    public bool CanSelect => IsAvailable && !IsSearching;
    public bool CanReloadTags => CanSelect && SelectedImage is not null && !IsLoadingTags;
    public bool IsTagFilterEmpty => HasLoadedTags && _allTags.Count > 0 && Tags.Count == 0;
    public string? SearchError { get; private set; }
    public string? TagsError { get; private set; }
    public string? QueryError => Query.Length > 0 && !ContainerRegistryRules.IsValidQuery(Query) ? L.Get("ContainerRegistryQueryInvalid") : null;

    public void Activate(IContainerManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; Notify();
    }
    public void SetQuery(string query)
    {
        if (_disposed || query == Query) return;
        Cancel(); Query = query; Results.Clear(); ClearSelection(); HasSearched = IsSearching = false; SearchError = null; Notify();
    }
    public async Task SearchAsync()
    {
        if (!CanSearch || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); var query = Query.Trim();
        IsSearching = true; HasSearched = false; SearchError = null; Results.Clear(); ClearSelection(); Notify();
        try
        {
            var results = await repository.SearchRegistryAsync(query, request.Token); if (!Current(request, repository)) return;
            foreach (var image in results) Results.Add(new(image)); HasSearched = true;
        }
        catch (Exception error)
        {
            if (Current(request, repository)) { SearchError = Error(error, "ContainerRegistrySearchFailed"); HasSearched = true; }
        }
        finally { if (Current(request, repository)) { IsSearching = false; Notify(); } }
    }
    public async Task SelectImageAsync(ContainerRegistryItem? image)
    {
        if (!CanSelect || image is not null && !Results.Contains(image) || image == SelectedImage) return;
        Cancel(); ClearSelection(); SelectedImage = image; Notify();
        if (image is not null) await ReloadTagsAsync();
    }
    public async Task ReloadTagsAsync()
    {
        if (!CanReloadTags || _repository is null || SelectedImage is null) return;
        var repository = _repository; var selected = SelectedImage; var request = BeginRequest();
        IsLoadingTags = true; HasLoadedTags = false; TagsError = null; _allTags = []; Tags.Clear(); SelectedTag = null; Notify();
        try
        {
            var tags = await repository.LoadRegistryTagsAsync(selected.Name, request.Token); if (!Current(request, repository) || SelectedImage != selected) return;
            _allTags = tags.ToArray(); HasLoadedTags = true; FilterTags();
        }
        catch (Exception error) { if (Current(request, repository)) TagsError = Error(error, "ContainerRegistryTagsFailed"); }
        finally { if (Current(request, repository)) { IsLoadingTags = false; Notify(); } }
    }
    public void SetTagFilter(string filter)
    { if (_disposed || filter == TagFilter) return; TagFilter = filter; FilterTags(); Notify(); }
    public void SelectTag(string? tag)
    { SelectedTag = !_disposed && IsAvailable && !IsLoadingTags && tag is not null && Tags.Contains(tag) ? tag : null; Notify(); }
    private void FilterTags()
    {
        Tags.Clear(); foreach (var tag in _allTags.Where(tag => tag.Contains(TagFilter, StringComparison.OrdinalIgnoreCase))) Tags.Add(tag);
        if (SelectedTag is not null && !Tags.Contains(SelectedTag)) SelectedTag = null;
    }
    private void ClearSelection()
    { SelectedImage = null; SelectedTag = null; TagFilter = ""; _allTags = []; Tags.Clear(); HasLoadedTags = IsLoadingTags = false; TagsError = null; }
    private string Error(Exception error, string fallback)
    {
        if (error is DsmException { AuthenticationFailure: true }) { RequiresReconnect = true; return L.Get("ContainerRegistrySignIn"); }
        return L.Get(error is DsmException { Code: 105 } ? "ContainerRegistryPermission" : fallback);
    }
    public void Deactivate()
    {
        Cancel(); _repository = null; Results.Clear(); ClearSelection(); Query = ""; SearchError = null;
        HasSearched = IsSearching = RequiresReconnect = false; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private Request BeginRequest() { Cancel(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void Cancel() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(Request request, IContainerManagerRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record Request(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
