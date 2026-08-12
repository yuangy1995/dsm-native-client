using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasDdnsViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private bool _disposed;

    private bool _isLoading;
    private bool _isEditing;
    private bool _isSaving;
    private bool _isTesting;
    private NasDDNSDraft _draft = new();
    private string? _errorMessage;
    private string? _testResult;
    private MutationResult? _lastResult;

    public ObservableCollection<NasDDNSProvider> Providers { get; } = [];
    public ObservableCollection<NasDDNSRecord> Records { get; } = [];

    public bool IsLoading
    {
        get => _isLoading;
        private set => SetProperty(ref _isLoading, value);
    }

    public bool IsEditing
    {
        get => _isEditing;
        private set => SetProperty(ref _isEditing, value);
    }

    public bool IsSaving
    {
        get => _isSaving;
        private set => SetProperty(ref _isSaving, value);
    }

    public bool IsTesting
    {
        get => _isTesting;
        private set => SetProperty(ref _isTesting, value);
    }

    public NasDDNSDraft Draft
    {
        get => _draft;
        private set => SetProperty(ref _draft, value);
    }

    public string? ErrorMessage
    {
        get => _errorMessage;
        private set => SetProperty(ref _errorMessage, value);
    }

    public string? TestResult
    {
        get => _testResult;
        private set => SetProperty(ref _testResult, value);
    }

    public MutationResult? LastResult
    {
        get => _lastResult;
        private set
        {
            if (SetProperty(ref _lastResult, value))
            {
                RaisePropertyChanged(nameof(WasSuccessful));
            }
        }
    }

    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public bool CanSave => _repository?.WriteAvailability.CanSaveDDNS == true &&
                           Draft.IsValidForSubmission && !IsSaving;
    public bool IsUnsupported => _repository?.WriteAvailability.CanSaveDDNS != true;

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        CancelRequest();
        _repository = repository;

        if (!repository.WriteAvailability.CanSaveDDNS)
        {
            return;
        }

        await LoadAllAsync();
    }

    public async Task RefreshAsync()
    {
        ThrowIfDisposed();
        if (_repository is null)
        {
            return;
        }
        await LoadAllAsync();
    }

    private async Task LoadAllAsync()
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var providers = await repository.LoadDDNSProvidersAsync(
                request.Cancellation.Token);
            var records = await repository.LoadDDNSRecordsAsync(
                request.Cancellation.Token);

            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            Providers.Clear();
            foreach (var provider in providers)
            {
                Providers.Add(provider);
            }

            Records.Clear();
            foreach (var record in records)
            {
                Records.Add(record);
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                ErrorMessage = L.Get("NasSettingsLoadError");
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoading = false;
            }
        }
    }

    public void BeginCreate()
    {
        Draft = new NasDDNSDraft { IsEnabled = true };
        IsEditing = true;
        ErrorMessage = null;
        LastResult = null;
    }

    public void BeginEdit(NasDDNSRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        Draft = new NasDDNSDraft
        {
            ProviderId = record.ProviderId,
            Hostname = record.Hostname,
            Username = record.Username,
            ExternalIp = record.ExternalIp,
            IsEnabled = record.IsEnabled,
            Heartbeat = record.Heartbeat,
        };
        IsEditing = true;
        ErrorMessage = null;
        LastResult = null;
    }

    public void CancelEdit()
    {
        Draft = new NasDDNSDraft();
        IsEditing = false;
        ErrorMessage = null;
    }

    public async Task SaveAsync(string? existingRecordId = null)
    {
        ThrowIfDisposed();
        if (IsSaving)
        {
            return;
        }
        var repository = RequireRepository();
        if (!Draft.IsValidForSubmission)
        {
            ErrorMessage = L.Get("NasSettingsDdnsValidationError");
            return;
        }

        var request = BeginRequest();
        IsSaving = true;
        ErrorMessage = null;
        LastResult = null;

        try
        {
            var result = await repository.SaveDDNSRecordAsync(
                Draft, existingRecordId, request.Cancellation.Token);

            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            LastResult = result;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                IsEditing = false;
                Draft = new NasDDNSDraft();
                await LoadAllAsync();
            }
            else
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
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsSaving = false;
            }
        }
    }

    public async Task DeleteAsync(string recordId)
    {
        ThrowIfDisposed();
        if (IsSaving)
        {
            return;
        }
        var repository = RequireRepository();
        var request = BeginRequest();
        IsSaving = true;
        ErrorMessage = null;
        LastResult = null;

        try
        {
            var result = await repository.DeleteDDNSRecordAsync(
                recordId, request.Cancellation.Token);

            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            LastResult = result;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                await LoadAllAsync();
            }
            else
            {
                ErrorMessage = L.Get("NasSettingsDeleteError");
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                ErrorMessage = L.Get("NasSettingsDeleteError");
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsSaving = false;
            }
        }
    }

    public async Task TestAsync(string recordId)
    {
        ThrowIfDisposed();
        if (IsTesting)
        {
            return;
        }
        var repository = RequireRepository();
        var request = BeginRequest();
        IsTesting = true;
        TestResult = null;
        ErrorMessage = null;

        try
        {
            var result = await repository.TestDDNSRecordAsync(
                recordId, request.Cancellation.Token);

            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }

            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                TestResult = L.Get("NasSettingsDdnsTestSuccess");
            }
            else
            {
                TestResult = L.Get("NasSettingsDdnsTestFailed");
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                TestResult = L.Get("NasSettingsDdnsTestFailed");
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsTesting = false;
            }
        }
    }

    public void Deactivate()
    {
        CancelRequest();
        _repository = null;
        Providers.Clear();
        Records.Clear();
        Draft = new NasDDNSDraft();
        IsEditing = false;
        IsLoading = false;
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
        _repository ?? throw new InvalidOperationException("DDNS editor is inactive.");

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);

    private static LocalizationService L => LocalizationService.Current;

    private sealed record RequestState(
        long Generation,
        CancellationTokenSource Cancellation);
}
