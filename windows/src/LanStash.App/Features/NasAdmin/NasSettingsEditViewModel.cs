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
    NeedsReview,
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
    private bool _requiresReview;

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
                RaisePropertyChanged(nameof(CanSave));
            }
        }
    }

    public T? Draft
    {
        get => _draft;
        set
        {
            if (IsSaving || _requiresReview) return;
            if (SetProperty(ref _draft, value))
            {
                RaisePropertyChanged(nameof(CanSave));
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

    public bool CanSave => Draft is not null && !_requiresReview &&
        State == NasSettingsEditState.Editing && CanSaveFeature();

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
    public bool HasError => State is NasSettingsEditState.Failed or NasSettingsEditState.NeedsReview;
    public bool IsUnsupported => State == NasSettingsEditState.Unsupported;
    public bool CanEdit => !_requiresReview &&
        State is NasSettingsEditState.Idle or NasSettingsEditState.Saved or NasSettingsEditState.Failed;
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public bool WasFailure => LastResult?.Status == MutationResultStatus.ConfirmedFailure;

    private Func<CancellationToken, Task<T>>? _loader;
    private Func<T, CancellationToken, Task<MutationResult>>? _saver;
    private Func<T, T, Guid, CancellationToken, Task<MutationResult>>? _snapshotSaver;

    public Task ActivateAsync(INasSettingsRepository repository, string editTitle, Func<CancellationToken, Task<T>> loader,
        Func<T, T, Guid, CancellationToken, Task<MutationResult>> snapshotSaver) =>
        ActivateAsync(repository, editTitle, loader, null, snapshotSaver);

    public async Task ActivateAsync(
        INasSettingsRepository repository,
        string editTitle,
        Func<CancellationToken, Task<T>> loader,
        Func<T, CancellationToken, Task<MutationResult>>? saver,
        Func<T, T, Guid, CancellationToken, Task<MutationResult>>? snapshotSaver = null)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(loader);
        if (saver is null && snapshotSaver is null) throw new ArgumentNullException(nameof(saver));

        CancelRequest();
        _requiresReview = false;
        _loaded = null;
        _draft = null;
        LastResult = null;
        _repository = repository;
        _loader = loader;
        _saver = saver;
        _snapshotSaver = snapshotSaver;
        EditTitle = editTitle;

        State = NasSettingsEditState.Idle;
        await LoadAsync();
    }

    public async Task LoadAsync()
    {
        ThrowIfDisposed();
        if (IsSaving) return;
        var repository = RequireRepository();
        var loader = RequireLoader();
        var request = BeginRequest();
        State = NasSettingsEditState.Loading;
        ErrorMessage = null;
        _loaded = null;
        _draft = null;
        RaisePropertyChanged(nameof(Draft));
        RaisePropertyChanged(nameof(CanSave));

        try
        {
            var data = await loader(request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            _loaded = data;
            _requiresReview = false;
            LastResult = null;
            Draft = Clone(data);
            State = NasSettingsEditState.Editing;
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch (DsmException error) when (error.Code == 102)
        {
            if (IsCurrent(request.Generation, repository))
            {
                ErrorMessage = L.Get("NasSettingsUnavailable");
                State = NasSettingsEditState.Unsupported;
            }
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
        var draft = Draft;

        if (draft is null || !CanSave)
        {
            return;
        }

        var request = BeginRequest();
        State = NasSettingsEditState.Saving;
        _requiresReview = true;
        ErrorMessage = null;
        LastResult = null;

        try
        {
            // 保存期间禁止重新读取和编辑；这一份原值/目标值及请求 ID 在整个提交内固定。
            var result = _snapshotSaver is { } snapshotSaver && _loaded is { } baseline
                ? await snapshotSaver(baseline, draft, Guid.NewGuid(), request.Cancellation.Token)
                : await RequireSaver()(draft, request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            LastResult = result;
            _requiresReview = result.Status != MutationResultStatus.ConfirmedSuccess &&
                (result.RequiresRefresh || result.Status is MutationResultStatus.SubmittedButUnverified or
                    MutationResultStatus.CancellationRequestedAfterSubmission or MutationResultStatus.PartialSuccess);
            State = result.Status switch
            {
                MutationResultStatus.ConfirmedSuccess => NasSettingsEditState.Saved,
                _ when _requiresReview => NasSettingsEditState.NeedsReview,
                MutationResultStatus.Unsupported => NasSettingsEditState.Unsupported,
                MutationResultStatus.CancelledBeforeSubmission => NasSettingsEditState.Editing,
                MutationResultStatus.ConfirmedFailure => NasSettingsEditState.Failed,
                _ => NasSettingsEditState.Failed,
            };

            if (State == NasSettingsEditState.Saved) _loaded = Clone(draft);
            if (State == NasSettingsEditState.Unsupported)
            {
                ErrorMessage = L.Get("NasSettingsUnavailable");
            }
            else if (State == NasSettingsEditState.NeedsReview)
            {
                ErrorMessage = L.Get(result.Submitted ? "NasSettingsSaveNeedsReview" : "NasSettingsNotSavedNeedsReload");
            }
            else if (State == NasSettingsEditState.Failed)
            {
                ErrorMessage = L.Get(result.ErrorCategory switch
                {
                    MutationErrorCategory.Permission => "NasSettingsSavePermissionDenied",
                    MutationErrorCategory.Authentication => "NasSettingsSaveSignInRequired",
                    _ => "NasSettingsSaveError",
                });
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
            if (IsCurrent(request.Generation, repository)) MarkNeedsReview();
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                MarkNeedsReview();
            }
        }
    }

    public void BeginEdit()
    {
        ThrowIfDisposed();
        if (!CanEdit) return;
        if (_loaded is not null)
        {
            Draft = Clone(_loaded);
            State = NasSettingsEditState.Editing;
            LastResult = null;
        }
    }

    public void CancelEdit()
    {
        ThrowIfDisposed();
        if (IsSaving || _requiresReview) return;
        CancelRequest();
        Draft = _loaded is not null ? Clone(_loaded) : null;
        State = NasSettingsEditState.Idle;
        LastResult = null;
    }

    public void SetUnsupported()
    {
        if (IsSaving || _requiresReview) return;
        State = NasSettingsEditState.Unsupported;
    }

    public void Deactivate()
    {
        CancelRequest();
        _repository = null;
        _loader = null;
        _saver = null;
        _snapshotSaver = null;
        _loaded = default;
        _requiresReview = false;
        State = NasSettingsEditState.Idle;
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
                hs.HddSleepMinutes, hs.UpsEnabled, hs.UpsMode, hs.UpsShutdownTime)
            {
                LedMinimum = hs.LedMinimum, LedMaximum = hs.LedMaximum, Beep = hs.Beep, Hibernation = hs.Hibernation,
                Ups = hs.Ups, AvailableSections = hs.AvailableSections, FailedSections = hs.FailedSections,
            };
        }

        if (source is NasSecuritySettings ss)
        {
            return (T)(object)new NasSecuritySettings(
                ss.AutoBlockEnabled, ss.AutoBlockFailedAttempts,
                ss.AutoBlockWithinMinutes, ss.AutoBlockExpiryDays,
                ss.DosProtectionEnabled, ss.FirewallEnabled, ss.PortScanEnabled)
            {
                DosProtection = Array.AsReadOnly(ss.DosProtection.ToArray()), FirewallProfileName = ss.FirewallProfileName,
                AvailableSections = ss.AvailableSections, FailedSections = ss.FailedSections,
            };
        }

        if (source is NasRegionSettings rs)
        {
            return (T)(object)new NasRegionSettings(
                rs.DateFormat, rs.TimeFormat, rs.Timezone,
                Array.AsReadOnly(rs.NtpServers.ToArray()), rs.ManualDate)
            {
                Mode = rs.Mode, NasLocalTime = rs.NasLocalTime,
                TimeZones = Array.AsReadOnly(rs.TimeZones.ToArray()),
            };
        }

        return source;
    }

    private bool CanSaveFeature()
    {
        if (_repository is null) return false;
        var available = _repository.WriteAvailability;
        return Draft switch
        {
            NasFileServiceSettings => available.CanSaveFileService,
            NasTerminalSettings => available.CanSaveTerminal,
            NasProxySettings => available.CanSaveProxy,
            NasHardwareSettings => available.CanSaveHardware,
            NasSecuritySettings => available.CanSaveSecurity,
            NasRegionSettings => available.CanSaveRegion,
            NasEthernetInterface => available.CanSaveNetwork,
            NasRemoteAccessSettings => available.CanSaveRemoteAccess,
            _ => false,
        };
    }

    private void MarkNeedsReview()
    {
        // 提交开始后的异常无法证明未生效，只允许先重新读取，不能再次保存旧草稿。
        _requiresReview = true;
        ErrorMessage = L.Get("NasSettingsSaveNeedsReview");
        State = NasSettingsEditState.NeedsReview;
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
