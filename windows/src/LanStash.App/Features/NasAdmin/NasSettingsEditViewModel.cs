using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public enum NasSettingsEditState
{
    Idle,
    Loading,
    Editing,
    Saving,
    Saved,
    Failed,
    Unsupported,
}

public sealed class NasSettingsEditViewModel<T> : ObservableObject, IDisposable
    where T : class
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private bool _disposed;

    private NasSettingsEditState _state = NasSettingsEditState.Idle;
    private T? _loaded;
    private T? _draft;
    private MutationResult? _lastResult;
    private string? _errorMessage;
    private string _editTitle = string.Empty;
    private bool _canSave;

    public NasSettingsEditState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaisePropertyChanged(nameof(IsLoading));
                RaisePropertyChanged(nameof(IsEditing));
                RaisePropertyChanged(nameof(IsSaving));
                RaisePropertyChanged(nameof(HasError));
                RaisePropertyChanged(nameof(IsUnsupported));
                RaisePropertyChanged(nameof(CanEdit));
            }
        }
    }

    public T? Draft
    {
        get => _draft;
        set
        {
            if (SetProperty(ref _draft, value))
            {
                CanSave = value is not null;
            }
        }
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set => SetProperty(ref _errorMessage, value);
    }

    public string EditTitle
    {
        get => _editTitle;
        set => SetProperty(ref _editTitle, value);
    }

    public bool CanSave
    {
        get => _canSave;
        private set => SetProperty(ref _canSave, value);
    }

    public MutationResult? LastResult
    {
        get => _lastResult;
        private set
        {
            if (SetProperty(ref _lastResult, value))
            {
                RaisePropertyChanged(nameof(WasSuccessful));
                RaisePropertyChanged(nameof(WasFailure));
            }
        }
    }

    public bool IsLoading => State == NasSettingsEditState.Loading;
    public bool IsEditing => State == NasSettingsEditState.Editing;
    public bool IsSaving => State == NasSettingsEditState.Saving;
    public bool HasError => State == NasSettingsEditState.Failed;
    public bool IsUnsupported => State == NasSettingsEditState.Unsupported;
    public bool CanEdit => State == NasSettingsEditState.Idle || State == NasSettingsEditState.Saved;
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public bool WasFailure => LastResult?.Status == MutationResultStatus.ConfirmedFailure;

    private Func<CancellationToken, Task<T>>? _loader;
    private Func<T, CancellationToken, Task<MutationResult>>? _saver;

    public async Task ActivateAsync(
        INasSettingsRepository repository,
        string editTitle,
        Func<CancellationToken, Task<T>> loader,
        Func<T, CancellationToken, Task<MutationResult>> saver)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(loader);
        ArgumentNullException.ThrowIfNull(saver);

        CancelRequest();
        _repository = repository;
        _loader = loader;
        _saver = saver;
        EditTitle = editTitle;

        await LoadAsync();
    }

    public async Task LoadAsync()
    {
        ThrowIfDisposed();
        var repository = RequireRepository();
        var loader = RequireLoader();
        var request = BeginRequest();
        State = NasSettingsEditState.Loading;
        ErrorMessage = null;

        try
        {
            var data = await loader(request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            _loaded = data;
            Draft = Clone(data);
            State = NasSettingsEditState.Editing;
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                ErrorMessage = L.Get("NasSettingsLoadError");
                State = NasSettingsEditState.Failed;
            }
        }
    }

    public async Task SaveAsync()
    {
        ThrowIfDisposed();
        var repository = RequireRepository();
        var saver = RequireSaver();
        var draft = Draft;

        if (draft is null || !repository.WriteAvailability.CanSaveFileService)
        {
            return;
        }

        var request = BeginRequest();
        State = NasSettingsEditState.Saving;
        ErrorMessage = null;
        LastResult = null;

        try
        {
            var result = await saver(draft, request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            LastResult = result;
            State = result.Status switch
            {
                MutationResultStatus.ConfirmedSuccess => NasSettingsEditState.Saved,
                MutationResultStatus.ConfirmedFailure => NasSettingsEditState.Failed,
                MutationResultStatus.SubmittedButUnverified => NasSettingsEditState.Saved,
                _ => NasSettingsEditState.Failed,
            };

            if (State == NasSettingsEditState.Failed)
            {
                ErrorMessage = L.Get("NasSettingsSaveError");
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                ErrorMessage = L.Get("NasSettingsSaveError");
                State = NasSettingsEditState.Failed;
            }
        }
    }

    public void BeginEdit()
    {
        if (_loaded is not null)
        {
            Draft = Clone(_loaded);
            State = NasSettingsEditState.Editing;
            LastResult = null;
        }
    }

    public void CancelEdit()
    {
        Draft = _loaded is not null ? Clone(_loaded) : null;
        State = NasSettingsEditState.Idle;
        LastResult = null;
    }

    public void SetUnsupported()
    {
        State = NasSettingsEditState.Unsupported;
    }

    public void Deactivate()
    {
        CancelRequest();
        _repository = null;
        _loader = null;
        _saver = null;
        _loaded = default;
        Draft = default;
        LastResult = null;
        State = NasSettingsEditState.Idle;
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

    private static T? Clone(T? source)
    {
        if (source is null)
        {
            return null;
        }

        if (source is NasFileServiceSettings fss)
        {
            return (T)(object)fss.CloneWith();
        }

        if (source is NasTerminalSettings ts)
        {
            return (T)(object)new NasTerminalSettings(
                ts.SshEnabled, ts.SshPort, ts.TelnetEnabled, ts.TelnetPort);
        }

        if (source is NasProxySettings ps)
        {
            return (T)(object)new NasProxySettings(ps.Enabled, ps.Host, ps.Port);
        }

        if (source is NasHardwareSettings hs)
        {
            return (T)(object)new NasHardwareSettings(
                hs.PowerFailRestart, hs.LedBrightness, hs.FanMode, hs.BeepControl,
                hs.HddSleepMinutes, hs.UpsEnabled, hs.UpsMode, hs.UpsShutdownTime);
        }

        if (source is NasSecuritySettings ss)
        {
            return (T)(object)new NasSecuritySettings(
                ss.AutoBlockEnabled, ss.AutoBlockFailedAttempts,
                ss.AutoBlockWithinMinutes, ss.AutoBlockExpiryDays,
                ss.DosProtectionEnabled, ss.FirewallEnabled, ss.PortScanEnabled);
        }

        if (source is NasRegionSettings rs)
        {
            return (T)(object)new NasRegionSettings(
                rs.DateFormat, rs.TimeFormat, rs.Timezone,
                rs.NtpServers.ToList(), rs.ManualDate);
        }

        return source;
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
        _repository ?? throw new InvalidOperationException("Settings editor is inactive.");

    private Func<CancellationToken, Task<T>> RequireLoader() =>
        _loader ?? throw new InvalidOperationException("No loader registered.");

    private Func<T, CancellationToken, Task<MutationResult>> RequireSaver() =>
        _saver ?? throw new InvalidOperationException("No saver registered.");

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private static LocalizationService L => LocalizationService.Current;

    private sealed record RequestState(
        long Generation,
        CancellationTokenSource Cancellation);
}
