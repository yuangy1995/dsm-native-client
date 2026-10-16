using System.Net;
using System.Text;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed record NasPackageCatalogRow(NasPackageCatalogEntry Entry, string Detail, string AutomationName);
public sealed partial class NasPackageSettingsDialogContent
{
    private readonly DispatcherTimer _activityTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private NasPackageInstallPlan? _shownPlan;
    private NasPackageInstallConfiguration? _shownConfiguration;
    private NasPackageCenterSettings? _shownSettings;
    private IReadOnlyList<NasPackageSource>? _shownSources;
    private IReadOnlyList<NasPackageCategory>? _shownCategories;
    private NasPackageCatalogEntry[] _shownCatalog = [];
    private readonly Dictionary<string, ComboBox> _planVolumes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, Func<NasPackageOptionValue>> _optionReaders = new(StringComparer.Ordinal);
    private readonly Dictionary<string, ComboBox> _packagePolicies = new(StringComparer.Ordinal);
    private Func<Task>? _centerConfirmation;
    private string? _localCenterError;
    private int _centerPage;
    private sealed record Choice<T>(T Value, string Name);
    private void InitializeCenter()
    {
        SectionChoice.DisplayMemberPath = "Name";
        SectionChoice.ItemsSource = Enum.GetValues<NasPackageSection>().Select(value => new Choice<NasPackageSection>(value, L.Get(SectionKey(value)))).ToArray();
        SectionChoice.SelectedIndex = 0;
        UpdatePolicy.DisplayMemberPath = "Name";
        UpdatePolicy.ItemsSource = Enum.GetValues<NasPackageUpdatePolicy>().Select(value => new Choice<NasPackageUpdatePolicy>(value, L.Get(PolicyKey(value)))).ToArray();
        _activityTimer.Tick += async (_, _) => { if (!_disposed && (_model.HasPendingActivity || _model.Installation?.IsActive == true)) await _model.RefreshCenterActivityAsync(); };
        foreach (var control in new[] { BetaEnabled, EmailEnabled, DesktopEnabled })
        { control.Checked += PreferenceDraft_Changed; control.Unchecked += PreferenceDraft_Changed; }
        DefaultVolume.SelectionChanged += (_, _) => { if (!_synchronizing) ClearCenterConfirmation(); };
    }
    private void RefreshCenter()
    {
        CenterErrorNotice.Message = _localCenterError ?? _model.CenterError ?? ""; CenterErrorNotice.IsOpen = CenterErrorNotice.Message.Length > 0;
        CenterErrorNotice.Visibility = Show(CenterErrorNotice.IsOpen);
        CenterFeedbackNotice.IsOpen = _model.LastActivity is not null;
        CenterFeedbackNotice.Visibility = Show(CenterFeedbackNotice.IsOpen);
        if (_model.LastActivity is { } last)
        {
            CenterFeedbackNotice.Message = L.Get(last.Stage switch { NasPackageStepStage.Confirmed => "NasPackageCenterSaved",
                NasPackageStepStage.Cancelled => "NasPackageCenterQueueEnded", NasPackageStepStage.Rejected => "NasPackageCenterFailed", _ => "NasPackageCenterUnknown" });
            CenterFeedbackNotice.Severity = last.Stage == NasPackageStepStage.Confirmed ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
        }
        PreferencesButton.IsEnabled = SourcesButton.IsEnabled = !IsBusy;
        UploadButton.IsEnabled = _model.CanUpload;
        OpenDsmButton.Visibility = _repository.PackageCenterWebUri is null ? Visibility.Collapsed : Visibility.Visible;
        BrowsePanel.Visibility = Show(_centerPage == 0); PreferencesPanel.Visibility = Show(_centerPage == 1); SourcesPanel.Visibility = Show(_centerPage == 2);
        SectionChoice.IsEnabled = !IsBusy;
        InstalledPanel.Visibility = Show(_model.Section == NasPackageSection.Installed);
        CatalogPanel.Visibility = Show(_model.Section != NasPackageSection.Installed);
        CatalogSearchInput.IsEnabled = CategoryChoice.IsEnabled = CatalogList.IsEnabled = !IsBusy;
        if (!ReferenceEquals(_shownCategories, _model.Catalog?.Categories))
        {
            _shownCategories = _model.Catalog?.Categories;
            CategoryChoice.ItemsSource = new[] { new NasPackageCategory("", L.Get("NasPackageCenterAllCategories")) }.Concat(_shownCategories ?? []).ToArray();
        }
        CategoryChoice.SelectedValue = _model.CategoryId;
        var entries = _model.VisibleCatalog;
        if (!_shownCatalog.SequenceEqual(entries))
        {
            _shownCatalog = entries.ToArray();
            CatalogList.ItemsSource = _shownCatalog.Select(entry =>
            {
                var detail = L.Format("NasPackageCenterCatalogDetail", entry.Version, entry.Publisher);
                if (entry.SizeBytes is { } size) detail += Environment.NewLine + L.Format("NasPackageCenterDownloadSize", NasDetailsViewModel.FormatBytes(size));
                if (entry.InstalledVersion is not null) detail += Environment.NewLine + L.Format("NasPackageCenterInstalledVersion", entry.InstalledVersion);
                return new NasPackageCatalogRow(entry, detail, L.Format("NasDetailsRowAutomationName", entry.Name, detail));
            }).ToArray();
        }
        CatalogList.SelectedItem = CatalogList.Items.OfType<NasPackageCatalogRow>().FirstOrDefault(row => row.Entry.Id == _model.SelectedCatalog?.Id);
        CatalogEmptyNotice.Visibility = Show(!IsBusy && entries.Count == 0);
        CatalogEmptyNotice.Text = L.Get(_model.Catalog is null ? "NasPackageCenterCatalogUnavailable" : _model.Catalog.Entries.Count == 0 ? "NasPackageCenterCatalogEmpty" : "NasPackageNoMatches");
        CommunityNotice.Visibility = Show(_model.Section == NasPackageSection.Community && _model.Catalog?.CommunityAvailable == false);
        CatalogDescription.Text = Plain(_model.SelectedCatalog?.Description);
        CatalogReleaseNotes.Text = string.IsNullOrWhiteSpace(_model.SelectedCatalog?.ReleaseNotes) ? "" : L.Format("NasPackageCenterReleaseNotes", Plain(_model.SelectedCatalog.ReleaseNotes));
        PrepareButton.IsEnabled = _model.CanPrepare;
        PrepareUpdatesButton.Visibility = Show(_model.Section == NasPackageSection.Updates);
        PrepareUpdatesButton.IsEnabled = !IsBusy && !_model.HasPendingActivity && entries.Any(item => item.IsUpdateAvailable);
        RefreshPlan(); RefreshInstallation(); RefreshPreferences();
        ConfirmCenterButton.IsEnabled = !IsBusy && _centerConfirmation is not null;
    }
    private void RefreshPlan()
    {
        PreparationPanel.Visibility = Show(_model.IsPreparing || _model.InstallPlan is not null);
        if (!ReferenceEquals(_shownPlan, _model.InstallPlan))
        {
            _shownPlan = _model.InstallPlan; PlanItems.Children.Clear(); _planVolumes.Clear(); PlanStart.IsChecked = true;
            foreach (var item in _shownPlan?.Items ?? [])
            {
                PlanItems.Children.Add(new TextBlock { Text = L.Format("NasPackageCenterPlanItem", item.Package.Name, item.Package.Version), TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                if (item.Volumes.Count > 0)
                {
                    var volume = VolumeChoice(item.Volumes, item.DefaultVolumeId); _planVolumes.Add(item.Package.Id, volume); PlanItems.Children.Add(volume);
                }
            }
        }
        AffectedText.Text = _shownPlan?.AffectedPackages.Count > 0 ? L.Format("NasPackageCenterAffected", string.Join(Environment.NewLine, _shownPlan.AffectedPackages)) : "";
        AffectedText.Visibility = Show(AffectedText.Text.Length > 0);
        PlanStart.Visibility = PlanRisk.Visibility = Show(_shownPlan is not null);
        InstallProtectedNotice.Visibility = Show(_shownPlan is not null && !_model.CenterAvailability.CanInstall);
        InstallButton.IsEnabled = _model.CanStartInstallation;
        foreach (var control in _planVolumes.Values) control.IsEnabled = !IsBusy;
        PlanStart.IsEnabled = !IsBusy;
        CancelPreparationButton.IsEnabled = _model.IsPreparing || !IsBusy;
    }
    private void RefreshInstallation()
    {
        var progress = _model.Installation;
        ActivityPanel.Visibility = Show(progress is not null || _model.Activities.Any(item => item.IsPending && item.Kind != NasPackageActivityKind.Control) || _model.CenterError is not null && _model.HasPendingActivity);
        ActivityText.Text = progress is null ? L.Get("NasPackageCenterUnknown") :
            L.Format("NasPackageCenterProgress", NasPackageManagementViewModel.RecoveryName(progress.PackageName), L.Get(PhaseKey(progress.Phase)), progress.CompletedCount, progress.TotalCount);
        if (progress?.MessageKey is { } message) ActivityText.Text += Environment.NewLine + L.Get(message);
        InstallProgress.Visibility = Show(progress?.IsActive == true);
        InstallProgress.IsIndeterminate = progress?.Fraction is null; InstallProgress.Value = (progress?.Fraction ?? 0) * 100;
        RefreshActivityButton.IsEnabled = !IsBusy;
        CancelInstallButton.Visibility = Show(progress?.CanCancel == true); CancelInstallButton.IsEnabled = !IsBusy;
        EndQueueButton.Visibility = Show(_model.Activities.Any(item => item.IsPending && item.CanEndQueue)); EndQueueButton.IsEnabled = !IsBusy;
        var configuration = progress?.Phase == NasPackageInstallPhase.NeedsOptions ? progress.Configuration : null;
        InstallOptionsPanel.Visibility = Show(configuration is not null);
        foreach (var control in InstallFields.Children.OfType<Control>()) control.IsEnabled = !IsBusy;
        AcceptLicense.IsEnabled = ConfigurationVolume.IsEnabled = ConfigurationStart.IsEnabled = !IsBusy;
        ConfigureButton.IsEnabled = !IsBusy && _model.CenterAvailability.CanInstall;
        if (ReferenceEquals(configuration, _shownConfiguration)) return;
        _shownConfiguration = configuration; InstallFields.Children.Clear(); _optionReaders.Clear(); AcceptLicense.IsChecked = false;
        if (configuration is null) return;
        InstallOptionsTitle.Text = L.Format("NasPackageCenterPlanItem", configuration.PackageName, configuration.Version);
        LicenseText.Text = Plain(configuration.License); LicenseText.Visibility = AcceptLicense.Visibility = Show(configuration.License is not null);
        RestartNotice.Visibility = Show(configuration.RequiresRestart);
        ConfigurationVolume.ItemsSource = configuration.Volumes; ConfigurationVolume.SelectedValue = configuration.DefaultVolumeId;
        ConfigurationVolume.Visibility = Show(configuration.Volumes.Count > 0);
        ConfigurationStart.Visibility = Show(configuration.CanStart); ConfigurationStart.IsChecked = configuration.CanStart;
        foreach (var field in configuration.Fields)
        {
            var label = Plain(field.Label);
            if (field.Kind == NasPackageOptionKind.Description)
            { InstallFields.Children.Add(new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap }); continue; }
            FrameworkElement control;
            if (field.Kind == NasPackageOptionKind.Password)
            {
                var box = new PasswordBox { Header = label, Password = field.DefaultValue.Text ?? "" };
                _optionReaders[field.Id] = () => new(Text: box.Password); control = box;
            }
            else if (field.Kind is NasPackageOptionKind.Toggle or NasPackageOptionKind.Radio)
            {
                Microsoft.UI.Xaml.Controls.Primitives.ToggleButton box = field.Kind == NasPackageOptionKind.Radio ?
                    new RadioButton { GroupName = "package-option-" + field.Group } : new CheckBox();
                box.Content = label; box.IsChecked = field.DefaultValue.Flag == true;
                _optionReaders[field.Id] = () => new(Flag: box.IsChecked == true); control = box;
            }
            else if (field.Kind == NasPackageOptionKind.Choice)
            {
                var box = new ComboBox { Header = label, DisplayMemberPath = "Name", SelectedValuePath = "Id", ItemsSource = field.Choices, SelectedValue = field.DefaultValue.Text, HorizontalAlignment = HorizontalAlignment.Stretch };
                _optionReaders[field.Id] = () => new(Text: box.SelectedValue as string ?? ""); control = box;
            }
            else
            {
                var box = new TextBox { Header = label, Text = field.DefaultValue.Text ?? "" };
                _optionReaders[field.Id] = () => new(Text: box.Text); control = box;
            }
            AutomationProperties.SetName(control, label); InstallFields.Children.Add(control);
        }
    }
    private void RefreshPreferences()
    {
        if (!ReferenceEquals(_shownSettings, _model.CenterSettings))
        {
            _shownSettings = _model.CenterSettings; PackageUpdatePolicies.Children.Clear(); _packagePolicies.Clear();
            if (_shownSettings is { } settings)
            {
                BetaEnabled.IsChecked = settings.BetaEnabled; EmailEnabled.IsChecked = settings.EmailNotifications; DesktopEnabled.IsChecked = settings.DesktopNotifications;
                DefaultVolume.ItemsSource = new[] { new NasPackageInstallVolume("", L.Get("NasPackageCenterAskVolume")) }.Concat(settings.Volumes).ToArray();
                DefaultVolume.SelectedValue = settings.DefaultVolumeId; DefaultVolume.Visibility = Show(settings.Volumes.Count > 1);
                UpdatePolicy.SelectedItem = UpdatePolicy.Items.OfType<Choice<NasPackageUpdatePolicy>>().First(item => item.Value == settings.UpdatePolicy);
                foreach (var item in settings.PackageUpdates)
                {
                    var choices = Enum.GetValues<NasPackageSingleUpdatePolicy>().Select(value => new Choice<NasPackageSingleUpdatePolicy?>(value, L.Get(value switch
                    { NasPackageSingleUpdatePolicy.Important => "NasPackageCenterPolicyImportant", NasPackageSingleUpdatePolicy.Latest => "NasPackageCenterPolicyLatest", _ => "NasPackageCenterPolicyManual" }))).ToList();
                    if (item.Policy is null) choices.Insert(0, new(null, L.Get("UnknownValue")));
                    var box = new ComboBox { Header = item.Name, ItemsSource = choices, DisplayMemberPath = "Name", SelectedItem = choices.First(choice => choice.Value == item.Policy), HorizontalAlignment = HorizontalAlignment.Stretch,
                        IsEnabled = item.CanUpdateAutomatically && _model.CenterAvailability.CanEnableAutomaticUpdates };
                    box.SelectionChanged += (_, _) => { if (!_synchronizing) ClearCenterConfirmation(); };
                    _packagePolicies.Add(item.Id, box); PackageUpdatePolicies.Children.Add(box);
                }
            }
        }
        BetaEnabled.IsEnabled = EmailEnabled.IsEnabled = DesktopEnabled.IsEnabled = DefaultVolume.IsEnabled = _model.CanChangeSettings;
        UpdatePolicy.IsEnabled = _model.CanChangeSettings;
        AutoUpdateProtected.Visibility = Show(!_model.CenterAvailability.CanEnableAutomaticUpdates);
        PackageUpdatePolicies.Visibility = Show((UpdatePolicy.SelectedItem as Choice<NasPackageUpdatePolicy>)?.Value == NasPackageUpdatePolicy.Selected);
        foreach (var item in _shownSettings?.PackageUpdates ?? [])
            _packagePolicies[item.Id].IsEnabled = _model.CanChangeSettings && item.CanUpdateAutomatically && _model.CenterAvailability.CanEnableAutomaticUpdates;
        SavePreferencesButton.IsEnabled = _model.CanChangeSettings;
        if (!ReferenceEquals(_shownSources, _model.Sources))
        {
            _shownSources = _model.Sources; SourceList.ItemsSource = _shownSources; SourceList.SelectedItem = null; SourceName.Text = SourceUrl.Text = "";
        }
        SourceList.IsEnabled = !IsBusy; SourceName.IsEnabled = SourceUrl.IsEnabled = _model.CanChangeSources && _model.CenterAvailability.CanTrustSources;
        NewSourceButton.IsEnabled = SaveSourceButton.IsEnabled = _model.CanChangeSources && _model.CenterAvailability.CanTrustSources;
        RemoveSourceButton.IsEnabled = _model.CanChangeSources && SourceList.SelectedItem is NasPackageSource;
        SourcesEmptyNotice.Visibility = Show(_shownSources?.Count == 0); SourceProtected.Visibility = Show(!_model.CenterAvailability.CanTrustSources);
    }
    private static ComboBox VolumeChoice(IReadOnlyList<NasPackageInstallVolume> volumes, string selected) => new()
    { Header = L.Get("NasPackageCenterVolume.Header"), ItemsSource = volumes, DisplayMemberPath = "Name", SelectedValuePath = "Id", SelectedValue = selected, HorizontalAlignment = HorizontalAlignment.Stretch };
    private static Visibility Show(bool show) => show ? Visibility.Visible : Visibility.Collapsed;
    private static string SectionKey(NasPackageSection value) => value switch
    { NasPackageSection.Updates => "NasPackageCenterSectionUpdates", NasPackageSection.All => "NasPackageCenterSectionAll", NasPackageSection.Beta => "NasPackageCenterSectionBeta",
        NasPackageSection.Community => "NasPackageCenterSectionCommunity", _ => "NasPackageCenterSectionInstalled" };
    private static string PolicyKey(NasPackageUpdatePolicy value) => value switch
    { NasPackageUpdatePolicy.Important => "NasPackageCenterPolicyImportant", NasPackageUpdatePolicy.Latest => "NasPackageCenterPolicyLatest",
        NasPackageUpdatePolicy.Selected => "NasPackageCenterPolicySelected", _ => "NasPackageCenterPolicyManual" };
    private static string PhaseKey(NasPackageInstallPhase value) => value switch
    { NasPackageInstallPhase.Uploading => "NasPackageCenterPhaseUploading", NasPackageInstallPhase.Downloading => "NasPackageCenterPhaseDownloading",
        NasPackageInstallPhase.Installing => "NasPackageCenterPhaseInstalling", NasPackageInstallPhase.NeedsOptions => "NasPackageCenterPhaseNeedsOptions",
        NasPackageInstallPhase.Completed => "NasPackageCenterPhaseCompleted", NasPackageInstallPhase.Failed => "NasPackageCenterPhaseFailed",
        NasPackageInstallPhase.Cancelled => "NasPackageCenterPhaseCancelled", NasPackageInstallPhase.Interrupted => "NasPackageCenterPhaseInterrupted", _ => "NasPackageCenterPhaseUnknown" };
    private static string Plain(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        var text = new StringBuilder(value.Length); var insideTag = false;
        foreach (var character in value)
        {
            if (character == '<') { insideTag = true; text.Append(' '); }
            else if (character == '>' && insideTag) insideTag = false;
            else if (!insideTag) text.Append(character);
        }
        return WebUtility.HtmlDecode(text.ToString()).Trim();
    }
    private void Section_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_synchronizing && SectionChoice.SelectedItem is Choice<NasPackageSection> choice) _model.SelectSection(choice.Value); }
    private void CatalogFilter_Changed(object sender, TextChangedEventArgs e) => FilterCatalog();
    private void Category_Changed(object sender, SelectionChangedEventArgs e) => FilterCatalog();
    private void FilterCatalog() { if (!_synchronizing) _model.FilterCatalog(CatalogSearchInput.Text, CategoryChoice.SelectedValue as string ?? ""); }
    private void CatalogSelection_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_synchronizing) _model.SelectCatalog((CatalogList.SelectedItem as NasPackageCatalogRow)?.Entry.Id); }
    private async void Prepare_Click(object sender, RoutedEventArgs e) { await _model.PrepareInstallationAsync(); ShowPreparation(); }
    private async void PrepareUpdates_Click(object sender, RoutedEventArgs e) { await _model.PrepareInstallationAsync(true); ShowPreparation(); }
    private void ShowPreparation()
    { if (!_disposed && _model.InstallPlan is not null) PreparationPanel.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false }); }
    private void CancelPreparation_Click(object sender, RoutedEventArgs e) => _model.CancelPreparation();
    private async void Install_Click(object sender, RoutedEventArgs e) => await _model.StartInstallationAsync(
        _planVolumes.ToDictionary(pair => pair.Key, pair => pair.Value.SelectedValue as string ?? "", StringComparer.Ordinal), PlanStart.IsChecked == true);
    private async void Configure_Click(object sender, RoutedEventArgs e)
    {
        var values = _optionReaders.ToDictionary(pair => pair.Key, pair => pair.Value(), StringComparer.Ordinal);
        if (_shownConfiguration is not { } configuration || !configuration.Accepts(values) || configuration.License is not null && AcceptLicense.IsChecked != true)
        { ShowCenterError("NasPackageCenterOptionsInvalid"); return; }
        ClearLocalCenterError();
        await _model.ConfigureInstallationAsync(ConfigurationVolume.SelectedValue as string ?? "", ConfigurationStart.IsChecked == true, AcceptLicense.IsChecked == true, values);
        values.Clear();
    }
    private async void RefreshActivity_Click(object sender, RoutedEventArgs e) => await _model.RefreshCenterActivityAsync(true);
    private void CancelInstall_Click(object sender, RoutedEventArgs e) => ConfirmCenter("NasPackageCenterCancelRisk", _model.CancelInstallationAsync);
    private void EndQueue_Click(object sender, RoutedEventArgs e) => ConfirmCenter("NasPackageCenterEndRisk", _model.EndRemainingAsync);
    private async void Preferences_Click(object sender, RoutedEventArgs e)
    { if (IsBusy) return; _centerPage = 1; ClearLocalCenterError(); ClearCenterConfirmation(); await _model.LoadPreferencesAsync(false); }
    private async void Sources_Click(object sender, RoutedEventArgs e)
    { if (IsBusy) return; _centerPage = 2; ClearLocalCenterError(); ClearCenterConfirmation(); await _model.LoadPreferencesAsync(true); }
    private void Back_Click(object sender, RoutedEventArgs e) { if (IsBusy) return; _centerPage = 0; ClearLocalCenterError(); ClearCenterConfirmation(); Refresh(); }
    private void PreferenceDraft_Changed(object sender, RoutedEventArgs e) { if (!_synchronizing) ClearCenterConfirmation(); }
    private void Policy_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_synchronizing) return; ClearCenterConfirmation();
        if (!_model.CenterAvailability.CanEnableAutomaticUpdates && UpdatePolicy.SelectedItem is Choice<NasPackageUpdatePolicy> { Value: not NasPackageUpdatePolicy.Manual } choice && choice.Value != _shownSettings?.UpdatePolicy)
        {
            _synchronizing = true; UpdatePolicy.SelectedItem = UpdatePolicy.Items.OfType<Choice<NasPackageUpdatePolicy>>().FirstOrDefault(item => item.Value == _shownSettings?.UpdatePolicy); _synchronizing = false;
        }
        PackageUpdatePolicies.Visibility = Show((UpdatePolicy.SelectedItem as Choice<NasPackageUpdatePolicy>)?.Value == NasPackageUpdatePolicy.Selected);
    }
    private void SavePreferences_Click(object sender, RoutedEventArgs e)
    {
        if (!_model.CanChangeSettings || _shownSettings is not { } settings || UpdatePolicy.SelectedItem is not Choice<NasPackageUpdatePolicy> choice) return;
        var desired = settings with { BetaEnabled = BetaEnabled.IsChecked == true, EmailNotifications = EmailEnabled.IsChecked == true, DesktopNotifications = DesktopEnabled.IsChecked == true,
            DefaultVolumeId = DefaultVolume.SelectedValue as string ?? settings.DefaultVolumeId, UpdatePolicy = choice.Value,
            PackageUpdates = settings.PackageUpdates.Select(item => item with { Policy = (_packagePolicies[item.Id].SelectedItem as Choice<NasPackageSingleUpdatePolicy?>)?.Value }).ToArray() };
        ConfirmCenter("NasPackageCenterSettingsRisk", () => _model.SaveSettingsAsync(desired));
    }
    private void SourceSelection_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_synchronizing) return; ClearCenterConfirmation(); _synchronizing = true;
        SourceName.Text = (SourceList.SelectedItem as NasPackageSource)?.Name ?? ""; SourceUrl.Text = (SourceList.SelectedItem as NasPackageSource)?.Url ?? "";
        _synchronizing = false; Refresh();
    }
    private void SourceDraft_Changed(object sender, TextChangedEventArgs e) { if (!_synchronizing) ClearCenterConfirmation(); }
    private void NewSource_Click(object sender, RoutedEventArgs e)
    { if (IsBusy) return; SourceList.SelectedItem = null; SourceName.Text = SourceUrl.Text = ""; ClearCenterConfirmation(); }
    private void SaveSource_Click(object sender, RoutedEventArgs e)
    {
        if (!_model.CanChangeSources || !_model.CenterAvailability.CanTrustSources) return;
        var source = new NasPackageSource(SourceName.Text, SourceUrl.Text).Normalize();
        if (source is null) { ShowCenterError("NasPackageCenterSourceInvalid"); return; }
        var baseline = SourceList.SelectedItem as NasPackageSource;
        ConfirmCenter("NasPackageCenterSourceRisk", () => _model.SaveSourceAsync(baseline, source));
        if (new Uri(source.Url).Scheme == "http") CenterConfirmationText.Text += Environment.NewLine + L.Get("NasPackageCenterSourceHttpRisk");
    }
    private void RemoveSource_Click(object sender, RoutedEventArgs e)
    { if (SourceList.SelectedItem is NasPackageSource source && _model.CanChangeSources) ConfirmCenter("NasPackageCenterRemoveSourceRisk", () => _model.SaveSourceAsync(source, null)); }
    private void ConfirmCenter(string key, Func<Task> action)
    {
        ClearLocalCenterError(); _centerConfirmation = action; CenterConfirmationText.Text = L.Get(key); CenterConfirmationPanel.Visibility = Visibility.Visible; ConfirmCenterButton.IsEnabled = !IsBusy;
        DispatcherQueue.TryEnqueue(() => { if (!_disposed && _centerConfirmation is not null) CenterConfirmationPanel.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false }); });
    }
    private void ClearCenterConfirmation() { _centerConfirmation = null; CenterConfirmationPanel.Visibility = Visibility.Collapsed; }
    private async void ConfirmCenter_Click(object sender, RoutedEventArgs e)
    { if (IsBusy || _centerConfirmation is not { } action) return; ClearCenterConfirmation(); await action(); }
    private void CancelCenter_Click(object sender, RoutedEventArgs e) => ClearCenterConfirmation();
    private async void Upload_Click(object sender, RoutedEventArgs e)
    {
        if (!_model.CanUpload || (Application.Current as App)?.MainWindow is not { } window) return;
        ClearLocalCenterError();
        try
        {
            var picker = new FileOpenPicker(Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(window)));
            picker.FileTypeFilter.Add(".spk"); var file = await picker.PickSingleFileAsync();
            if (!_disposed && file is not null && _model.CanUpload) ConfirmCenter("NasPackageCenterUploadRisk", () => _model.UploadAsync(file.Path));
        }
        catch { if (!_disposed) ShowCenterError("NasPackageCenterFileUnavailable"); }
    }
    private async void OpenDsm_Click(object sender, RoutedEventArgs e)
    {
        if (_repository.PackageCenterWebUri is not { } uri) return;
        ClearLocalCenterError();
        try { if (await Windows.System.Launcher.LaunchUriAsync(uri)) return; }
        catch { }
        if (!_disposed) ShowCenterError("NasPackageCenterBrowserFailed");
    }
    private void ShowCenterError(string key)
    {
        _localCenterError = L.Get(key); CenterErrorNotice.Message = _localCenterError; CenterErrorNotice.IsOpen = true; CenterErrorNotice.Visibility = Visibility.Visible;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || _localCenterError is null) return;
            ContentScroll.UpdateLayout();
            ContentScroll.ChangeView(null, 0, null, true);
        });
    }
    private void ClearLocalCenterError()
    { _localCenterError = null; CenterErrorNotice.Message = _model.CenterError ?? ""; CenterErrorNotice.IsOpen = _model.CenterError is not null; CenterErrorNotice.Visibility = Show(CenterErrorNotice.IsOpen); }
}
