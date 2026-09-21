using System.ComponentModel;
using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadSettingsDialogContent : UserControl, IDisposable
{
    private readonly DownloadSettingsViewModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private bool _rendering;
    private bool _ready;
    private bool _completed;
    private DownloadStationSettingsSummary? _rendered;
    internal event Action? StateChanged;
    internal Style ActionButtonStyle => (Style)Resources["DownloadSettingsActionButtonStyle"];
    internal DownloadSettingsDialogContent(DownloadSettingsViewModel model)
    {
        InitializeComponent(); _model = model;
        DestinationBox.Header = _l.Get("DownloadSettingsDestination");
        DestinationUnavailable.Text = _l.Get("DownloadSettingsDestinationUnavailable");
        EmuleToggle.Header = _l.Get("DownloadSettingsEmule"); ExtractToggle.Header = _l.Get("DownloadSettingsExtract");
        BtDownload.Header = _l.Get("DownloadSettingsBtDownload"); BtUpload.Header = _l.Get("DownloadSettingsBtUpload");
        WebFtpDownload.Header = _l.Get("DownloadSettingsWebFtp"); NzbDownload.Header = _l.Get("DownloadSettingsNzb");
        EmuleDownload.Header = _l.Get("DownloadSettingsEmuleDownload"); EmuleUpload.Header = _l.Get("DownloadSettingsEmuleUpload");
        ScheduleToggle.Header = _l.Get("DownloadSettingsSchedule"); EmuleScheduleToggle.Header = _l.Get("DownloadSettingsEmuleSchedule");
        SpeedHint.Text = _l.Get("DownloadSettingsSpeedHint"); ImpactText.Text = _l.Get("DownloadSettingsImpact");
        Confirmation.Content = _l.Get("DownloadSettingsConfirm"); RefreshButton.Content = _l.Get("DownloadSettingsRefresh");
        foreach (var toggle in new[] { EmuleToggle, ExtractToggle, ScheduleToggle, EmuleScheduleToggle })
        { toggle.OnContent = _l.Get("DownloadSettingsOn"); toggle.OffContent = _l.Get("DownloadSettingsOff"); }
        BrowseButton.Content = _l.Get("DownloadSettingsBrowse"); FolderUpButton.Content = _l.Get("DownloadSettingsFolderUp");
        FolderCloseButton.Content = _l.Get("DownloadSettingsFolderClose"); OpenFolderButton.Content = _l.Get("DownloadSettingsFolderOpen");
        ChooseFolderButton.Content = _l.Get("DownloadSettingsFolderChoose"); FolderEmpty.Text = _l.Get("DownloadSettingsFoldersEmpty");
        AutomationProperties.SetName(FolderList, _l.Get("DownloadSettingsBrowse"));
        AutomationProperties.SetName(LoadingRing, _l.Get("DownloadSettingsLoading"));
        _model.PropertyChanged += ModelChanged; _ready = true; Render();
    }
    internal string PrimaryText => _l.Get(_model.RequiresReview ? "DownloadSettingsReview" : _model.CanContinue ? "DownloadSettingsContinue" : "DownloadSettingsSave");
    internal bool CanSubmit => !_completed && !_model.IsLoading && !_model.IsBusy && (_model.RequiresReview ||
        ((_model.CanContinue || _model.CanSave) && Confirmation.IsChecked == true));
    internal async Task SubmitAsync()
    {
        if (!CanSubmit) return;
        if (_model.RequiresReview) await _model.ReviewAsync();
        else if (_model.CanContinue) await _model.ContinueAsync();
        else await _model.SaveAsync();
        Confirmation.IsChecked = false;
        _completed = !_model.HasPending;
        Render();
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs e) => Render();
    private void Render()
    {
        if (!_ready || _rendering) return;
        _rendering = true;
        LoadingRing.IsActive = _model.IsLoading; LoadingRing.Visibility = Show(_model.IsLoading);
        ErrorPanel.Visibility = Show(_model.ErrorKey is not null); ErrorText.Text = _model.ErrorKey is { } error ? _l.Get(error) : "";
        Feedback.IsOpen = _model.FeedbackKey is not null; Feedback.Message = _model.FeedbackKey is { } feedback ? _l.Get(feedback) : "";
        Feedback.Severity = _model.HasPending ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        Editor.Visibility = Show(_model.Snapshot is not null && !_model.IsLoading && _model.ErrorKey is null);
        Editor.IsHitTestVisible = !_model.IsBusy && !_model.HasPending;
        foreach (var control in new Control[] { DestinationBox, EmuleToggle, ExtractToggle, BtDownload, BtUpload, WebFtpDownload, NzbDownload, EmuleDownload, EmuleUpload, ScheduleToggle, EmuleScheduleToggle })
            control.IsEnabled = !_model.IsBusy && !_model.HasPending;
        DestinationBox.IsEnabled &= _model.Snapshot?.CanEditDestination == true;
        DestinationBox.Visibility = Show(_model.Snapshot?.CanEditDestination == true);
        BrowseButton.Visibility = Show(_model.CanBrowseFolders); BrowseButton.IsEnabled = !_model.HasPending && !_model.IsBusy;
        FolderBrowser.Visibility = Show(_model.IsBrowsingFolders);
        FolderLoading.IsActive = _model.IsLoadingFolders; FolderLoading.Visibility = Show(_model.IsLoadingFolders);
        FolderPathText.Text = _model.FolderPath.Length == 0 ? _l.Get("DownloadSettingsFolderRoot") : _model.FolderPath;
        if (!ReferenceEquals(FolderList.ItemsSource, _model.Folders)) FolderList.ItemsSource = _model.Folders;
        FolderList.IsEnabled = !_model.IsLoadingFolders;
        OpenFolderButton.IsEnabled = !_model.IsLoadingFolders && FolderList.SelectedItem is FileCopyMoveFolder;
        ChooseFolderButton.IsEnabled = !_model.IsLoadingFolders && FolderList.SelectedItem is FileCopyMoveFolder { CanWrite: true };
        FolderUpButton.IsEnabled = !_model.IsLoadingFolders && _model.FolderPath.Length > 0;
        FolderError.Visibility = Show(_model.FolderErrorKey is not null); FolderError.Text = _model.FolderErrorKey is { } folderError ? _l.Get(folderError) : "";
        FolderEmpty.Visibility = Show(!_model.IsLoadingFolders && _model.FolderErrorKey is null && _model.Folders.Count == 0);
        DestinationUnavailable.Visibility = Show(_model.Snapshot?.CanEditDestination == false);
        var scheduleAvailable = _model.Snapshot?.ScheduleStatus == DownloadStationSectionStatus.Available;
        ScheduleToggle.IsEnabled &= scheduleAvailable; EmuleScheduleToggle.IsEnabled &= scheduleAvailable;
        ScheduleToggle.Visibility = EmuleScheduleToggle.Visibility = Show(scheduleAvailable);
        ScheduleHint.Text = _l.Get(_model.Snapshot?.ScheduleStatus == DownloadStationSectionStatus.Failed ? "DownloadSettingsScheduleFailed" : "DownloadSettingsScheduleUnavailable");
        ScheduleHint.Visibility = Show(!scheduleAvailable);
        if (_model.Draft is { } value && !ReferenceEquals(_rendered, value))
        {
            _rendered = value;
            DestinationBox.Text = value.DefaultDestination ?? ""; EmuleToggle.IsOn = value.IsEmuleEnabled == true; ExtractToggle.IsOn = value.IsAutoExtractEnabled == true;
            BtDownload.Value = value.BtDownloadLimitKb ?? double.NaN; BtUpload.Value = value.BtUploadLimitKb ?? double.NaN;
            WebFtpDownload.Value = value.HttpDownloadLimitKb ?? double.NaN; NzbDownload.Value = value.NzbDownloadLimitKb ?? double.NaN;
            EmuleDownload.Value = value.EmuleDownloadLimitKb ?? double.NaN; EmuleUpload.Value = value.EmuleUploadLimitKb ?? double.NaN;
            ScheduleToggle.IsOn = value.IsScheduleEnabled == true; EmuleScheduleToggle.IsOn = value.IsEmuleScheduleEnabled == true;
        }
        RefreshButton.IsEnabled = !_model.IsBusy && !_model.HasPending;
        Confirmation.IsEnabled = !_model.IsBusy && !_model.IsLoading && !_model.RequiresReview && !_model.IsBrowsingFolders;
        BasicResult.Visibility = ScheduleResult.Visibility = Show(_model.Outcome is not null);
        if (_model.Outcome is { } outcome)
        {
            BasicResult.Text = _l.Format("DownloadSettingsBasicResult", StateText(outcome.Basic));
            ScheduleResult.Text = _l.Format("DownloadSettingsScheduleResult", StateText(outcome.Schedule));
        }
        _rendering = false; StateChanged?.Invoke();
    }
    private string StateText(DownloadSettingsComponentState state) => _l.Get(state switch
    {
        DownloadSettingsComponentState.Unchanged => "DownloadSettingsUnchanged", DownloadSettingsComponentState.NotStarted => "DownloadSettingsNotStarted",
        DownloadSettingsComponentState.Unknown => "DownloadSettingsUnknown", DownloadSettingsComponentState.Confirmed => "DownloadSettingsConfirmed", _ => "DownloadSettingsRejected",
    });
    private void UpdateDraft()
    {
        if (!_ready || _rendering || _model.Draft is not { } value) return;
        static int? Limit(NumberBox box) => double.IsFinite(box.Value) && box.Value == Math.Truncate(box.Value) && box.Value is >= 0 and <= 1_000_000 ? (int)box.Value : null;
        _completed = false; Confirmation.IsChecked = false;
        _rendering = true;
        _model.SetDraft(value with { DefaultDestination = DestinationBox.Text, IsEmuleEnabled = EmuleToggle.IsOn, IsAutoExtractEnabled = ExtractToggle.IsOn,
            BtDownloadLimitKb = Limit(BtDownload), BtUploadLimitKb = Limit(BtUpload), HttpDownloadLimitKb = Limit(WebFtpDownload), FtpDownloadLimitKb = Limit(WebFtpDownload),
            NzbDownloadLimitKb = Limit(NzbDownload), EmuleDownloadLimitKb = Limit(EmuleDownload), EmuleUploadLimitKb = Limit(EmuleUpload),
            IsScheduleEnabled = ScheduleToggle.IsOn, IsEmuleScheduleEnabled = EmuleScheduleToggle.IsOn });
        _rendered = _model.Draft; _rendering = false; Render();
    }
    private void Text_Changed(object sender, TextChangedEventArgs e) => UpdateDraft();
    private void Toggle_Changed(object sender, RoutedEventArgs e) => UpdateDraft();
    private void Number_Changed(NumberBox sender, NumberBoxValueChangedEventArgs e) => UpdateDraft();
    private void Confirmation_Changed(object sender, RoutedEventArgs e) { if (_ready && !_rendering) StateChanged?.Invoke(); }
    private async void Refresh_Click(object sender, RoutedEventArgs e) { _completed = false; Confirmation.IsChecked = false; await _model.LoadAsync(); }
    private async void Browse_Click(object sender, RoutedEventArgs e) => await _model.BrowseFoldersAsync("");
    private void FolderSelection_Changed(object sender, SelectionChangedEventArgs e) { if (!_rendering) Render(); }
    private async void OpenFolder_Click(object sender, RoutedEventArgs e) { if (FolderList.SelectedItem is FileCopyMoveFolder folder) await _model.BrowseFoldersAsync(folder.Path); }
    private void ChooseFolder_Click(object sender, RoutedEventArgs e) { if (FolderList.SelectedItem is FileCopyMoveFolder folder) { _completed = false; Confirmation.IsChecked = false; _model.ChooseFolder(folder); } }
    private async void FolderUp_Click(object sender, RoutedEventArgs e)
    { var path = _model.FolderPath.TrimEnd('/'); var index = path.LastIndexOf('/'); await _model.BrowseFoldersAsync(index <= 0 ? "" : path[..index]); }
    private void FolderClose_Click(object sender, RoutedEventArgs e) => _model.CloseFolderBrowser();
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose() { _ready = false; _model.PropertyChanged -= ModelChanged; }
}
