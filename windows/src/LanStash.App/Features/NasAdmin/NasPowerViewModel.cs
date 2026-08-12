using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasPowerViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private bool _disposed;

    private bool _isExecuting;
    private NasPowerAction _action;
    private string? _confirmationMessage;
    private MutationResult? _lastResult;

    public bool IsExecuting
    {
        get => _isExecuting;
        private set => SetProperty(ref _isExecuting, value);
    }

    public string? ConfirmationMessage
    {
        get => _confirmationMessage;
        private set => SetProperty(ref _confirmationMessage, value);
    }

    public MutationResult? LastResult
    {
        get => _lastResult;
        private set => SetProperty(ref _lastResult, value);
    }

    public bool IsUnsupported => _repository?.WriteAvailability.CanPowerAction != true;
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess
        || LastResult?.Status == MutationResultStatus.SubmittedButUnverified;

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        CancelRequest();
        _repository = repository;
        await Task.CompletedTask;
    }

    public void RequestShutdown()
    {
        _action = NasPowerAction.Shutdown;
        ConfirmationMessage = L.Get("NasSettingsShutdownConfirmation");
    }

    public void RequestReboot()
    {
        _action = NasPowerAction.Reboot;
        ConfirmationMessage = L.Get("NasSettingsRebootConfirmation");
    }

    public void CancelAction()
    {
        _action = NasPowerAction.Reboot;
        ConfirmationMessage = null;
        LastResult = null;
    }

    public async Task ExecuteActionAsync()
    {
        ThrowIfDisposed();
        if (IsExecuting)
        {
            return;
        }
        var repository = RequireRepository();
        var request = BeginRequest();
        IsExecuting = true;
        LastResult = null;

        try
        {
            var result = await repository.ExecutePowerActionAsync(
                _action, request.Cancellation.Token);

            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            LastResult = result;
            if (result.Status == MutationResultStatus.SubmittedButUnverified)
            {
                ConfirmationMessage = L.Get(_action == NasPowerAction.Shutdown
                    ? "NasSettingsShutdownSubmitted"
                    : "NasSettingsRebootSubmitted");
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                LastResult = new MutationResult(1, MutationResultStatus.ConfirmedFailure,
                    "powerAction", submitted: true, requiresRefresh: false,
                    new MutationResultCounts(0, 1, 0),
                    MutationErrorCategory.Server);
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsExecuting = false;
            }
        }
    }

    public void Deactivate()
    {
        CancelRequest();
        _repository = null;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        CancelRequest();
    }

    private RequestState BeginRequest()
    {
        CancelRequest();
        var cancellation = new CancellationTokenSource();
        _requestCancellation = cancellation;
        return new RequestState(++_generation, cancellation);
    }

    private void CancelRequest()
    {
        _generation++;
        var cancellation = _requestCancellation;
        _requestCancellation = null;
        cancellation?.Cancel();
        cancellation?.Dispose();
    }

    private bool IsCurrent(long generation, INasSettingsRepository repository) =>
        !_disposed &&
        generation == _generation &&
        ReferenceEquals(repository, _repository);

    private INasSettingsRepository RequireRepository() =>
        _repository ?? throw new InvalidOperationException("Power view model is inactive.");

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private static LocalizationService L => LocalizationService.Current;

    private sealed record RequestState(
        long Generation,
        CancellationTokenSource Cancellation);
}
