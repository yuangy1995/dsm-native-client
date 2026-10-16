using System.ComponentModel;
using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class DownloadRssContent : UserControl, IDisposable
{
    private readonly DownloadRssModel _model;
    private readonly ComboBox _sites = new() { DisplayMemberPath = nameof(DownloadRssSite.Title), HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 44 };
    private readonly AutoSuggestBox _search = new();
    private readonly ListView _feeds = new() { SelectionMode = ListViewSelectionMode.Single, DisplayMemberPath = nameof(DownloadRssFeed.Title), MinHeight = 120 };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _error = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly ProgressRing _progress = new() { Width = 28, Height = 28 };
    private readonly Button _refresh = new() { MinHeight = 44 };
    private readonly TextBlock _feedback = new() { TextWrapping = TextWrapping.Wrap };
    private bool _updating;
    public event Action? StateChanged;
    public DownloadRssContent(DownloadRssModel model)
    {
        _model = model; MinWidth = 300; MinHeight = 360; MaxHeight = 520;
        var root = new Grid { RowSpacing = 10 };
        for (var index = 0; index < 7; index++) root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        _sites.Header = L("DownloadRssSites"); AutomationProperties.SetName(_sites, L("DownloadRssSites"));
        _search.PlaceholderText = L("DownloadRssSearch"); AutomationProperties.SetName(_search, L("DownloadRssSearch"));
        AutomationProperties.SetName(_feeds, L("DownloadRssItems"));
        _error.Message = L("DownloadRssError");
        var retry = new Button { Content = L("DownloadReadRetry"), MinHeight = 44 };
        retry.Click += async (_, _) => await _model.LoadAsync(); _error.ActionButton = retry;
        _refresh.Content = L("DownloadRssUpdate"); _refresh.Click += async (_, _) => await _model.UpdateSiteAsync();
        FrameworkElement[] controls = [_sites, _refresh, _feedback, _search, _error, _progress, _empty, _feeds];
        for (var index = 0; index < controls.Length; index++) { Grid.SetRow(controls[index], index); root.Children.Add(controls[index]); }
        Content = root;
        _sites.SelectionChanged += async (_, _) => { if (!_updating && _sites.SelectedItem is DownloadRssSite site) await _model.SelectSiteAsync(site); };
        _feeds.SelectionChanged += (_, _) => { if (!_updating) _model.SelectFeed(_feeds.SelectedItem as DownloadRssFeed); };
        _search.TextChanged += (_, args) => { if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput) _model.Search(_search.Text); };
        _model.PropertyChanged += Changed; Render();
    }
    private static string L(string key) => LocalizationService.Current.Get(key);
    private void Changed(object? sender, PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        _updating = true;
        try
        {
            _sites.ItemsSource = _model.Sites; _sites.SelectedItem = _model.SelectedSite;
            _sites.IsEnabled = !_model.IsLoading && !_model.IsUpdating;
            _refresh.IsEnabled = !_model.IsLoading && !_model.IsUpdating && _model.SelectedSite is { IsUpdating: false };
            _feedback.Text = _model.FeedbackKey is { } key ? L(key) : ""; _feedback.Visibility = _model.FeedbackKey is null ? Visibility.Collapsed : Visibility.Visible;
            _feeds.ItemsSource = _model.VisibleFeeds; _feeds.SelectedItem = _model.SelectedFeed;
            _feeds.IsEnabled = !_model.IsLoading && !_model.IsUpdating && !_model.HasError;
            _progress.IsActive = _model.IsLoading; _progress.Visibility = _model.IsLoading ? Visibility.Visible : Visibility.Collapsed;
            _error.IsOpen = _model.HasError; _error.Visibility = _model.HasError ? Visibility.Visible : Visibility.Collapsed;
            _empty.Text = L(_model.Sites.Count == 0 ? "DownloadRssEmptySites" : _model.Feeds.Count == 0 ? "DownloadRssEmptyItems" : "DownloadRssFilteredEmpty");
            _empty.Visibility = !_model.IsLoading && !_model.HasError && _model.VisibleFeeds.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { _updating = false; }
        StateChanged?.Invoke();
    }
    public void Dispose() => _model.PropertyChanged -= Changed;
}
