using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private enum PhotoPreferenceKind { Display, Duplicates, Recognition, Shared, SharedEnabled }
    private async void PhotoDisplaySettings_Click(object sender, RoutedEventArgs args) => await ShowPhotoPreferencesAsync(PhotoPreferenceKind.Display);
    private async void PhotoDuplicateSettings_Click(object sender, RoutedEventArgs args) => await ShowPhotoPreferencesAsync(PhotoPreferenceKind.Duplicates);
    private async void PhotoRecognitionSettings_Click(object sender, RoutedEventArgs args) => await ShowPhotoPreferencesAsync(PhotoPreferenceKind.Recognition);
    private async void PhotoSharedSettings_Click(object sender, RoutedEventArgs args) => await ShowPhotoPreferencesAsync(PhotoPreferenceKind.Shared);
    private void RenderPhotoPreferenceControls()
    {
        foreach (var (menu, key) in new[] { (PhotoDisplaySettingsMenu, "PhotosDisplaySettings"), (PhotoDuplicateSettingsMenu, "PhotosDuplicateSettings"), (PhotoRecognitionSettingsMenu, "PhotosRecognitionSettings") })
        { menu.Text = _l.Get(key); menu.Visibility = Visible(_model.Repository.SupportsManagement); menu.IsEnabled = !_model.IsLoading && !_managementPreparing; }
        PhotoSharedSettingsMenu.Text = _l.Get("PhotosSharedSettings");
        PhotoSharedSettingsMenu.Visibility = Visible(_model.Repository.SupportsManagement && _model.IsAdministrator);
        PhotoSharedSettingsMenu.IsEnabled = !_model.IsLoading && !_managementPreparing;
        PhotoGlobalSettingsMenu.Text = _l.Get("PhotosGlobalSettings");
        PhotoGlobalSettingsMenu.Visibility = PhotoSharedSettingsMenu.Visibility;
        PhotoGlobalSettingsMenu.IsEnabled = PhotoSharedSettingsMenu.IsEnabled;
        PhotoSharedMembersMenu.Text = _l.Get("PhotosSharedMembers");
        PhotoSharedMembersMenu.Visibility = PhotoSharedSettingsMenu.Visibility;
        PhotoSharedMembersMenu.IsEnabled = PhotoSharedSettingsMenu.IsEnabled;
        PhotoMaintenanceMenu.Text = _l.Get("PhotosLibraryMaintenance");
        PhotoMaintenanceMenu.Visibility = Visible(_model.Repository.SupportsManagement && _model.HasOriginalSource && (_model.SelectedSpace == SynologyPhotoSpace.Personal || _model.IsAdministrator));
        PhotoMaintenanceMenu.IsEnabled = !_model.IsLoading && !_managementPreparing;
        PhotoCodecPromptMenu.Text = _l.Get("PhotosCodecPrompt");
        PhotoCodecPromptMenu.Visibility = Visible(_model.Repository.SupportsManagement);
        PhotoCodecPromptMenu.IsEnabled = PhotoMaintenanceMenu.IsEnabled;
        PhotoBackgroundTasksMenu.Text = _l.Get("PhotosBackgroundTasks");
        PhotoBackgroundTasksMenu.Visibility = Visible(_model.Repository.SupportsManagement);
        PhotoBackgroundTasksMenu.IsEnabled = !_model.IsLoading && !_managementPreparing;
    }
    private async Task ShowPhotoPreferencesAsync(PhotoPreferenceKind kind)
    {
        if (_disposed || _dialog is not null) return;
        var generation = _viewGeneration; var closed = false; var busy = false; var pending = false; var id = Guid.NewGuid();
        Func<bool>? changed = null; Func<Task<SynologyPhotoSettingsChange>>? save = null;
        Func<string?>? confirmation = null; var confirming = false; var showEnabled = false;
        var fields = new StackPanel { Spacing = 12, MinWidth = 280, MaxWidth = 560 };
        var form = new ContentControl { Content = fields, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var retry = new Button { Content = _l.Get("PhotosRetry") };
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(form); panel.Children.Add(message); panel.Children.Add(retry);
        var title = kind switch { PhotoPreferenceKind.Display => "PhotosDisplaySettings", PhotoPreferenceKind.Duplicates => "PhotosDuplicateSettings", PhotoPreferenceKind.Recognition => "PhotosRecognitionSettings", _ => "PhotosSharedSettings" };
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get(title),
            PrimaryButtonText = _l.Get("PhotosSaveChanges"), CloseButtonText = _l.Get("PhotosClose"), IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 550, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void RenderForm()
        {
            if (!Current()) return;
            form.IsEnabled = !busy && !pending; form.Visibility = Visible(!confirming); retry.IsEnabled = !busy;
            dialog.PrimaryButtonText = _l.Get(confirming ? "PhotosSharedConfirm" : "PhotosSaveChanges");
            dialog.IsPrimaryButtonEnabled = !busy && !pending && changed?.Invoke() == true;
            retry.Visibility = Visible(!busy && !confirming && (pending || save is null));
            message.Visibility = Visible(message.Text.Length > 0);
        }
        ComboBox Choice(string key, string[] choices, int selected)
        {
            var value = new ComboBox { Header = _l.Get(key), ItemsSource = choices, SelectedIndex = selected, HorizontalAlignment = HorizontalAlignment.Stretch };
            AutomationProperties.SetAutomationId(value, key); AutomationProperties.SetName(value, _l.Get(key));
            value.SelectionChanged += (_, _) => RenderForm(); fields.Children.Add(value); return value;
        }
        ToggleSwitch Toggle(string key, bool value, bool enabled = true)
        {
            var toggle = new ToggleSwitch { Header = _l.Get(key), IsOn = value, IsEnabled = enabled,
                OnContent = _l.Get("PhotosAutomaticOn"), OffContent = _l.Get("PhotosAutomaticOff") };
            AutomationProperties.SetAutomationId(toggle, key); AutomationProperties.SetName(toggle, _l.Get(key));
            toggle.Toggled += (_, _) => RenderForm(); fields.Children.Add(toggle); return toggle;
        }
        async Task Load()
        {
            if (!Current() || busy) return;
            busy = true; save = null; changed = null; confirmation = null; confirming = false; message.Text = _l.Get("PhotosLoadingDescription"); RenderForm();
            try
            {
                var unfinished = (await _model.Repository.SettingsChangesAsync(_viewCancellation.Token)).SingleOrDefault(value => value.Pending);
                if (unfinished is not null)
                {
                    var result = await _model.Repository.ReviewSettingsChangeAsync(unfinished.Id, _viewCancellation.Token);
                    if (!Current()) return;
                    pending = result.Pending;
                    if (pending) { fields.Children.Clear(); message.Text = _l.Get("PhotosPreferenceSaving"); return; }
                    await _model.ApplySettingsChangeAsync(result);
                    if (!Current()) { if (!_disposed && ReferenceEquals(_dialog, dialog)) dialog.Hide(); return; }
                }
                pending = false; fields.Children.Clear(); id = Guid.NewGuid();
                if (kind == PhotoPreferenceKind.Display)
                {
                    var original = await _model.Repository.DisplaySettingsAsync(_viewCancellation.Token); if (!Current()) return;
                    var grouping = Choice("PhotosDisplayGrouping", [_l.Get("PhotosDisplayDay"), _l.Get("PhotosDisplayMonth")], (int)original.Grouping);
                    var examples = Enum.GetValues<SynologyPhotoDateFormat>().Select(format => Features.Photos.Synology.SynologyPhotosWorkspace.FormatDisplayDate(
                        new(2026, 10, 25), original with { DateFormat = format }, false, false, System.Globalization.CultureInfo.CurrentCulture)).ToArray();
                    var date = Choice("PhotosDisplayDate", examples, (int)original.DateFormat);
                    var clock = Choice("PhotosDisplayClock", [_l.Get("PhotosDisplay24Hour"), _l.Get("PhotosDisplay12Hour")], original.TwelveHourClock ? 1 : 0);
                    var sort = Choice("PhotosSortBy", Enum.GetValues<SynologyPhotoSortField>().Select(PhotoSortTitle).ToArray(), (int)original.DefaultSort.Field);
                    var direction = Choice("PhotosSortDirection", [_l.Get("PhotosSortAscending"), _l.Get("PhotosSortDescending")], original.DefaultSort.Descending ? 1 : 0);
                    var info = Toggle("PhotosDisplayPreviewInfo", original.ShowsPreviewInfo);
                    SynologyPhotoDisplaySettings Target() => new((SynologyPhotoGrouping)grouping.SelectedIndex, (SynologyPhotoDateFormat)date.SelectedIndex,
                        clock.SelectedIndex == 1, new((SynologyPhotoSortField)sort.SelectedIndex, direction.SelectedIndex == 1), info.IsOn);
                    changed = () => Target() != original; save = () => _model.Repository.SetDisplaySettingsAsync(id, original, Target());
                }
                else if (kind == PhotoPreferenceKind.Duplicates)
                {
                    var original = await _model.Repository.DuplicateSettingsAsync(_viewCancellation.Token); if (!Current()) return;
                    var upload = Choice("PhotosUploadDuplicate", [_l.Get("PhotosUploadSkip"), _l.Get("PhotosUploadKeepBoth")], (int)original.Upload);
                    var transfer = Choice("PhotosFileDuplicate", [_l.Get("PhotosFileSkip"), _l.Get("PhotosFileOverwrite")], (int)original.Transfer);
                    SynologyPhotoDuplicateSettings Target() => new((SynologyPhotoDuplicatePolicy)upload.SelectedIndex, (SynologyPhotoFileDuplicate)transfer.SelectedIndex);
                    changed = () => Target() != original; save = () => _model.Repository.SetDuplicateSettingsAsync(id, original, Target());
                }
                else if (kind == PhotoPreferenceKind.Recognition)
                {
                    var original = await _model.Repository.RecognitionSettingsAsync(_viewCancellation.Token); if (!Current()) return;
                    var toggles = new Dictionary<SynologyPhotoCategory, ToggleSwitch>();
                    foreach (var category in new[] { SynologyPhotoCategory.People, SynologyPhotoCategory.Subjects, SynologyPhotoCategory.Similar })
                        if (original.Value(category) is { } enabled) toggles[category] = Toggle(category switch
                        { SynologyPhotoCategory.People => "PhotosCategoryPeople", SynologyPhotoCategory.Subjects => "PhotosCategorySubjects", _ => "PhotosCategorySimilar" }, enabled, original.Editable(category));
                    bool? Value(SynologyPhotoCategory category) => toggles.TryGetValue(category, out var toggle) ? toggle.IsOn : original.Value(category);
                    SynologyPhotoRecognitionSettings Target() => original with { People = Value(SynologyPhotoCategory.People), Subjects = Value(SynologyPhotoCategory.Subjects), Similar = Value(SynologyPhotoCategory.Similar) };
                    changed = () => Target() != original; save = () => _model.Repository.SetRecognitionSettingsAsync(id, original, Target());
                    if (!toggles.Keys.Any(original.Editable)) { message.Text = _l.Get("PhotosRecognitionUnavailable"); return; }
                }
                else
                {
                    var original = await _model.Repository.SharedSettingsAsync(_viewCancellation.Token); if (!Current()) return;
                    var safety = _model.Repository.SettingsSafety;
                    if (kind == PhotoPreferenceKind.SharedEnabled)
                    {
                        var enabled = Toggle("PhotosSharedEnabled", original.Enabled, safety.SharedLibraryChanges && (original.PersonalEnabled || !original.Enabled));
                        changed = () => enabled.IsOn != original.Enabled;
                        save = () => _model.Repository.SetSharedEnabledAsync(id, original, enabled.IsOn, confirmed: true);
                        confirmation = () => enabled.IsOn ? "PhotosSharedEnableWarning" : "PhotosSharedDisableWarning";
                    }
                    else
                    {
                        var toggles = new Dictionary<SynologyPhotoCategory, ToggleSwitch>();
                        foreach (var category in new[] { SynologyPhotoCategory.People, SynologyPhotoCategory.Subjects, SynologyPhotoCategory.Similar })
                            if (original.Value(category) is { } value) toggles[category] = Toggle(category switch
                            { SynologyPhotoCategory.People => "PhotosCategoryPeople", SynologyPhotoCategory.Subjects => "PhotosCategorySubjects", _ => "PhotosCategorySimilar" }, value, original.Editable(category));
                        var publicRoot = original.PublicRoot is { } publicValue ? Toggle("PhotosSharedPublicRoot", publicValue, original.Enabled && safety.PublicDirectorySharing) : null;
                        bool? Value(SynologyPhotoCategory category) => toggles.TryGetValue(category, out var toggle) ? toggle.IsOn : original.Value(category);
                        SynologyPhotoSharedSettings Target() => original with { People = Value(SynologyPhotoCategory.People), Subjects = Value(SynologyPhotoCategory.Subjects), Similar = Value(SynologyPhotoCategory.Similar), PublicRoot = publicRoot?.IsOn };
                        changed = () => Target() != original; save = () => _model.Repository.SetSharedSettingsAsync(id, original, Target(), confirmed: true);
                        confirmation = () => Target().PublicRoot != original.PublicRoot ? Target().PublicRoot == true ? "PhotosSharedPublicEnableWarning" : "PhotosSharedPublicDisableWarning" : null;
                        var switchLibrary = new Button { Content = _l.Get(original.Enabled ? "PhotosSharedDisable" : "PhotosSharedEnable"),
                            IsEnabled = safety.SharedLibraryChanges && original.CanSetEnabled(!original.Enabled) };
                        AutomationProperties.SetAutomationId(switchLibrary, "PhotoSharedSwitch");
                        switchLibrary.Click += (_, _) => { if (!busy && !pending) { showEnabled = true; dialog.Hide(); } }; fields.Children.Add(switchLibrary);
                    }
                    if (!original.PersonalEnabled && original.Enabled) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosSharedLastLibrary"), TextWrapping = TextWrapping.Wrap });
                    if (original.DisabledBySharedFolder == true) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosSharedFolderDisabled"), TextWrapping = TextWrapping.Wrap });
                    if (!safety.SharedLibraryChanges || !safety.PublicDirectorySharing) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosSharedUseWeb"), TextWrapping = TextWrapping.Wrap });
                    else if (!original.Enabled) fields.Children.Add(new TextBlock { Text = _l.Get("PhotosSharedIsDisabled"), TextWrapping = TextWrapping.Wrap });
                }
                message.Text = "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(PreferenceErrorKey(error)); }
            finally { busy = false; RenderForm(); RenderPreviewControls(); }
        }
        retry.Click += async (_, _) => await Load();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(3) };
        timer.Tick += async (_, _) => { if (pending && !busy) await Load(); };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (!Current() || busy || pending || save is null || changed?.Invoke() != true) return;
            if (!confirming && confirmation?.Invoke() is { } warning) { confirming = true; message.Text = _l.Get(warning); RenderForm(); return; }
            var deferral = args.GetDeferral(); busy = true; message.Text = _l.Get("PhotosPreferenceSaving"); RenderForm();
            try
            {
                var result = await save(); if (!Current()) return;
                pending = result.Pending;
                if (result.State == SynologyPhotoChangeState.Completed)
                {
                    await _model.ApplySettingsChangeAsync(result);
                    // 当前来源或分类退出会合法更新页面代次，仍须关闭本次已完成的窗口。
                    if (!_disposed && ReferenceEquals(_dialog, dialog)) dialog.Hide();
                }
                else { save = null; changed = null; message.Text = _l.Get(pending ? "PhotosPreferenceSaving" : "PhotosPreferenceSaveFailed"); }
            }
            catch (Exception error) { if (Current()) { save = null; changed = null; message.Text = _l.Get(PreferenceErrorKey(error)); } }
            finally { busy = false; confirming = false; RenderForm(); deferral.Complete(); }
        };
        dialog.Closed += (_, _) => closed = true;
        try
        {
            if (MoreButton.Flyout.IsOpen) MoreButton.Flyout.Hide(); SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var showing = ShowPhotoDialogAsync(dialog); timer.Start(); await Load(); await showing;
        }
        finally { closed = true; timer.Stop(); if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderPreviewControls(); }
        if (showEnabled && !_disposed && generation == _viewGeneration) await ShowPhotoPreferencesAsync(PhotoPreferenceKind.SharedEnabled);
    }
    private static string PreferenceErrorKey(Exception error) => ManagementErrorKey(error) switch
    {
        "PhotosEditPermission" => "PhotosPreferencePermission", "PhotosEditTargetChanged" => "PhotosPreferenceChanged",
        "PhotosEditBusy" => "PhotosPreferenceSaving", "PhotosEditRecoveryUnavailable" => "PhotosEditRecoveryUnavailable",
        "PhotosUploadSignInAgain" => "PhotosUploadSignInAgain", _ => "PhotosPreferenceLoadFailed",
    };
}
