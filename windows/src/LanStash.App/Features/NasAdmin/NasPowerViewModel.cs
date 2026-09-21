using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasPowerViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _ready, _reviewed;
    private NasPowerRequest? _confirmation;
    public NasPowerAction? Action { get; private set; }
    public bool IsExecuting { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsBusy => IsExecuting || IsLoading;
    public MutationResult? LastResult { get; private set; }
    public NasPowerRecoveryInfo? Recovery { get; private set; }
    public string? ErrorMessage { get; private set; }
    public bool IsUnsupported => _repository?.WriteAvailability.CanPowerAction != true;
    public bool CanChoose => !_disposed && _ready && !IsBusy && !IsUnsupported && Recovery is null;
    public bool CanExecute => CanChoose && _confirmation is not null && Action == _confirmation.Action;
    public bool CanAcknowledge => !_disposed && !IsBusy && Recovery?.HasFreshSession == true;
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public string? ConfirmationMessage => Action is null ? null : L.Get(Action == NasPowerAction.Shutdown ? "NasSettingsShutdownConfirmation" : "NasSettingsRebootConfirmation");
    public string? Feedback
    {
        get
        {
            if (_reviewed) return L.Get("NasPowerReviewed");
            var result = Recovery?.Result ?? LastResult;
            if (result is null) return null;
            return L.Get(result.Status switch
            {
                MutationResultStatus.ConfirmedSuccess => "NasPowerAccepted",
                MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasPowerUnknown",
                MutationResultStatus.CancelledBeforeSubmission => "NasPowerNotSent",
                MutationResultStatus.Unsupported => "NasSettingsUnavailable",
                MutationResultStatus.PermissionDenied => "NasPowerPermission",
                _ => result.ErrorCategory switch
                {
                    MutationErrorCategory.Authentication => "NasPowerAuthentication", MutationErrorCategory.Permission => "NasPowerPermission",
                    MutationErrorCategory.Conflict => "NasPowerConflict", _ => "NasPowerFailed",
                },
            });
        }
    }
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || _repository is null || IsBusy) return;
        var repository = _repository; var request = BeginRequest();
        Action = null; _confirmation = null; IsLoading = true; _ready = false; ErrorMessage = null; Notify();
        try
        {
            await repository.PrepareServiceSettingsAsync(request.Token);
            if (!Current(request, repository)) return;
            var recovery = await repository.GetPowerRecoveryAsync(request.Token);
            if (!Current(request, repository)) return;
            Recovery = recovery; if (recovery is not null) LastResult = recovery.Result;
            _ready = true;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasPowerLoadFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void RequestShutdown() => Choose(NasPowerAction.Shutdown);
    public void RequestReboot() => Choose(NasPowerAction.Reboot);
    private void Choose(NasPowerAction action)
    {
        if (!CanChoose) return;
        Action = action; _confirmation = null; _reviewed = false; Notify();
    }
    public void CancelAction()
    {
        if (IsBusy) return;
        Action = null; _confirmation = null; Notify();
    }
    public bool ConfirmAction(bool confirmed)
    {
        _confirmation = confirmed && CanChoose && Action is { } action ? new(_repository!.ProfileId, action, Guid.NewGuid(), true) : null;
        Notify(); return CanExecute;
    }
    public async Task ExecuteActionAsync()
    {
        if (!CanExecute || _repository is null || _confirmation is null) return;
        var repository = _repository; var confirmation = _confirmation; var request = BeginRequest();
        _confirmation = null; IsExecuting = true; LastResult = null; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.ExecutePowerActionAsync(confirmation, request.Token);
            if (!Current(request, repository)) return;
            LastResult = result;
            var recovery = await repository.GetPowerRecoveryAsync(request.Token);
            if (!Current(request, repository)) return;
            Recovery = recovery;
            if (Recovery is null && result.Submitted && result.Status is MutationResultStatus.ConfirmedSuccess or MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission)
                Recovery = new(confirmation.Action, result, false);
        }
        catch
        {
            if (Current(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "powerAction", true, true, new(0, 0, 1));
                Recovery = new(confirmation.Action, LastResult, false);
            }
        }
        finally { if (Current(request, repository)) { IsExecuting = false; Notify(); } }
    }
    public async Task AcknowledgeAsync(bool deviceChecked)
    {
        if (!deviceChecked || !CanAcknowledge || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); IsLoading = true; ErrorMessage = null; Notify();
        try
        {
            var cleared = await repository.AcknowledgePowerRecoveryAsync(true, request.Token);
            if (!Current(request, repository)) return;
            if (cleared) { Recovery = null; LastResult = null; Action = null; _confirmation = null; _reviewed = true; }
            else ErrorMessage = L.Get("NasPowerReviewFailed");
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasPowerReviewFailed"); }
        finally { if (Current(request, repository)) { IsLoading = false; Notify(); } }
    }
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _ready = false; _reviewed = false; Action = null; _confirmation = null;
        LastResult = null; Recovery = null; ErrorMessage = null; IsExecuting = false; IsLoading = false; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private RequestState BeginRequest() { CancelRequest(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void CancelRequest() { _generation++; var old = _cancellation; _cancellation = null; old?.Cancel(); old?.Dispose(); }
    private bool Current(RequestState request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
