using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class IsoMountDialog : ContentDialog, IDisposable
{
    private readonly IsoMountViewModel _model;
    private readonly LocalizationService _text = LocalizationService.Current;
    private readonly StackPanel _body = new() { Spacing = 12, MinWidth = 440, MaxWidth = 530 };
    private readonly InfoBar _message = new() { IsClosable = false };
    private readonly ProgressRing _busy = new() { Width = 28, Height = 28 };
    private readonly TextBox _filter = new();
    private readonly ComboBox _pending = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ListView _connections = new() { MaxHeight = 130, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _source = new() { TextWrapping = TextWrapping.WrapWholeWords };
    private readonly TextBlock _destination = new() { TextWrapping = TextWrapping.WrapWholeWords };
    private readonly TextBlock _disconnect = new() { TextWrapping = TextWrapping.Wrap };
    private readonly CheckBox _automatic = new(), _automaticRisk = new();
    private readonly StackPanel _form = new() { Spacing = 12 }, _browser = new() { Spacing = 8 };
    private readonly Button _new, _choose, _open;
    private bool _rendering, _disposed;
    public string? OpenPath { get; private set; }

    public IsoMountDialog(IsoMountViewModel model, XamlRoot root)
    {
        _model = model; XamlRoot = root; RequestedTheme = root.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default;
        Title = _text.Get("IsoTitle"); CloseButtonText = _text.Get("ActionClose"); SecondaryButtonText = _text.Get("FileShareRefreshAction");
        DefaultButton = ContentDialogButton.None;
        AutomationProperties.SetAutomationId(this, "IsoMountDialog");
        _filter.Header = _text.Get("IsoFilter"); _filter.TextChanged += (_, _) => Render();
        _pending.Header = _text.Get("IsoPendingList");
        _pending.SelectionChanged += (_, _) => { if (!_rendering && _pending.SelectedItem is ComboBoxItem { Tag: IsoMountProgress item }) _model.SelectPending(item); };
        _connections.SelectionChanged += (_, _) => { if (!_rendering && _connections.SelectedItem is ListViewItem { Tag: IsoMountConnection item }) _model.Select(item); };
        AutomationProperties.SetName(_connections, _text.Get("IsoConnections"));
        _new = Button("IsoNew", () => _model.NewMount());
        _choose = Button("IsoChoose", async () => await _model.BrowseAsync(""));
        _open = Button("IsoOpen", () => { OpenPath = _model.Selected?.MountPoint ?? (_model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess && !_model.Progress.Change.IsUnmount ? _model.Progress.Change.MountPoint : null); if (OpenPath is not null) Hide(); });
        _automatic.Content = _text.Get("IsoAutomatic");
        _automatic.Checked += (_, _) => ChangeAutomatic(); _automatic.Unchecked += (_, _) => ChangeAutomatic();
        _automaticRisk.Content = Label(_text.Get("IsoAutomaticRisk"));
        _automaticRisk.Checked += (_, _) => ConfirmAutomatic(); _automaticRisk.Unchecked += (_, _) => ConfirmAutomatic();
        _disconnect.Text = _text.Get("IsoDisconnectRisk");
        _form.Children.Add(_source); _form.Children.Add(_destination); _form.Children.Add(_choose);
        _form.Children.Add(_automatic); _form.Children.Add(_automaticRisk); _form.Children.Add(_disconnect);
        foreach (var child in new UIElement[] { _busy, _message, _filter, _connections, _empty, _pending, _open, _new, _form, _browser }) _body.Children.Add(child);
        Content = new ScrollViewer { Content = _body, MaxHeight = 490, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        PrimaryButtonClick += async (_, args) => { args.Cancel = true; await _model.SaveAsync(); };
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await _model.LoadAsync(); };
        Opened += async (_, _) => await _model.LoadAsync();
        _model.PropertyChanged += Changed; Render();
    }
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Render();
    private void ChangeAutomatic() { if (_rendering) return; _model.Automatic = _automatic.IsChecked == true; _model.DraftChanged(); }
    private void ConfirmAutomatic() { if (_rendering) return; _model.ConfirmedAutomatic = _automaticRisk.IsChecked == true; _model.Notify(); }
    private void Render()
    {
        if (_disposed || _rendering) return;
        _rendering = true;
        try
        {
            _busy.IsActive = _model.IsBusy; _busy.Visibility = Show(_model.IsBusy);
            PrimaryButtonText = _text.Get(_model.Selected is null && _model.Progress?.Change.IsUnmount != true ? "IsoMount" : "IsoUnmount");
            IsPrimaryButtonEnabled = _model.CanSave; IsSecondaryButtonEnabled = !_model.IsBusy;
            _message.IsOpen = _model.MessageKey is not null;
            _message.Message = _model.MessageKey is { } message ? _text.Get(message) : "";
            _message.Severity = _model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            var all = _model.Inventory?.IsoItems ?? [];
            _filter.Visibility = Show(all.Count > 0);
            var visible = all.Where(item => item.Source.Contains(_filter.Text, StringComparison.CurrentCultureIgnoreCase) ||
                item.MountPoint.Contains(_filter.Text, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            _connections.Items.Clear();
            foreach (var item in visible)
            {
                var row = new ListViewItem { Content = Label(_text.Format("IsoConnection", item.Source, item.MountPoint)), Tag = item };
                _connections.Items.Add(row); if (item == _model.Selected) _connections.SelectedItem = row;
            }
            _connections.IsEnabled = !_model.IsBusy;
            _empty.Text = _text.Get(all.Count == 0 ? "IsoEmpty" : "IsoFilteredEmpty");
            _empty.Visibility = Show(visible.Length == 0 && (all.Count > 0 || _model.Source is null) && !_model.IsBusy && !_model.LoadFailed);
            _pending.Items.Clear();
            foreach (var item in _model.Pending)
            {
                var row = new ComboBoxItem { Content = item.Change.MountPoint, Tag = item }; _pending.Items.Add(row);
                if (item.Change.RequestId == _model.Progress?.Change.RequestId) _pending.SelectedItem = row;
            }
            _pending.Visibility = Show(_model.Pending.Count > 0); _pending.IsEnabled = !_model.IsBusy;
            _open.Visibility = Show(_model.Selected is not null || _model.Progress is { Outcome.Status: MutationResultStatus.ConfirmedSuccess, Change.IsUnmount: false });
            _open.IsEnabled = !_model.IsBusy && !_model.IsPending;
            _new.Visibility = Show(_model.Source is not null && (_model.Selected is not null || _model.Progress is not null));
            _new.IsEnabled = !_model.IsBusy;
            var unmount = _model.Selected is not null || _model.Progress?.Change.IsUnmount == true;
            var source = _model.Progress?.Change.Source ?? _model.Source;
            _form.Visibility = Show((unmount || source is not null) && !(unmount && _model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess));
            _source.Text = _text.Format("IsoSource", _model.Selected?.Source ?? _model.Progress?.Change.Existing?.Source ?? source?.Path ?? "");
            _destination.Text = _text.Format("IsoDestination", _model.Destination.Length == 0 ? _text.Get("IsoNoDestination") : _model.Destination);
            _choose.Visibility = Show(!unmount); _choose.IsEnabled = _model.CanEdit;
            _automatic.Visibility = Show(!unmount); _automatic.IsEnabled = _model.CanEdit; _automatic.IsChecked = _model.Automatic;
            _automaticRisk.Visibility = Show(!unmount && _model.Automatic); _automaticRisk.IsEnabled = _model.CanEdit; _automaticRisk.IsChecked = _model.ConfirmedAutomatic;
            _disconnect.Visibility = Show(unmount);
            RenderBrowser();
        }
        finally { _rendering = false; }
    }
    private void RenderBrowser()
    {
        _browser.Children.Clear(); _browser.Visibility = Show(_model.IsBrowsing);
        if (!_model.IsBrowsing) return;
        _browser.Children.Add(Label(_model.BrowserPath.Length == 0 ? _text.Get("FileLocationsSharesLabel.Text") : _model.BrowserPath));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var up = Button("IsoUp", async () => await _model.BrowseAsync(_model.BrowserPath.LastIndexOf('/') > 0 ? _model.BrowserPath[.._model.BrowserPath.LastIndexOf('/')] : ""));
        up.IsEnabled = !_model.IsLoadingFolders && _model.BrowserPath.Length > 0;
        var use = Button("IsoUseFolder", () => _model.ChooseFolder()); use.IsEnabled = !_model.IsLoadingFolders && _model.CanChooseFolder;
        actions.Children.Add(up); actions.Children.Add(use); actions.Children.Add(Button("ActionCancel", () => _model.CancelBrowse())); _browser.Children.Add(actions);
        if (_model.IsLoadingFolders) { _browser.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 }); return; }
        if (_model.FolderFailed) { _browser.Children.Add(Label(_text.Get("IsoFolderFailed"))); return; }
        var list = new ListView { Height = 140, SelectionMode = ListViewSelectionMode.Single };
        AutomationProperties.SetName(list, _text.Get("IsoChoose"));
        foreach (var folder in _model.Folders) list.Items.Add(new ListViewItem { Content = folder.Name, Tag = folder });
        list.SelectionChanged += async (_, _) => { if (list.SelectedItem is ListViewItem { Tag: FileCopyMoveFolder folder }) await _model.BrowseAsync(folder.Path, folder.CanWrite); };
        _browser.Children.Add(list);
    }
    private Button Button(string key, Action action)
    {
        var button = new Button { Content = _text.Get(key), MinHeight = 40 };
        AutomationProperties.SetAutomationId(button, key); button.Click += (_, _) => action(); return button;
    }
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.WrapWholeWords };
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { if (_disposed) return; _disposed = true; _model.PropertyChanged -= Changed; _model.Dispose(); }
}
