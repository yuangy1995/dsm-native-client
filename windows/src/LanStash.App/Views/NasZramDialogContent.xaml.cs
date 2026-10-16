using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class NasZramDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasZramViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool CanSave => _model.CanSave;
    public bool IsBusy => _model.IsBusy;
    public string? PrimaryButtonResourceKey => "NasHardwareEditSave";
    public NasZramDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => _model.SaveAsync();
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        UnsupportedNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        var snapshot = _model.Snapshot;
        ContentPanel.Visibility = snapshot?.HasInformation == true ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = snapshot is { HasInformation: false } ? Visibility.Visible : Visibility.Collapsed;
        EnabledToggle.IsOn = _model.DesiredEnabled; EnabledToggle.IsEnabled = _model.CanEdit;
        EnabledToggle.Visibility = snapshot?.IsEnabled is not null ? Visibility.Visible : Visibility.Collapsed;
        StatusTitle.Visibility = StatusText.Visibility = snapshot?.IsEnabled is null ? Visibility.Visible : Visibility.Collapsed;
        RebootText.Visibility = snapshot?.NeedsReboot == true ? Visibility.Visible : Visibility.Collapsed; RebootText.Text = L.Get("NasZramRebootRequired");
        ResultNotice.IsOpen = _model.StatusKey is not null; ResultNotice.Message = _model.StatusKey is { } status ? L.Get(status) : "";
        ResultNotice.Severity = _model.Recovery?.IsComplete == true ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        WriteUnavailable.Text = L.Get("NasHardwareEditUnavailable");
        WriteUnavailable.Visibility = !IsBusy && snapshot?.IsEnabled is not null && !_model.CanEdit && _model.Recovery?.HasUnknown != true && _model.Recovery?.CanMarkReboot != true ? Visibility.Visible : Visibility.Collapsed;
        CapacityTitle.Visibility = CapacityText.Visibility = snapshot?.ConfiguredBytes is not null ? Visibility.Visible : Visibility.Collapsed;
        AlgorithmTitle.Visibility = AlgorithmText.Visibility = snapshot is { Algorithm: not NasZramAlgorithm.Unknown } ? Visibility.Visible : Visibility.Collapsed;
        RiskChoice.Visibility = _model.CanEdit && snapshot?.IsEnabled != _model.DesiredEnabled || _model.Recovery?.CanMarkReboot == true ? Visibility.Visible : Visibility.Collapsed;
        RiskChoice.IsEnabled = !IsBusy; RiskChoice.IsChecked = _model.RiskConfirmed;
        MarkRebootButton.Visibility = _model.Recovery?.CanMarkReboot == true ? Visibility.Visible : Visibility.Collapsed; MarkRebootButton.IsEnabled = _model.CanMarkReboot;
        StatusText.Text = L.Get(snapshot?.IsEnabled switch { true => "NasZramEnabled", false => "NasZramDisabled", _ => "UnknownValue" });
        CapacityText.Text = snapshot?.ConfiguredBytes is { } bytes ? NasDetailsViewModel.FormatBytes(bytes) : L.Get("UnknownValue");
        AlgorithmText.Text = L.Get(snapshot?.Algorithm switch { NasZramAlgorithm.Lz4 => "NasZramLz4", NasZramAlgorithm.Lzo => "NasZramLzo",
            NasZramAlgorithm.Zstd => "NasZramZstd", _ => "UnknownValue" });
        _synchronizing = false; StateChanged?.Invoke();
    }
    private void Enabled_Changed(object sender, RoutedEventArgs e) { if (!_disposed && !_synchronizing) _model.SetEnabled(EnabledToggle.IsOn); }
    private void Risk_Changed(object sender, RoutedEventArgs e) { if (!_disposed && !_synchronizing) _model.ConfirmRisk(RiskChoice.IsChecked == true); }
    private async void MarkReboot_Click(object sender, RoutedEventArgs e) => await _model.MarkRebootAsync();
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
