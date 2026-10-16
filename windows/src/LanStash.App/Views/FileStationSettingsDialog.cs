using System.Globalization;
using LanStash.App.Features.Files.Settings;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal sealed partial class FileStationSettingsDialog : ContentDialog, IDisposable
{
    private readonly FileStationSettingsViewModel _model;
    private readonly LocalizationService _text = LocalizationService.Current;
    private readonly StackPanel _editor = new() { Spacing = 12 };
    private readonly ContentControl _editorHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, IsTabStop = false };
    private readonly StackPanel _selectors = new() { Spacing = 10 };
    private readonly ListView _list = new() { MaxHeight = 160, MinHeight = 120, SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBox _filter = new();
    private readonly ComboBox _section = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock _empty = new() { TextWrapping = TextWrapping.WrapWholeWords, TextAlignment = TextAlignment.Center, Margin = new(0, 24, 0, 24) };
    private readonly InfoBar _message = new() { IsClosable = false };
    private readonly CheckBox _expansion = new();
    private readonly ProgressRing _busy = new() { Width = 28, Height = 28 };
    private readonly Button _refresh;
    private bool _rendering, _disposed;
    public FileStationSettingsDialog(FileStationSettingsViewModel model, XamlRoot root, Func<Task<string?>>? pickThemeImage = null)
    {
        _pickThemeImage = pickThemeImage;
        _model = model; XamlRoot = root; RequestedTheme = root.Content is FrameworkElement e ? e.ActualTheme : ElementTheme.Default;
        Title = T("FsSettingsTitle"); CloseButtonText = T("FsSettingsClose"); PrimaryButtonText = T("FsSettingsSave"); DefaultButton = ContentDialogButton.None;
        Resources["ContentDialogMaxWidth"] = 760d;
        AutomationProperties.SetAutomationId(this, "FileStationSettingsDialog");
        foreach (var section in Enum.GetValues<FileStationSettingsSection>()) _section.Items.Add(new ComboBoxItem { Tag = section, Content = T("FsSettingsSection" + section) });
        AutomationProperties.SetName(_section, T("FsSettingsSection"));
        _section.SelectionChanged += async (_, _) => { if (!_rendering && _section.SelectedItem is ComboBoxItem { Tag: FileStationSettingsSection section }) await model.SelectSectionAsync(section); };
        _filter.Header = T("FsSettingsFilter"); AutomationProperties.SetAutomationId(_filter, "FsSettingsFilter");
        _filter.TextChanged += (_, _) => { if (!_rendering) model.SetFilter(_filter.Text); };
        _list.SelectionChanged += (_, _) => { if (!_rendering && _list.SelectedItem is ListViewItem { Tag: FileStationSetting item }) model.Select(item); };
        AutomationProperties.SetName(_list, T("FsSettingsAccounts"));
        _refresh = Button("FsSettingsRefresh", async () => await model.LoadAsync());
        _expansion.Checked += (_, _) => { if (!_rendering) { model.ConfirmedExpansion = true; RenderFooter(); } };
        _expansion.Unchecked += (_, _) => { if (!_rendering) { model.ConfirmedExpansion = false; RenderFooter(); } };
        var header = new Grid { ColumnSpacing = 12 }; header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        header.Children.Add(_section); Grid.SetColumn(_refresh, 1); header.Children.Add(_refresh);
        var body = new StackPanel { Spacing = 12, MinWidth = 460, MaxWidth = 680, MinHeight = 320 };
        _editorHost.Content = _editor;
        foreach (var child in new UIElement[] { header, _message, _busy, _selectors, _filter, _list, _empty, _editorHost, _themePicker, _expansion }) body.Children.Add(child);
        Content = new ScrollViewer { Content = body, MaxHeight = 510, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Opened += async (_, _) => await model.LoadAsync(); PrimaryButtonClick += async (_, args) =>
        { args.Cancel = true; if (model.ThemePickerOpen) model.UseThemeImage(); else await model.SaveAsync(); };
        model.PropertyChanged += Changed; Render();
    }
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (_disposed || _rendering) return;
        if (e.PropertyName == nameof(_model.Draft)) RenderFooter(); else if (e.PropertyName == nameof(_model.Filter)) RenderList();
        else if (e.PropertyName == nameof(_model.ThemeFilter)) RenderThemeList(); else Render();
    }
    private void Render()
    {
        if (_disposed || _rendering) return; _rendering = true;
        try
        {
            _section.SelectedIndex = (int)_model.Section; _section.IsEnabled = !_model.IsBusy && !_pickingThemeImage;
            _refresh.IsEnabled = !_model.IsBusy && !_model.ThemePickerOpen && !_pickingThemeImage;
            _busy.IsActive = _model.IsBusy; _busy.Visibility = Show(_model.IsBusy);
            _filter.Visibility = _list.Visibility = Show(_model.Section is FileStationSettingsSection.MountAccounts or FileStationSettingsSection.Bandwidth);
            _filter.Text = _model.Filter; _filter.IsEnabled = !_model.IsBusy && !_model.LoadFailed;
            _selectors.Children.Clear();
            if (_model.Section == FileStationSettingsSection.MountAccounts)
            {
                var source = new ComboBox { Header = T("FsSettingsDirectory"), HorizontalAlignment = HorizontalAlignment.Stretch };
                foreach (var directory in _model.Directories) source.Items.Add(new ComboBoxItem { Tag = directory, Content = directory.Kind == FileStationDirectoryKind.Domain ? directory.Name : T("FsSettingsDirectory" + directory.Kind) });
                source.SelectedItem = source.Items.Cast<ComboBoxItem>().FirstOrDefault(v => Equals(v.Tag, _model.Source)); source.IsEnabled = !_model.IsBusy;
                source.SelectionChanged += async (_, _) => { if (!_rendering && source.SelectedItem is ComboBoxItem { Tag: FileStationDirectory selected }) await _model.SetDirectoryAsync(selected, _model.AccountKind); };
                _selectors.Children.Add(source);
                _selectors.Children.Add(Choice("FsSettingsAccountKind", _model.AccountKind, Enum.GetValues<FileSharePrincipalKind>(), async value => await _model.SetDirectoryAsync(_model.Source, value), false));
                if (_model.SourcesUnavailable) _selectors.Children.Add(Label(T("FsSettingsSourcesUnavailable")));
            }
            if (_model.Section == FileStationSettingsSection.Bandwidth)
                _selectors.Children.Add(Choice("FsSettingsOwner", _model.Owner, Enum.GetValues<FileStationBandwidthOwner>(), async value => await _model.SetOwnerAsync(value), false));
            RenderList(); RenderEditor(); RenderThemePicker(); RenderFooter();
        }
        finally { _rendering = false; }
    }
    private void RenderList()
    {
        var wasRendering = _rendering; _rendering = true;
        try
        {
            _list.Items.Clear(); foreach (var setting in _model.VisibleItems)
            {
                var body = new StackPanel { Spacing = 3 }; body.Children.Add(Label(FileStationSettingsViewModel.ItemName(setting)));
                body.Children.Add(Label(setting switch { FileStationMountAccount a => T(a.CanModify ? a.Enabled ? "FsSettingsAccountAllowed" : "FsSettingsAccountDenied" : "FsSettingsAccountLocked"),
                    FileStationBandwidth b => PolicyLabel(b), _ => "" }));
                var item = new ListViewItem { Content = body, Tag = setting }; _list.Items.Add(item);
                if (setting.Target == _model.Baseline?.Target) _list.SelectedItem = item;
            }
            _list.IsEnabled = !_model.IsBusy;
            var listing = _model.Section is FileStationSettingsSection.MountAccounts or FileStationSettingsSection.Bandwidth;
            _empty.Visibility = Show(listing && !_model.IsBusy && !_model.LoadFailed && _list.Items.Count == 0);
            _empty.Text = T(_model.Items.Count == 0 ? "FsSettingsEmpty" : "FsSettingsFilteredEmpty");
        }
        finally { _rendering = wasRendering; }
    }
    private void RenderEditor()
    {
        _editor.Children.Clear(); _editorHost.IsEnabled = _model.CanEdit; _editorHost.Visibility = Show(!_model.ThemePickerOpen);
        switch (_model.Draft)
        {
            case FileStationTheme theme: RenderThemeEditor(theme); break;
            case FileStationGeneralSettings general:
                Check("FsSettingsRecordTransfers", general.RecordsTransfers, v => UpdateGeneral(g => g with { RecordsTransfers = v }));
                Check("FsSettingsDefaultPermissions", general.UsesDefaultPermissions, v => UpdateGeneral(g => g with { UsesDefaultPermissions = v }));
                Check("FsSettingsShowAccounts", general.ShowsAccounts, v => UpdateGeneral(g => g with { ShowsAccounts = v }));
                if (general.UsesCustomSharingPage is { } custom) Check("FsSettingsCustomPage", custom, v => UpdateGeneral(g => g with { UsesCustomSharingPage = v }));
                Access("FsSettingsSharing", general.Sharing, true, v => UpdateGeneral(g => g with { Sharing = v }), true);
                if (general.Sharing == FileStationAccess.Selected) PolicyAccounts(true, general);
                Access("FsSettingsRequests", general.FileRequests, true, v => UpdateGeneral(g => g with { FileRequests = v }), true);
                if (general.FileRequests == FileStationAccess.Selected) PolicyAccounts(false, general);
                Number("FsSettingsLinkLimit", general.DefaultLinkLimit, v => UpdateGeneral(g => g with { DefaultLinkLimit = v }));
                Access("FsSettingsRemoteMounts", general.RemoteMounts, false, v => UpdateGeneral(g => g with { RemoteMounts = v }));
                Access("FsSettingsIsoMounts", general.IsoMounts, false, v => UpdateGeneral(g => g with { IsoMounts = v }));
                _editor.Children.Add(Choice("FsSettingsServiceBandwidth", general.Bandwidth,
                    new[] { FileStationBandwidthPolicy.Disabled, FileStationBandwidthPolicy.Enabled, FileStationBandwidthPolicy.Scheduled }, v =>
                    { UpdateGeneral(g => g with { Bandwidth = v, Schedule = v == FileStationBandwidthPolicy.Scheduled && g.Schedule.Length == 0 ? new('1', 168) : g.Schedule }); RebuildEditor(); }));
                if (general.Bandwidth == FileStationBandwidthPolicy.Scheduled) Schedule(general.Schedule, false, v => UpdateGeneral(g => g with { Schedule = v }));
                break;
            case FileStationMountAccess mount:
                Access("FsSettingsMountAccess", mount.Access, true, v => _model.UpdateDraft(mount with { Access = v })); break;
            case FileStationMountAccount account:
                _editor.Children.Add(Label(account.Name));
                if (!account.CanModify) _editor.Children.Add(Label(T("FsSettingsAccountLocked")));
                else Check("FsSettingsAllowMount", account.Enabled, v => _model.UpdateDraft(account with { Enabled = v }));
                break;
            case FileStationBandwidth bandwidth:
                _editor.Children.Add(Label(bandwidth.Name));
                var policies = bandwidth.Policy == FileStationBandwidthPolicy.NotConfigured ? Enum.GetValues<FileStationBandwidthPolicy>() : new[] { FileStationBandwidthPolicy.Disabled, FileStationBandwidthPolicy.Enabled, FileStationBandwidthPolicy.Scheduled };
                _editor.Children.Add(Choice("FsSettingsAccountPolicy", bandwidth.Policy, policies, v =>
                { UpdateBandwidth(b => b with { Policy = v, Schedule = v == FileStationBandwidthPolicy.Scheduled && b.Schedule.Length == 0 ? new('1', 168) : b.Schedule }); RebuildEditor(); }));
                if (bandwidth.Policy == FileStationBandwidthPolicy.NotConfigured) _editor.Children.Add(Label(PolicyLabel(bandwidth)));
                if (bandwidth.Policy is FileStationBandwidthPolicy.Enabled or FileStationBandwidthPolicy.Scheduled)
                {
                    Number("FsSettingsUploadLimit", bandwidth.UploadLimit, v => UpdateBandwidth(b => b with { UploadLimit = v }));
                    Number("FsSettingsDownloadLimit", bandwidth.DownloadLimit, v => UpdateBandwidth(b => b with { DownloadLimit = v }));
                    _editor.Children.Add(Label(T("FsSettingsRatesHelp")));
                }
                if (bandwidth.Policy == FileStationBandwidthPolicy.Scheduled)
                {
                    Number("FsSettingsAlternateUpload", bandwidth.AlternateUploadLimit, v => UpdateBandwidth(b => b with { AlternateUploadLimit = v }));
                    Number("FsSettingsAlternateDownload", bandwidth.AlternateDownloadLimit, v => UpdateBandwidth(b => b with { AlternateDownloadLimit = v }));
                    Schedule(bandwidth.Schedule, true, v => UpdateBandwidth(b => b with { Schedule = v }));
                }
                break;
        }
    }
    private void RenderFooter()
    {
        var previous = _rendering; _rendering = true;
        try
        {
            PrimaryButtonText = T(_model.ThemePickerOpen ? "FsThemeUseImage" : "FsSettingsSave");
            IsPrimaryButtonEnabled = _model.ThemePickerOpen ? _model.CanUseThemeImage : _model.CanSave; _editorHost.IsEnabled = _model.CanEdit;
            _expansion.Visibility = Show(_model.NeedsExpansionConfirmation); _expansion.IsEnabled = _model.CanEdit; _expansion.IsChecked = _model.ConfirmedExpansion;
            var risks = new StackPanel { Spacing = 4 }; foreach (var riskKey in _model.ExpansionMessageKeys) risks.Children.Add(Label(T(riskKey))); _expansion.Content = risks;
            var key = _model.MessageKey; _message.IsOpen = key is not null; _message.Message = key is null ? "" : T(key);
            _message.Severity = _model.Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        }
        finally { _rendering = previous; }
    }
    private void PolicyAccounts(bool sharing, FileStationGeneralSettings settings)
    {
        var filter = new TextBox { Header = T("FsSettingsFilter"), Margin = new(0, 4, 0, 0) };
        var accounts = new StackPanel { Spacing = 4 };
        void Rebuild()
        {
            accounts.Children.Clear(); var selection = sharing ? (_model.Draft as FileStationGeneralSettings)?.SharingAccounts ?? settings.SharingAccounts : (_model.Draft as FileStationGeneralSettings)?.RequestAccounts ?? settings.RequestAccounts;
            foreach (var account in _model.PolicyAccounts.Where(a => a.Name.Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase)))
            {
                var check = new CheckBox { Content = account.Name, IsChecked = selection.Contains(account.Id), IsEnabled = !account.IsAdministrator, Tag = account.Id };
                AutomationProperties.SetName(check, _text.Format("FsSettingsNamedAccount", account.Name, T("FsSettingsEnum" + account.Id.Kind)));
                check.Checked += (_, _) => { if (!_rendering) _model.TogglePolicyAccount(account.Id, sharing, true); };
                check.Unchecked += (_, _) => { if (!_rendering) _model.TogglePolicyAccount(account.Id, sharing, false); }; accounts.Children.Add(check);
            }
            if (accounts.Children.Count == 0) accounts.Children.Add(Label(T(_model.PolicyAccounts.Count == 0 ? "FsSettingsAccountsUnavailable" : "FsSettingsFilteredEmpty")));
        }
        Rebuild(); filter.TextChanged += (_, _) => Rebuild(); _editor.Children.Add(filter); _editor.Children.Add(new ScrollViewer { Content = accounts, MaxHeight = 160 });
    }
    private void Schedule(string initial, bool perAccount, Action<string> changed)
    {
        var value = initial; var days = CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedDayNames; var painting = 1;
        var day = new ComboBox { Header = T("FsSettingsScheduleDay"), ItemsSource = days, SelectedIndex = 0 };
        var modeChoice = new ComboBox { Header = T("FsSettingsScheduleFillMode") };
        AutomationProperties.SetAutomationId(modeChoice, "FsSettingsScheduleFillMode");
        for (var mode = 0; mode <= (perAccount ? 2 : 1); mode++) modeChoice.Items.Add(new ComboBoxItem { Tag = mode, Content = T("FsSettingsScheduleMode" + mode) });
        modeChoice.SelectedIndex = 1; modeChoice.SelectionChanged += (_, _) => painting = modeChoice.SelectedIndex;
        var grid = new Grid { ColumnSpacing = 6, RowSpacing = 6 };
        for (var column = 0; column < 6; column++) grid.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
        for (var row = 0; row < 4; row++) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        void Rebuild()
        {
            grid.Children.Clear(); if (!FileStationSchedule.IsValid(value, perAccount)) return;
            for (var h = 0; h < 24; h++)
            {
                var hour = h; var mode = value[day.SelectedIndex * 24 + hour] - '0';
                var button = new Button { MinHeight = 52, HorizontalAlignment = HorizontalAlignment.Stretch,
                    Content = new TextBlock { Text = _text.Format("FsSettingsScheduleHour", hour, T("FsSettingsScheduleMode" + mode)), TextWrapping = TextWrapping.WrapWholeWords, TextAlignment = TextAlignment.Center } };
                AutomationProperties.SetName(button, _text.Format("FsSettingsScheduleCell", days[day.SelectedIndex], hour, T("FsSettingsScheduleMode" + mode)));
                button.Click += (_, _) => { value = FileStationSchedule.Set(value, day.SelectedIndex, hour, (mode + 1) % (perAccount ? 3 : 2), perAccount); changed(value); Rebuild(); };
                Grid.SetRow(button, hour / 6); Grid.SetColumn(button, hour % 6); grid.Children.Add(button);
            }
        }
        var fills = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        fills.Children.Add(Button("FsSettingsScheduleFillDay", () => { for (var hour = 0; hour < 24; hour++) value = FileStationSchedule.Set(value, day.SelectedIndex, hour, painting, perAccount); changed(value); Rebuild(); }));
        fills.Children.Add(Button("FsSettingsScheduleFillWeek", () => { value = new((char)('0' + painting), 168); changed(value); Rebuild(); }));
        day.SelectionChanged += (_, _) => Rebuild(); _editor.Children.Add(Label(T("FsSettingsScheduleHelp"))); _editor.Children.Add(day); _editor.Children.Add(grid);
        _editor.Children.Add(modeChoice); _editor.Children.Add(fills); Rebuild();
    }
    private ComboBox Choice<TValue>(string key, TValue selected, IEnumerable<TValue> values, Action<TValue> change, bool editor = true) where TValue : struct, Enum
    {
        var choice = new ComboBox { Header = T(key), HorizontalAlignment = HorizontalAlignment.Stretch, IsEnabled = editor ? _model.CanEdit : !_model.IsBusy };
        AutomationProperties.SetAutomationId(choice, key);
        foreach (var value in values) choice.Items.Add(new ComboBoxItem { Tag = value, Content = T("FsSettingsEnum" + value) });
        choice.SelectedItem = choice.Items.Cast<ComboBoxItem>().FirstOrDefault(v => Equals(v.Tag, selected));
        choice.SelectionChanged += (_, _) => { if (!_rendering && choice.SelectedItem is ComboBoxItem { Tag: TValue value }) change(value); }; return choice;
    }
    private void Access(string key, FileStationAccess value, bool selected, Action<FileStationAccess> update, bool rebuild = false) =>
        _editor.Children.Add(Choice(key, value, selected ? Enum.GetValues<FileStationAccess>() : new[] { FileStationAccess.Administrators, FileStationAccess.Everyone }, v => { update(v); if (rebuild) RebuildEditor(); }));
    private void Check(string key, bool value, Action<bool> change)
    {
        var check = new CheckBox { Content = T(key), IsChecked = value }; AutomationProperties.SetAutomationId(check, key);
        check.Checked += (_, _) => { if (!_rendering) change(true); }; check.Unchecked += (_, _) => { if (!_rendering) change(false); }; _editor.Children.Add(check);
    }
    private void Number(string key, int value, Action<int> change)
    {
        var number = new NumberBox { Header = T(key), Minimum = 0, Maximum = 999999999, Value = value, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        AutomationProperties.SetAutomationId(number, key);
        number.ValueChanged += (_, _) => { if (!_rendering) change(double.IsFinite(number.Value) && number.Value == Math.Truncate(number.Value) ? (int)number.Value : -1); }; _editor.Children.Add(number);
    }
    private void UpdateGeneral(Func<FileStationGeneralSettings, FileStationGeneralSettings> change) { if (_model.Draft is FileStationGeneralSettings value) _model.UpdateDraft(change(value)); }
    private void UpdateBandwidth(Func<FileStationBandwidth, FileStationBandwidth> change) { if (_model.Draft is FileStationBandwidth value) _model.UpdateDraft(change(value)); }
    private void RebuildEditor() { var previous = _rendering; _rendering = true; try { RenderEditor(); RenderFooter(); } finally { _rendering = previous; } }
    private string PolicyLabel(FileStationBandwidth b) => T(b.Policy == FileStationBandwidthPolicy.NotConfigured ? b.Owner is FileStationBandwidthOwner.LocalUser or FileStationBandwidthOwner.LdapUser or FileStationBandwidthOwner.DomainUser ? "FsSettingsInherited" : "FsSettingsUnconfigured" : "FsSettingsEnum" + b.Policy);
    private Button Button(string key, Action action) { var button = new Button { Content = T(key), MinHeight = 40 }; AutomationProperties.SetAutomationId(button, key); button.Click += (_, _) => action(); return button; }
    private string T(string key) => _text.Get(key);
    private static TextBlock Label(string text) => new() { Text = text, TextWrapping = TextWrapping.WrapWholeWords };
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { if (_disposed) return; _disposed = true; _themePreviewGeneration++; _model.PropertyChanged -= Changed; _model.Dispose(); }
}
