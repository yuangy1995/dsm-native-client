using LanStash.App.Features.NasAdmin;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed record NasExternalStorageRow(string Name, string State, string Capacity);
public sealed partial class NasExternalStorageDialogContent : UserControl, INasSettingsDialogContent
{
    private readonly INasSettingsRepository _repository;
    private readonly NasExternalStorageViewModel _model = new();
    private bool _disposed, _synchronizing = true;
    public event Action? StateChanged;
    public bool CanSave => false;
    public bool IsBusy => _model.IsLoading;
    public string? PrimaryButtonResourceKey => null;
    public NasExternalStorageDialogContent(INasSettingsRepository repository)
    { _repository = repository; InitializeComponent(); _model.PropertyChanged += (_, _) => Refresh(); _synchronizing = false; }
    public Task ActivateAsync() => _model.ActivateAsync(_repository);
    public Task ReloadAsync() => _model.ReloadAsync();
    public Task SaveAsync() => Task.CompletedTask;
    private void Refresh()
    {
        if (_disposed) return; _synchronizing = true;
        LoadingIndicator.IsActive = IsBusy; LoadingIndicator.Visibility = IsBusy ? Visibility.Visible : Visibility.Collapsed;
        ErrorNotice.IsOpen = _model.ErrorMessage is not null; ErrorNotice.Message = _model.ErrorMessage ?? "";
        UnsupportedNotice.Visibility = _model.IsUnsupported ? Visibility.Visible : Visibility.Collapsed;
        var data = _model.Directory;
        CountText.Visibility = data is null ? Visibility.Collapsed : Visibility.Visible;
        CountText.Text = data is null ? "" : L.Format("NasExternalCount", data.Devices.Count, data.Total);
        PartialNotice.Visibility = data is { UnavailableSources: not NasExternalStorageSources.None } ? Visibility.Visible : Visibility.Collapsed;
        var missing = new List<string>();
        if (data?.UnavailableSources.HasFlag(NasExternalStorageSources.Usb) == true) missing.Add(L.Get("NasExternalUsb.Content"));
        if (data?.UnavailableSources.HasFlag(NasExternalStorageSources.Esata) == true) missing.Add(L.Get("NasExternalEsata.Content"));
        PartialNotice.Text = L.Format("NasExternalPartial", string.Join(L.Get("NasExternalSeparator"), missing));
        var incomplete = data is not null && (data.IsTruncated || data.IgnoredEntries > 0);
        IncompleteNotice.Visibility = incomplete ? Visibility.Visible : Visibility.Collapsed;
        FilterChoice.IsEnabled = data is not null && !IsBusy; FilterChoice.SelectedIndex = (int)_model.Filter;
        var visible = _model.VisibleDevices;
        DeviceList.ItemsSource = visible.Select(device => new NasExternalStorageRow(device.DisplayName ?? L.Get("NasExternalUnnamed"),
            L.Format("NasExternalState", L.Get(device.Connection == NasExternalStorageConnection.Usb ? "NasExternalUsb.Content" : "NasExternalEsata.Content"),
                L.Get(device.Status switch { NasExternalStorageStatus.Ready => "NasExternalReady", NasExternalStorageStatus.Busy => "NasExternalBusy",
                    NasExternalStorageStatus.Unavailable => "NasExternalOffline", _ => "UnknownValue" })),
            L.Format("NasExternalCapacity", Bytes(device.CapacityBytes), Bytes(device.UsedBytes)))).ToArray();
        EmptyNotice.Visibility = data is not null && visible.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyNotice.Text = L.Get(_model.SelectedSourceUnavailable ? "NasExternalSourceUnavailable" :
            data?.Devices.Count == 0 ? incomplete ? "NasExternalNoReadableRows" : "NasExternalEmpty" : "NasExternalNoMatches");
        _synchronizing = false; StateChanged?.Invoke();
    }
    private static string Bytes(long? value) => value is { } count ? NasDetailsViewModel.FormatBytes(count) : L.Get("UnknownValue");
    private void Filter_Changed(object sender, SelectionChangedEventArgs e)
    { if (!_disposed && !_synchronizing) _model.SetFilter((NasExternalStorageFilter)FilterChoice.SelectedIndex); }
    public void Dispose() { if (_disposed) return; _disposed = true; _model.Dispose(); DeviceList.ItemsSource = null; StateChanged = null; }
    private static LocalizationService L => LocalizationService.Current;
}
