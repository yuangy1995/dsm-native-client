using System.ComponentModel;
using System.Globalization;
using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class DownloadTaskDetailsContent : UserControl, IDisposable
{
    private readonly DownloadTaskDetailsModel _model;
    private readonly StackPanel _body = new() { Spacing = 12 };
    public DownloadTaskDetailsContent(DownloadTaskDetailsModel model)
    {
        _model = model;
        MinWidth = 300; MinHeight = 300; MaxHeight = 520;
        Content = new ScrollViewer { Content = _body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        model.PropertyChanged += Changed;
        Render();
    }
    private void Changed(object? sender, PropertyChangedEventArgs args) => Render();
    private static string L(string key) => LocalizationService.Current.Get(key);
    private void Render()
    {
        _body.Children.Clear();
        if (_model.IsLoading) _body.Children.Add(new ProgressRing { IsActive = true, Width = 28, Height = 28 });
        if (_model.HasError)
        {
            _body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = L("DownloadDetailsError") });
            var retry = new Button { Content = L("DownloadReadRetry"), MinHeight = 44 };
            retry.Click += async (_, _) => await _model.LoadAsync(); _body.Children.Add(retry);
        }
        if (_model.Details is not { } details) return;
        var item = new DownloadTaskItem(details.Task);
        Add("DownloadDetailsRemaining", item.RemainingText);
        Add("DownloadDetailsRatio", item.RatioText);
        Add("DownloadDetailsKind", details.Kind);
        Add("DownloadDetailsOwner", details.Owner);
        if (details.CreatedAt is long seconds && seconds <= 253402300799)
            Add("DownloadDetailsCreated", DateTimeOffset.FromUnixTimeSeconds(seconds).ToLocalTime().ToString("g", CultureInfo.CurrentCulture));
        Section("DownloadDetailsFiles", details.Files?.Select(file => (file.Name,
            LocalizationService.Current.Format("DownloadDetailsFileSize", DownloadTaskItem.FormatBytes(file.Downloaded), DownloadTaskItem.FormatBytes(file.Size)))));
        Section("DownloadDetailsTrackers", details.Trackers?.Select(tracker => (tracker.Origin,
            LocalizationService.Current.Format("DownloadDetailsConnections", Count(tracker.Seeds), Count(tracker.Peers)))));
        Section("DownloadDetailsPeers", details.Peers?.Select(peer => (peer.Address,
            LocalizationService.Current.Format("DownloadDetailsPeerValue", peer.Client ?? L("DownloadStationValueUnavailable"),
                peer.Progress?.ToString("P0", CultureInfo.CurrentCulture) ?? L("DownloadStationValueUnavailable"),
                DownloadTaskItem.FormatSpeed(peer.DownloadSpeed), DownloadTaskItem.FormatSpeed(peer.UploadSpeed)))));
    }
    private static string Count(int? count) => count?.ToString("N0", CultureInfo.CurrentCulture) ?? L("DownloadStationValueUnavailable");
    private void Add(string key, string? value)
    {
        var panel = new StackPanel { Spacing = 3 };
        panel.Children.Add(new TextBlock { Text = L(key), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new TextBlock { Text = value ?? L("DownloadStationValueUnavailable"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        _body.Children.Add(panel);
    }
    private void Section(string key, IEnumerable<(string Title, string Detail)>? rows)
    {
        var section = new StackPanel { Spacing = 8 };
        if (rows is null) section.Children.Add(new TextBlock { Text = L("DownloadDetailsNotProvided"), TextWrapping = TextWrapping.Wrap });
        else
        {
            foreach (var row in rows)
            {
                var panel = new StackPanel { Spacing = 3 };
                panel.Children.Add(new TextBlock { Text = row.Title, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                panel.Children.Add(new TextBlock { Text = row.Detail, TextWrapping = TextWrapping.Wrap });
                section.Children.Add(panel);
            }
            if (section.Children.Count == 0) section.Children.Add(new TextBlock { Text = L("DownloadDetailsNoItems") });
        }
        var expander = new Expander { Header = L(key), Content = section, HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch, IsExpanded = true };
        AutomationProperties.SetName(expander, L(key));
        _body.Children.Add(expander);
    }
    public void Dispose() => _model.PropertyChanged -= Changed;
}
