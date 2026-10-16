using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class FileVfsBrowserDialog : ContentDialog, IDisposable
{
    private readonly FileVfsBrowserViewModel _model;
    private readonly LocalizationService _text = LocalizationService.Current;
    private readonly ListView _list = new() { MinHeight = 260, MaxHeight = 330, SelectionMode = ListViewSelectionMode.Single, IsItemClickEnabled = true };
    private readonly TextBox _filter = new();
    private readonly TextBlock _location = Label(), _empty = Label();
    private readonly ProgressRing _busy = new() { Width = 28, Height = 28 };
    private readonly InfoBar _message = new() { IsClosable = false };
    private readonly Button _up, _open, _refresh;
    private readonly ComboBox _sort = new();
    private bool _rendering, _disposed;
    public FileVfsBrowserDialog(FileVfsBrowserViewModel model, XamlRoot root,
        Func<FileVfsDownloadSource, Func<bool>, CancellationToken, Task<bool>> startDownload)
    {
        _model = model; XamlRoot = root; RequestedTheme = root.Content is FrameworkElement e ? e.ActualTheme : ElementTheme.Default;
        Title = _text.Format("VfsBrowserTitle", model.Profile.Alias); CloseButtonText = _text.Get("VfsBrowserBack");
        PrimaryButtonText = _text.Get("VfsBrowserDownload"); DefaultButton = ContentDialogButton.None;
        AutomationProperties.SetAutomationId(this, "FileVfsBrowserDialog");
        _up = Button("VfsBrowserUp", async () => await model.UpAsync());
        _open = Button("VfsBrowserOpen", async () => await model.OpenAsync());
        _refresh = Button("VfsBrowserRefresh", async () => await model.LoadAsync());
        _filter.Header = _text.Get("VfsBrowserFilter"); _filter.TextChanged += (_, _) => { if (!_rendering) model.SetFilter(_filter.Text); };
        AutomationProperties.SetAutomationId(_filter, "VfsBrowserFilter");
        _sort.Header = _text.Get("VfsBrowserSort");
        foreach (var value in Enum.GetValues<FileListSortField>()) _sort.Items.Add(new ComboBoxItem { Tag = value, Content = _text.Get(value switch
            { FileListSortField.Size => "FileBrowserSortSize.Text", FileListSortField.ModifiedTime => "FileBrowserSortModified.Text", _ => "FileBrowserSortName.Text" }) });
        _sort.SelectedIndex = 0; _sort.SelectionChanged += (_, _) => { if (!_rendering && _sort.SelectedItem is ComboBoxItem { Tag: FileListSortField field }) model.SetSort(field); };
        AutomationProperties.SetName(_list, _text.Get("VfsBrowserContents"));
        _list.SelectionChanged += (_, _) => { if (!_rendering) model.Select((_list.SelectedItem as ListViewItem)?.Tag as FileItem); };
        _list.ItemClick += async (_, args) => { if (args.ClickedItem is ListViewItem { Tag: FileItem file }) { model.Select(file); if (file.IsDirectory) await model.OpenAsync(); } };
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; actions.Children.Add(_up); actions.Children.Add(_open); actions.Children.Add(_refresh);
        var filters = new Grid { ColumnSpacing = 12 }; filters.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); filters.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        filters.Children.Add(_filter); Grid.SetColumn(_sort, 1); filters.Children.Add(_sort);
        var body = new StackPanel { Spacing = 12, MinWidth = 440, MaxWidth = 540 };
        var contents = new Grid { MinHeight = 260 };
        _empty.VerticalAlignment = VerticalAlignment.Center; _empty.HorizontalAlignment = HorizontalAlignment.Center;
        _empty.TextAlignment = TextAlignment.Center;
        foreach (var child in new UIElement[] { _list, _empty, _busy }) contents.Children.Add(child);
        foreach (var child in new UIElement[] { _location, actions, filters, _message, contents }) body.Children.Add(child);
        Content = new ScrollViewer { Content = body, MaxHeight = 490, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        PrimaryButtonClick += async (_, args) => { args.Cancel = true; await model.DownloadAsync(startDownload); };
        Opened += async (_, _) => await model.LoadAsync(); model.PropertyChanged += Changed; Render();
    }
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (_disposed || _rendering) return; _rendering = true;
        try
        {
            _location.Text = _model.Location; _filter.Text = _model.Filter;
            _busy.IsActive = _model.IsBusy; _busy.Visibility = Show(_model.IsBusy);
            _up.IsEnabled = _model.CanUp; _open.IsEnabled = _model.CanOpen; _refresh.IsEnabled = !_model.IsBusy;
            _filter.IsEnabled = _sort.IsEnabled = !_model.IsBusy && !_model.HasError;
            IsPrimaryButtonEnabled = _model.CanDownload;
            var key = _model.HasError ? "VfsBrowserLoadFailed" : _model.DownloadFailed ? "VfsBrowserDownloadFailed" : _model.DownloadStarted ? "VfsBrowserDownloadStarted" : null;
            _message.IsOpen = key is not null; _message.Message = key is null ? "" : _text.Get(key);
            _message.Severity = _model.DownloadStarted ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            var files = _model.VisibleItems.ToArray(); _list.Items.Clear();
            foreach (var file in files)
            {
                var content = new StackPanel { Spacing = 4 }; content.Children.Add(new TextBlock { Text = file.Name, TextWrapping = TextWrapping.WrapWholeWords });
                content.Children.Add(new TextBlock { Text = file.IsDirectory ? _text.Get("VfsBrowserFolder") : _text.Format("VfsBrowserFileSize", file.Size), Opacity = .7 });
                var item = new ListViewItem { Tag = file, Content = content, HorizontalContentAlignment = HorizontalAlignment.Stretch };
                _list.Items.Add(item); if (file == _model.Selected) _list.SelectedItem = item;
            }
            _list.IsEnabled = !_model.IsBusy; _list.Visibility = Show(files.Length > 0);
            _empty.Text = _text.Get(_model.Items.Count == 0 ? "VfsBrowserEmpty" : "VfsBrowserFilteredEmpty");
            _empty.Visibility = Show(!_model.IsBusy && !_model.HasError && files.Length == 0);
        }
        finally { _rendering = false; }
    }
    private Button Button(string key, Action action) { var button = new Button { Content = _text.Get(key), MinHeight = 40 }; AutomationProperties.SetAutomationId(button, key); button.Click += (_, _) => action(); return button; }
    private static TextBlock Label() => new() { TextWrapping = TextWrapping.WrapWholeWords };
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { if (_disposed) return; _disposed = true; _model.PropertyChanged -= Changed; _model.Dispose(); }
}
