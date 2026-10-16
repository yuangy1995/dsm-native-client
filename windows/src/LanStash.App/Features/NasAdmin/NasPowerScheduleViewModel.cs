using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public enum NasPowerScheduleFilter { All, Enabled, Disabled }
public sealed class NasPowerScheduleViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed;
    public NasPowerScheduleSnapshot? Snapshot { get; private set; }
    public NasPowerScheduleFilter Filter { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsUnsupported { get; private set; }
    public string? ErrorMessage { get; private set; }
    private IReadOnlyList<NasPowerScheduleEntry> _draft = [];
    private bool _canWrite;
    public IReadOnlyList<NasPowerScheduleEntry> Draft => _draft;
    public bool IsSaving { get; private set; }
    public bool IsBusy => IsLoading || IsSaving;
    public bool RiskConfirmed { get; private set; }
    public bool HasChanges { get; private set; }
    public NasHardwareEditRecovery? Recovery { get; private set; }
    public string? StatusKey => NasHardwareEditPresentation.Status(Recovery);
    public bool CanEdit => !_disposed && !IsBusy && ErrorMessage is null && Snapshot?.CanEdit == true && Recovery?.HasUnknown != true;
    public bool CanSave => CanEdit && _canWrite && HasChanges && RiskConfirmed && NasPowerScheduleRules.IsValid(_draft);
    public bool IsWriteAvailable => _canWrite;
    public IReadOnlyList<NasPowerScheduleEntry> VisibleEntries => _draft.Where(entry => Filter switch
    { NasPowerScheduleFilter.Enabled => entry.IsEnabled == true, NasPowerScheduleFilter.Disabled => entry.IsEnabled == false, _ => true }).ToArray();
    public bool PutEntry(NasPowerScheduleEntry entry, string? replacingId = null)
    {
        if (!CanEdit || replacingId is not null && !_draft.Any(item => item.Id == replacingId)) return false;
        var updated = replacingId is null ? _draft.Append(entry with { Id = Guid.NewGuid().ToString("N"), Weekdays = entry.Weekdays.ToArray() }).ToArray() :
            _draft.Select(item => item.Id == replacingId ? entry with { Id = replacingId, Weekdays = entry.Weekdays.ToArray() } : item).ToArray();
        if (!NasPowerScheduleRules.IsValid(updated)) return false;
        _draft = updated; Changed(); return true;
    }
    public void RemoveEntry(string id) { if (!CanEdit) return; _draft = _draft.Where(entry => entry.Id != id).ToArray(); Changed(); }
    public void SetEntryEnabled(string id, bool enabled)
    { if (!CanEdit) return; _draft = _draft.Select(entry => entry.Id == id ? entry with { IsEnabled = enabled } : entry).ToArray(); Changed(); }
    public void ResetDraft() { if (!CanEdit) return; _draft = Snapshot!.Entries.ToArray(); HasChanges = RiskConfirmed = false; Notify(); }
    public void ConfirmRisk(bool confirmed) { if (_disposed || IsBusy) return; RiskConfirmed = confirmed; Notify(); }
    private void Changed() { HasChanges = Snapshot is not null && !NasPowerScheduleRules.SemanticallyEqual(_draft, Snapshot.Entries); RiskConfirmed = false; Notify(); }
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        Cancel(); _cancellation = new(); var token = _cancellation.Token; var generation = ++_generation; var repository = _repository;
        IsLoading = true; Snapshot = null; _draft = []; ErrorMessage = null; IsUnsupported = false; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try
        {
            var recovery = await NasHardwareEditPresentation.LoadAsync(repository, NasHardwareEditKind.PowerSchedule, token);
            var snapshot = await repository.LoadPowerScheduleAsync(token);
            var availability = await repository.PrepareServiceSettingsAsync(token);
            if (Current()) { Snapshot = snapshot; _draft = snapshot.Entries.ToArray(); Recovery = recovery; _canWrite = availability.CanSavePowerSchedule; HasChanges = RiskConfirmed = false; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (DsmException error) when (error.Code == 102) { if (Current()) IsUnsupported = true; }
        catch { if (Current()) ErrorMessage = LocalizationService.Current.Get("NasPowerScheduleLoadFailed"); }
        finally { if (Current()) { IsLoading = false; Notify(); } }
    }
    public async Task SaveAsync()
    {
        if (!CanSave || _repository is null) return;
        var repository = _repository; var generation = _generation; var token = _cancellation?.Token ?? CancellationToken.None;
        var request = new NasPowerScheduleSaveRequest(repository.ProfileId, Guid.NewGuid(), Snapshot!, _draft.ToArray(), RiskConfirmed);
        IsSaving = true; ErrorMessage = null; Notify();
        bool Current() => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
        try
        {
            var result = await repository.SavePowerScheduleAsync(request, token);
            if (!Current()) return; Recovery = result; RiskConfirmed = false;
            var actual = await repository.LoadPowerScheduleAsync(token);
            if (Current()) { Snapshot = actual; _draft = actual.Entries.ToArray(); HasChanges = false; }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { if (Current()) ErrorMessage = LocalizationService.Current.Get(NasHardwareEditPresentation.Error(error)); }
        finally { if (Current()) { IsSaving = false; Notify(); } }
    }
    public void SetFilter(NasPowerScheduleFilter filter)
    { if (_disposed || !Enum.IsDefined(filter) || filter == Filter) return; Filter = filter; Notify(); }
    public void Deactivate()
    { Cancel(); _repository = null; Snapshot = null; _draft = []; Recovery = null; _canWrite = HasChanges = RiskConfirmed = IsSaving = IsLoading = IsUnsupported = false; Filter = NasPowerScheduleFilter.All; ErrorMessage = null; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Cancel() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
}
