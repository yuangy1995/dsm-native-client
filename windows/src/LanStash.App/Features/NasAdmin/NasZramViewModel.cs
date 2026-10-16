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
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool DesiredEnabled { get; private set; }
    public bool RiskConfirmed { get; private set; }
    private bool _canWrite;
    public NasHardwareEditRecovery? Recovery { get; private set; }
    public string? StatusKey => NasHardwareEditPresentation.Status(Recovery);
    public bool CanEdit => !_disposed && !IsBusy && ErrorMessage is null && _canWrite && Snapshot is { IsEnabled: not null, NeedsReboot: not null } &&
        Recovery?.HasUnknown != true && Recovery?.CanMarkReboot != true;
    public bool CanSave => CanEdit && RiskConfirmed && Snapshot!.IsEnabled != DesiredEnabled;
    public bool CanMarkReboot => !_disposed && !IsBusy && ErrorMessage is null && _canWrite && RiskConfirmed && Recovery?.CanMarkReboot == true;
    public void SetEnabled(bool enabled) { if (!CanEdit || DesiredEnabled == enabled) return; DesiredEnabled = enabled; RiskConfirmed = false; Notify(); }
    public void ConfirmRisk(bool confirmed) { if (_disposed || IsBusy) return; RiskConfirmed = confirmed; Notify(); }
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        Cancel(); _cancellation = new(); var token = _cancellation.Token; var generation = ++_generation; var repository = _repository;
        IsLoading = true; Snapshot = null; ErrorMessage = null; IsUnsupported = false; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try
        {
            var recovery = await NasHardwareEditPresentation.LoadAsync(repository, NasHardwareEditKind.Zram, token);
            var snapshot = await repository.LoadZramAsync(token);
            var availability = await repository.PrepareServiceSettingsAsync(token);
            if (Current()) { Snapshot = snapshot; DesiredEnabled = snapshot.IsEnabled == true; Recovery = recovery; _canWrite = availability.CanSaveZram; RiskConfirmed = false; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (DsmException error) when (error.Code == 102) { if (Current()) IsUnsupported = true; }
        catch { if (Current()) ErrorMessage = LocalizationService.Current.Get("NasZramLoadFailed"); }
        finally { if (Current()) { IsLoading = false; Notify(); } }
    }
    public Task SaveAsync() => SaveCoreAsync(false);
    public Task MarkRebootAsync() => SaveCoreAsync(true);
    private async Task SaveCoreAsync(bool marker)
    {
        if (_repository is null || (marker ? !CanMarkReboot : !CanSave)) return;
        var repository = _repository; var generation = _generation; var token = _cancellation?.Token ?? CancellationToken.None;
        var request = new NasZramSaveRequest(repository.ProfileId, Guid.NewGuid(), Snapshot!, DesiredEnabled, RiskConfirmed);
        var id = Recovery?.Id ?? Guid.Empty;
        IsSaving = true; ErrorMessage = null; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try
        {
            var result = marker ? await repository.MarkZramRebootAsync(id, true, token) : await repository.SaveZramAsync(request, token);
            if (!Current()) return; Recovery = result; RiskConfirmed = false;
            var actual = await repository.LoadZramAsync(token);
            if (Current()) { Snapshot = actual; DesiredEnabled = actual.IsEnabled == true; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { if (Current()) ErrorMessage = LocalizationService.Current.Get(NasHardwareEditPresentation.Error(error)); }
        finally { if (Current()) { IsSaving = false; Notify(); } }
    }
    public void Deactivate()
    { Cancel(); _repository = null; Snapshot = null; Recovery = null; _canWrite = RiskConfirmed = DesiredEnabled = IsSaving = IsLoading = IsUnsupported = false; ErrorMessage = null; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Cancel() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
}
