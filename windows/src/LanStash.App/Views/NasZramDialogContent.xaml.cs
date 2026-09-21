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
    private bool _disposed;
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsLoading;
    public string? PrimaryButtonResourceKey => null;
    public NasZramDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        UnsupportedNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        var snapshot = _model.Snapshot;
        ContentPanel.Visibility = snapshot?.HasInformation == true ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Visibility = snapshot is { HasInformation: false } ? Visibility.Visible : Visibility.Collapsed;
        StatusText.Text = L.Get(snapshot?.IsEnabled switch { true => "NasZramEnabled", false => "NasZramDisabled", _ => "UnknownValue" });
        CapacityText.Text = snapshot?.ConfiguredBytes is { } bytes ? NasDetailsViewModel.FormatBytes(bytes) : L.Get("UnknownValue");
        AlgorithmText.Text = L.Get(snapshot?.Algorithm switch { NasZramAlgorithm.Lz4 => "NasZramLz4", NasZramAlgorithm.Lzo => "NasZramLzo",
            NasZramAlgorithm.Zstd => "NasZramZstd", _ => "UnknownValue" });
        StateChanged?.Invoke();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
