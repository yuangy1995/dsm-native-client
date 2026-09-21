using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasZramViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public NasZramSnapshot? Snapshot { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsUnsupported { get; private set; }
    public string? ErrorMessage { get; private set; }
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsLoading) return;
        Cancel(); _cancellation = new(); var token = _cancellation.Token; var generation = ++_generation; var repository = _repository;
        IsLoading = true; Snapshot = null; ErrorMessage = null; IsUnsupported = false; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try { var snapshot = await repository.LoadZramAsync(token); if (Current()) Snapshot = snapshot; }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (DsmException error) when (error.Code == 102) { if (Current()) IsUnsupported = true; }
        catch { if (Current()) ErrorMessage = LocalizationService.Current.Get("NasZramLoadFailed"); }
        finally { if (Current()) { IsLoading = false; Notify(); } }
    }
    public void Deactivate()
    { Cancel(); _repository = null; Snapshot = null; IsLoading = IsUnsupported = false; ErrorMessage = null; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Cancel() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
}
