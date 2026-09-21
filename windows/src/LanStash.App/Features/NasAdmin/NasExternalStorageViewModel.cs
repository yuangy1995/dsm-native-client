using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public enum NasExternalStorageFilter { All, Usb, Esata }
public sealed class NasExternalStorageViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public NasExternalStorageDirectory? Directory { get; private set; }
    public NasExternalStorageFilter Filter { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsUnsupported { get; private set; }
    public string? ErrorMessage { get; private set; }
    public IReadOnlyList<NasExternalStorageDevice> VisibleDevices => Directory?.Devices.Where(device => Filter switch
    { NasExternalStorageFilter.Usb => device.Connection == NasExternalStorageConnection.Usb, NasExternalStorageFilter.Esata => device.Connection == NasExternalStorageConnection.Esata, _ => true })
        .OrderBy(device => device.Connection).ThenBy(device => device.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToArray() ?? [];
    public bool SelectedSourceUnavailable => Directory is { } data && (Filter switch
    {
        NasExternalStorageFilter.Usb => data.UnavailableSources.HasFlag(NasExternalStorageSources.Usb),
        NasExternalStorageFilter.Esata => data.UnavailableSources.HasFlag(NasExternalStorageSources.Esata),
        _ => false
    });
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsLoading) return;
        Cancel(); _cancellation = new(); var token = _cancellation.Token; var generation = ++_generation; var repository = _repository;
        IsLoading = true; Directory = null; ErrorMessage = null; IsUnsupported = false; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try { var directory = await repository.LoadExternalStorageAsync(token); if (Current()) Directory = directory; }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (DsmException error) when (error.Code == 102) { if (Current()) IsUnsupported = true; }
        catch { if (Current()) ErrorMessage = LocalizationService.Current.Get("NasExternalLoadFailed"); }
        finally { if (Current()) { IsLoading = false; Notify(); } }
    }
    public void SetFilter(NasExternalStorageFilter filter)
    { if (_disposed || !Enum.IsDefined(filter) || filter == Filter) return; Filter = filter; Notify(); }
    public void Deactivate()
    { Cancel(); _repository = null; Directory = null; Filter = NasExternalStorageFilter.All; IsLoading = IsUnsupported = false; ErrorMessage = null; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Cancel() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
}
