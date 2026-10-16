using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed class FileVfsDialog : ContentDialog, IDisposable
{
    private readonly FileVfsViewModel _model;
    private readonly LocalizationService _text = LocalizationService.Current;
    private readonly StackPanel _body = new() { Spacing = 12, MinWidth = 440, MaxWidth = 540 };
    private readonly InfoBar _message = new() { IsClosable = false };
    private readonly ProgressRing _busy = new() { Width = 28, Height = 28 };
    private readonly TextBox _filter = new();
    private readonly ListView _list = new() { MaxHeight = 160, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBlock _empty = Label(""), _selected = Label(""), _warning = Label("");
    private readonly StackPanel _form = new() { Spacing = 10 }, _actions = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly ComboBox _protocol = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox _host = new(), _alias = new(), _account = new(), _folder = new(), _encoding = new();
    private readonly NumberBox _port = new() { Minimum = 1, Maximum = 65535, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    private readonly PasswordBox _password = new();
    private readonly CheckBox _replace = new(), _single = new(), _cleartext = new();
    private readonly Expander _advanced = new() { HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private readonly Button _new, _newCloud, _reauthorize, _authorize, _cancelAuthorization, _edit, _connect, _disconnect, _remove, _browse;
    public FileVfsProfile? BrowseRequested { get; private set; }
    private bool _rendering, _disposed;
    private FileVfsProfile? _passwordProfile;
    private FileVfsAction? _passwordAction;

    public FileVfsDialog(FileVfsViewModel model, XamlRoot root, Func<Uri, Task<bool>>? openBrowser = null)
    {
        _model = model; XamlRoot = root; RequestedTheme = root.Content is FrameworkElement element ? element.ActualTheme : ElementTheme.Default;
        Title = _text.Get("VfsTitle"); CloseButtonText = _text.Get("ActionClose"); SecondaryButtonText = _text.Get("FileShareRefreshAction");
        DefaultButton = ContentDialogButton.None; AutomationProperties.SetAutomationId(this, "FileVfsDialog");
        _filter.Header = _text.Get("VfsFilter"); _filter.TextChanged += (_, _) => Render();
        AutomationProperties.SetName(_list, _text.Get("VfsTitle"));
        _list.SelectionChanged += (_, _) => { if (!_rendering && _list.SelectedItem is ListViewItem { Tag: FileVfsProfile p }) _model.Select(p); };
        _new = Button("VfsNew", () => _model.NewConnection()); _edit = Button("VfsEdit", async () => await _model.EditAsync());
        _newCloud = Button("VfsCloudNew", () => _model.NewCloud());
        _reauthorize = Button("VfsCloudReauthorize", () => _model.Reauthorize());
        _authorize = Button("VfsCloudAuthorize", async () => await _model.AuthorizeCloudAsync(openBrowser ?? (async uri => await Windows.System.Launcher.LaunchUriAsync(uri))));
        _cancelAuthorization = Button("VfsCloudCancel", () => _model.CancelCloud());
        _connect = Button("VfsConnect", () => _model.ChooseAction(FileVfsAction.Connect));
        _disconnect = Button("VfsDisconnect", () => _model.ChooseAction(FileVfsAction.Disconnect));
        _remove = Button("VfsRemove", () => _model.ChooseAction(FileVfsAction.RemoveSavedProfile));
        _browse = Button("VfsBrowse", () => { if (_model.CanBrowse) { BrowseRequested = _model.Selected; Hide(); } });
        foreach (var button in new[] { _browse, _edit, _reauthorize, _connect, _disconnect, _remove }) _actions.Children.Add(button);
        _protocol.Header = _text.Get("VfsProtocol");
        _protocol.SelectionChanged += (_, _) =>
        {
            if (_rendering || _protocol.SelectedItem is not ComboBoxItem { Tag: FileVfsProtocol p }) return;
            if (_model.IsCloud) { _model.NewCloud(p.Id); return; }
            if (_model.Draft is not { } draft) return;
            _model.UpdateDraft(draft with { Protocol = p.Id, Port = p.DefaultPort ?? 0 }, _model.ReplacePassword);
        };
        Field(_host, "VfsHost"); Field(_alias, "VfsAlias"); Field(_account, "VfsAccount"); Field(_folder, "VfsFolder"); Field(_encoding, "VfsEncoding");
        _port.Header = _text.Get("VfsPort"); AutomationProperties.SetAutomationId(_port, "VfsPort");
        _port.ValueChanged += (_, _) => DraftChanged();
        _password.Header = _text.Get("VfsPassword"); AutomationProperties.SetAutomationId(_password, "VfsPassword");
        _replace.Content = _text.Get("VfsReplacePassword"); _single.Content = _text.Get("VfsSingleConnection");
        _cleartext.Content = Label(_text.Get("VfsCleartextRisk"));
        _replace.Checked += (_, _) => DraftChanged(); _replace.Unchecked += (_, _) => { if (!_rendering) _password.Password = ""; DraftChanged(); };
        _single.Checked += (_, _) => DraftChanged(); _single.Unchecked += (_, _) => DraftChanged();
        _cleartext.Checked += (_, _) => ConfirmCleartext(); _cleartext.Unchecked += (_, _) => ConfirmCleartext();
        _password.PasswordChanged += (_, _) => { if (!_rendering) { _model.ConfirmedCleartext = false; _model.Notify(); } };
        _advanced.Header = _text.Get("VfsAdvanced");
        var advanced = new StackPanel { Spacing = 10 }; advanced.Children.Add(_folder); advanced.Children.Add(_encoding); advanced.Children.Add(_single); _advanced.Content = advanced;
        foreach (var child in new UIElement[] { _protocol, _alias, _host, _port, _account, _replace, _password, _advanced, _authorize, _cancelAuthorization }) _form.Children.Add(child);
        foreach (var child in new UIElement[] { _busy, _message, _filter, _list, _empty, _new, _newCloud, _selected, _actions, _warning, _cleartext, _form }) _body.Children.Add(child);
        Content = new ScrollViewer { Content = _body, MaxHeight = 490, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; var password = _password.Password;
            _rendering = true; _password.Password = ""; _rendering = false;
            await _model.SaveAsync(password);
        };
        SecondaryButtonClick += async (_, args) => { args.Cancel = true; await _model.LoadAsync(); };
        Opened += async (_, _) => await _model.LoadAsync(); _model.PropertyChanged += Changed; Render();
    }
    private void Field(TextBox field, string key) { field.Header = _text.Get(key); AutomationProperties.SetAutomationId(field, key); field.TextChanged += (_, _) => DraftChanged(); }
    private void DraftChanged()
    {
        if (_rendering) return;
        if (_model.IsCloud) { _model.UpdateCloudAlias(_alias.Text); return; }
        if (_model.Draft is not { } draft) return;
        _model.UpdateDraft(draft with { Hostname = _host.Text, Alias = _alias.Text, Account = _account.Text, Folder = _folder.Text,
            Codepage = _encoding.Text, Port = double.IsNaN(_port.Value) || _port.Value != Math.Truncate(_port.Value) ? 0 : (int)_port.Value,
            UsesOneConnection = _single.IsChecked == true }, _replace.IsChecked == true);
    }
    private void ConfirmCleartext() { if (_rendering) return; _model.ConfirmedCleartext = _cleartext.IsChecked == true; _model.Notify(); }
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (_disposed || _rendering) return;
        _rendering = true;
        try
        {
            _busy.IsActive = _model.IsBusy; _busy.Visibility = Show(_model.IsBusy);
            PrimaryButtonText = _text.Get(_model.Action switch { FileVfsAction.Connect => "VfsConnect", FileVfsAction.Disconnect => "VfsDisconnect", FileVfsAction.RemoveSavedProfile => "VfsRemove", FileVfsAction.Create or FileVfsAction.CreateCloud => "VfsCreateSave", _ => "VfsSave" });
            IsPrimaryButtonEnabled = _model.CanSave; IsSecondaryButtonEnabled = !_model.IsBusy;
            _message.IsOpen = _model.MessageKey is not null; _message.Message = _model.MessageKey is { } key ? _text.Get(key) : "";
            _message.Severity = _model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            var visible = _model.Profiles.Where(p => p.Alias.Contains(_filter.Text, StringComparison.CurrentCultureIgnoreCase) || p.ProtocolName.Contains(_filter.Text, StringComparison.CurrentCultureIgnoreCase)).ToArray();
            _list.Items.Clear();
            foreach (var profile in visible)
            {
                var row = new ListViewItem { Tag = profile, Content = Label(_text.Format("VfsRow", profile.Alias, profile.ProtocolName,
                    _text.Get(profile.State switch { FileVfsState.Connected => "VfsConnected", FileVfsState.Disconnected => "VfsDisconnected", _ => "VfsStateUnknown" }))) };
                _list.Items.Add(row); if (profile == _model.Selected) _list.SelectedItem = row;
            }
            _list.IsEnabled = !_model.IsBusy && !_model.IsPending;
            _filter.Visibility = Show(_model.Profiles.Count > 0);
            _empty.Text = _text.Get(_model.Profiles.Count == 0 ? "VfsEmpty" : "VfsFilteredEmpty");
            _empty.Visibility = Show(visible.Length == 0 && !_model.IsBusy && !_model.LoadFailed && !_model.IsSetup && !_model.IsCloud);
            _new.IsEnabled = !_model.IsBusy && !_model.IsPending && !_model.LoadFailed && _model.Protocols.Any(p => p.SupportsServerSetup);
            _newCloud.Visibility = Show(_model.SupportsCloud && (!_model.IsCloud || _model.Progress is not null));
            _newCloud.IsEnabled = !_model.IsBusy && !_model.IsPending && !_model.LoadFailed && _model.Protocols.Any(p => p.SupportsCloudAuthorization);
            _new.Visibility = Show(_model.Action != FileVfsAction.Create || _model.Progress is not null);
            var selected = _model.Selected;
            _browse.Visibility = Show(_model.CanBrowse); _browse.IsEnabled = _model.CanBrowse;
            _selected.Text = selected is not null ? _text.Format("VfsSelected", selected.Alias, selected.ProtocolName) : "";
            _selected.Visibility = Show(selected is not null);
            _actions.Visibility = Show(selected is not null && !_model.IsSetup && !_model.IsCloud && !_model.IsPending);
            _reauthorize.Visibility = Show(_model.SupportsCloud && _model.Protocols.Any(p => p.Id == selected?.Protocol && p.SupportsCloudAuthorization));
            _reauthorize.IsEnabled = _model.CanEdit && selected?.State != FileVfsState.Unknown;
            _edit.Visibility = Show(_model.Protocols.Any(p => p.Id == selected?.Protocol && p.SupportsServerSetup));
            _edit.IsEnabled = _model.CanEdit && selected?.State != FileVfsState.Unknown && _model.Protocols.Any(p => p.Id == selected?.Protocol && p.SupportsServerSetup);
            _connect.Visibility = Show(selected?.State == FileVfsState.Disconnected); _connect.IsEnabled = _model.CanEdit;
            _disconnect.Visibility = Show(selected?.State == FileVfsState.Connected); _disconnect.IsEnabled = _model.CanEdit;
            _remove.Visibility = Show(selected?.State == FileVfsState.Disconnected); _remove.IsEnabled = _model.CanEdit;
            _form.Visibility = Show(_model.IsCloud || _model.IsSetup && _model.Draft is not null);
            foreach (var control in new UIElement[] { _host, _port, _replace, _password, _advanced }) control.Visibility = Show(!_model.IsCloud);
            _account.IsReadOnly = _model.IsCloud;
            _authorize.Visibility = Show(_model.IsCloud && !_model.IsAuthorizing && !_model.IsPending && _model.Progress?.Outcome.Status != MutationResultStatus.ConfirmedSuccess);
            _cancelAuthorization.Visibility = Show(_model.IsAuthorizing);
            foreach (var control in _form.Children.OfType<Control>()) control.IsEnabled = _model.CanEdit;
            _cancelAuthorization.IsEnabled = _model.IsAuthorizing;
            if (_passwordProfile != selected || _passwordAction != _model.Action) { _password.Password = ""; _passwordProfile = selected; _passwordAction = _model.Action; }
            if (_model.IsCloud)
            {
                _protocol.Items.Clear();
                foreach (var p in _model.Protocols.Where(p => p.SupportsCloudAuthorization))
                { var item = new ComboBoxItem { Content = p.Name, Tag = p }; _protocol.Items.Add(item); if (p.Id == _model.CloudProtocol) _protocol.SelectedItem = item; }
                _protocol.IsEnabled = _model.CanEdit && _model.Action == FileVfsAction.CreateCloud;
                _alias.Text = _model.CloudAlias; _alias.IsReadOnly = _model.Action == FileVfsAction.Reauthorize; _account.Text = _model.CloudAccount;
            }
            else _alias.IsReadOnly = false;
            if (_model.Draft is { } draft)
            {
                _protocol.Items.Clear();
                foreach (var p in _model.Protocols.Where(p => p.SupportsServerSetup))
                { var item = new ComboBoxItem { Content = p.Name, Tag = p }; _protocol.Items.Add(item); if (p.Id == draft.Protocol) _protocol.SelectedItem = item; }
                _protocol.IsEnabled = _model.CanEdit && _model.Action == FileVfsAction.Create;
                _host.Text = draft.Hostname; _alias.Text = draft.Alias; _account.Text = draft.Account; _folder.Text = draft.Folder;
                _encoding.Text = draft.Codepage; _port.Value = draft.Port; _single.IsChecked = draft.UsesOneConnection;
                _replace.Visibility = Show(_model.Action == FileVfsAction.Update); _replace.IsChecked = _model.ReplacePassword;
                _password.Visibility = Show(_model.ReplacePassword);
            }
            _warning.Text = _text.Get(_model.Action == FileVfsAction.RemoveSavedProfile ? "VfsRemoveRisk" : "VfsDisconnectRisk");
            _warning.Visibility = Show(_model.Action is FileVfsAction.Disconnect or FileVfsAction.RemoveSavedProfile && _model.Progress?.Outcome.Status != MutationResultStatus.ConfirmedSuccess);
            _cleartext.Visibility = Show(_model.NeedsCleartext); _cleartext.IsEnabled = _model.CanEdit; _cleartext.IsChecked = _model.ConfirmedCleartext;
        }
        finally { _rendering = false; }
    }
    private Button Button(string key, Action action)
    {
        var button = new Button { Content = _text.Get(key), MinHeight = 40 };
        AutomationProperties.SetAutomationId(button, key); button.Click += (_, _) => action(); return button;
    }
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.WrapWholeWords };
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { if (_disposed) return; _disposed = true; _password.Password = ""; _model.PropertyChanged -= Changed; _model.Dispose(); }
}
