using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasPowerSettingsDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasPowerViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => null;
    public NasPowerSettingsDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        FeedbackNotice.IsOpen = _model.Feedback is not null; FeedbackNotice.Message = _model.Feedback ?? "";
        FeedbackNotice.Severity = _model.Recovery?.Result.Status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission
            ? InfoBarSeverity.Warning : InfoBarSeverity.Informational;
        ReadOnlyNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        ShutdownButton.IsEnabled = RebootButton.IsEnabled = _model.CanChoose;
        ConfirmationPanel.Visibility = _model.Action is not null && _model.Recovery is null ? Visibility.Visible : Visibility.Collapsed;
        ConfirmationText.Text = _model.ConfirmationMessage ?? "";
        RiskAcknowledgement.IsEnabled = _model.CanChoose; if (!_model.CanExecute) RiskAcknowledgement.IsChecked = false;
        ExecuteButton.Content = L.Get(_model.Action == NasPowerAction.Shutdown ? "NasSettingsShutdownLabel" : "NasSettingsRebootLabel");
        ExecuteButton.IsEnabled = _model.CanExecute;
        RecoveryPanel.Visibility = _model.Recovery is not null ? Visibility.Visible : Visibility.Collapsed;
        RecoveryText.Text = L.Get(_model.Recovery?.HasFreshSession == true ? "NasPowerCheckDevice" : "NasPowerReconnectFirst");
        DeviceChecked.IsEnabled = _model.CanAcknowledge;
        if (!_model.CanAcknowledge) DeviceChecked.IsChecked = false;
        AcknowledgeButton.IsEnabled = _model.CanAcknowledge && DeviceChecked.IsChecked == true;
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void Shutdown_Click(object sender, RoutedEventArgs e) => _model.RequestShutdown();
    private void Reboot_Click(object sender, RoutedEventArgs e) => _model.RequestReboot();
    private void Risk_Changed(object sender, RoutedEventArgs e) { if (!_synchronizing) _model.ConfirmAction(RiskAcknowledgement.IsChecked == true); }
    private async void Execute_Click(object sender, RoutedEventArgs e) => await _model.ExecuteActionAsync();
    private void Device_Changed(object sender, RoutedEventArgs e) { if (!_synchronizing) Refresh(); }
    private async void Acknowledge_Click(object sender, RoutedEventArgs e) => await _model.AcknowledgeAsync(DeviceChecked.IsChecked == true);
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
