using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

/// <summary>关闭或重新选择后，旧请求只结束自身，不能覆盖新对象。</summary>
public sealed class DownloadTaskDetailsModel(IDownloadStationRepository repository, DownloadTask original) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public DownloadTaskDetails? Details { get; private set; }
    public bool IsLoading { get; private set; }
    public bool HasError { get; private set; }
    public async Task LoadAsync()
    {
        if (_disposed) return;
        var generation = ++_generation;
        _cancellation?.Cancel();
        using var cancellation = _cancellation = new CancellationTokenSource();
        IsLoading = true; HasError = false; RaisePropertyChanged(string.Empty);
        try
        {
            var details = await repository.LoadTaskDetailsAsync(original.Id, cancellation.Token);
            if (generation != _generation) return;
            if (details.Task.Id != original.Id || details.Task.Title != original.Title || details.Task.Size != original.Size)
                throw new InvalidDataException("download.details.changed");
            Details = details;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch { if (generation == _generation) HasError = true; }
        finally
        {
            if (generation == _generation) { IsLoading = false; _cancellation = null; RaisePropertyChanged(string.Empty); }
        }
    }
    public void Dispose() { _disposed = true; ++_generation; _cancellation?.Cancel(); _cancellation = null; }
}

public sealed class DownloadRssModel(IDownloadStationRepository repository) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public IReadOnlyList<DownloadRssSite> Sites { get; private set; } = [];
    public IReadOnlyList<DownloadRssFeed> Feeds { get; private set; } = [];
    public DownloadRssSite? SelectedSite { get; private set; }
    public DownloadRssFeed? SelectedFeed { get; private set; }
    public bool IsLoading { get; private set; }
    public bool HasError { get; private set; }
    public bool IsUpdating { get; private set; }
    public string? FeedbackKey { get; private set; }
    public string SearchText { get; private set; } = string.Empty;
    public IReadOnlyList<DownloadRssFeed> VisibleFeeds => Feeds.Where(item => item.Title.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    public void Search(string text) { SearchText = text; SelectedFeed = null; RaisePropertyChanged(string.Empty); }
    public void SelectFeed(DownloadRssFeed? feed)
    { SelectedFeed = feed is null ? null : VisibleFeeds.FirstOrDefault(item => item.Id == feed.Id); RaisePropertyChanged(nameof(SelectedFeed)); }
    public Task LoadAsync() => ReadAsync(SelectedSite);
    public async Task UpdateSiteAsync()
    {
        if (_disposed || IsLoading || IsUpdating || SelectedSite is not { } site) return;
        var generation = ++_generation;
        using var cancellation = _cancellation = new CancellationTokenSource();
        IsUpdating = true; FeedbackKey = null; RaisePropertyChanged(string.Empty);
        try
        {
            var action = await repository.RefreshRssSiteAsync(site, cancellation.Token);
            if (generation != _generation) return;
            FeedbackKey = action.Items.All(item => item.Stage == DownloadActionStage.Confirmed) ? "DownloadRssUpdated"
                : action.RequiresReview ? "DownloadRssUpdating" : "DownloadRssUpdateFailed";
        }
        catch { if (generation == _generation) FeedbackKey = "DownloadRssUpdateFailed"; }
        finally { if (generation == _generation) { IsUpdating = false; _cancellation = null; RaisePropertyChanged(string.Empty); } }
        if (!_disposed && generation == _generation) await ReadAsync(site);
    }
    public Task SelectSiteAsync(DownloadRssSite site) => ReadAsync(site);
    private async Task ReadAsync(DownloadRssSite? selection)
    {
        if (_disposed || IsUpdating) return;
        var generation = ++_generation;
        _cancellation?.Cancel();
        using var cancellation = _cancellation = new CancellationTokenSource();
        IsLoading = true; HasError = false; SelectedFeed = null; RaisePropertyChanged(string.Empty);
        try
        {
            var sites = await repository.ListRssSitesAsync(cancellation.Token);
            var selected = selection is null ? sites.FirstOrDefault() : sites.SingleOrDefault(item => item.Id == selection.Id && item.IdentityDigest == selection.IdentityDigest);
            if (selection is not null && selected is null) throw new InvalidDataException("download.rss.changed");
            var feeds = selected is null ? [] : await repository.ListRssFeedsAsync(selected.Id, cancellation.Token);
            if (generation != _generation) return;
            Sites = sites; SelectedSite = selected; Feeds = feeds;
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch { if (generation == _generation) HasError = true; }
        finally
        {
            if (generation == _generation) { IsLoading = false; _cancellation = null; RaisePropertyChanged(string.Empty); }
        }
    }
    public void Dispose() { _disposed = true; ++_generation; _cancellation?.Cancel(); _cancellation = null; }
}
