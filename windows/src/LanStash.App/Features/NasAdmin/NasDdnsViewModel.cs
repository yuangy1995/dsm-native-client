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
    private bool _disposed, _loaded;
    private NasDdnsMutationRequest? _confirmation;
    private string? _confirmedPassword;
    private NasDDNSRecord? _baseline, _target;
    public ObservableCollection<NasDDNSProvider> Providers { get; } = [];
    public ObservableCollection<NasDDNSRecord> Records { get; } = [];
    public bool IsLoading { get; private set; }
    public bool IsEditing { get; private set; }
    public bool IsSaving { get; private set; }
    public bool IsTesting { get; private set; }
    public bool IsBusy => IsLoading || IsSaving || IsTesting;
    public bool NeedsReview { get; private set; }
    public NasDDNSDraft Draft { get; private set; } = new();
    public bool IsExisting => _baseline is not null;
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public NasDdnsAction? SelectedAction { get; private set; }
    public NasDdnsAction? LastAction { get; private set; }
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public bool IsUnsupported => _repository?.WriteAvailability.CanSaveDDNS != true;
    public bool CanEdit => !_disposed && _loaded && !IsBusy && !NeedsReview && !IsUnsupported && ErrorMessage is null;
    public bool CanExecute => CanEdit && ConfirmationStillMatches();
    public bool HasValidAction => BuildRequest(Guid.Empty) is { } request &&
        NasDdnsMutationRules.IsValid(request, Draft.Password) && TargetsStillPresent(request);
    public bool CanSave => SelectedAction == NasDdnsAction.Save && CanExecute;
    public string? TestResult => LastAction == NasDdnsAction.Test ? FeedbackMessage : null;
    public string? FeedbackMessage => LastResult is null ? null : L.Get(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => LastAction switch
        {
            NasDdnsAction.Test => "NasDdnsTestAccepted", NasDdnsAction.Save => "NasDdnsSaved",
            NasDdnsAction.Delete => "NasDdnsDeleted", NasDdnsAction.UpdateAddress => "NasDdnsUpdated", _ => "NasDdnsReviewed",
        },
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasDdnsUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasDdnsNotSubmitted",
        MutationResultStatus.PermissionDenied => "NasDdnsPermission",
        MutationResultStatus.Unsupported => "NasSettingsUnavailable",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "NasDdnsAuthentication", MutationErrorCategory.Permission => "NasDdnsPermission",
            MutationErrorCategory.Conflict => "NasDdnsConflict", MutationErrorCategory.Validation => "NasSettingsDdnsValidationError", _ => "NasDdnsFailed",
        },
    });

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await LoadAllAsync();
    }
    public Task RefreshAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _repository is null || IsBusy ? Task.CompletedTask : LoadAllAsync();
    }
    private async Task LoadAllAsync()
    {
        var repository = _repository!; var request = BeginRequest();
        ResetEditor(); IsLoading = true; ErrorMessage = null; _loaded = false; Providers.Clear(); Records.Clear(); Notify();
        try
        {
            await repository.PrepareServiceSettingsAsync(request.Token);
            if (!IsCurrent(request.Generation, repository)) return;
            var review = await repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.Ddns, request.Token);
            if (!IsCurrent(request.Generation, repository)) return;
            NeedsReview = review is not null && (review.Counts.Unknown > 0 || review.ErrorCategory == MutationErrorCategory.Conflict ||
                review.Status == MutationResultStatus.CancelledBeforeSubmission);
            if (review is not null) { LastResult = review; LastAction = null; }
            await LoadDirectoryAsync(repository, request);
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch { if (IsCurrent(request.Generation, repository)) ErrorMessage = L.Get("NasSettingsLoadError"); }
        finally { if (IsCurrent(request.Generation, repository)) { IsLoading = false; Notify(); } }
    }
    private async Task LoadDirectoryAsync(INasSettingsRepository repository, RequestState request)
    {
        var providers = await repository.LoadDDNSProvidersAsync(request.Token);
        if (!IsCurrent(request.Generation, repository)) return;
        var records = await repository.LoadDDNSRecordsAsync(request.Token);
        if (!IsCurrent(request.Generation, repository)) return;
        Providers.Clear(); foreach (var item in providers) Providers.Add(item);
        Records.Clear(); foreach (var item in records) Records.Add(item);
        _loaded = true;
    }
    public void BeginCreate()
    {
        if (IsBusy || NeedsReview || _disposed) return;
        ResetEditor(); IsEditing = true; SelectedAction = NasDdnsAction.Save; ErrorMessage = null; Notify();
    }
    public void BeginEdit(NasDDNSRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        if (IsBusy || NeedsReview || _disposed) return;
        ResetEditor(); _baseline = record;
        Draft = new() { ProviderId = record.ProviderId, Hostname = record.Hostname, Username = record.Username,
            ExternalIp = record.ExternalIp, IsEnabled = record.IsEnabled, Heartbeat = record.Heartbeat };
        IsEditing = true; SelectedAction = NasDdnsAction.Save; ErrorMessage = null; Notify();
    }
    public void CancelEdit() { if (IsBusy) return; ResetEditor(); ErrorMessage = null; Notify(); }
    public void SelectAction(NasDdnsAction action, NasDDNSRecord? target = null)
    {
        if (IsBusy || NeedsReview || _disposed) return;
        InvalidateConfirmation(); SelectedAction = action; _target = target; Notify();
    }
    public void InvalidateConfirmation() { _confirmation = null; _confirmedPassword = null; }
    public void DraftChanged()
    {
        if (IsBusy || _disposed) return;
        InvalidateConfirmation(); ErrorMessage = null;
        if (LastAction == NasDdnsAction.Test) { LastResult = null; LastAction = null; }
        Notify();
    }
    public bool ConfirmAction()
    {
        InvalidateConfirmation(); var candidate = BuildRequest(Guid.NewGuid());
        if (!CanEdit || candidate is null || !NasDdnsMutationRules.IsValid(candidate, Draft.Password) || !TargetsStillPresent(candidate))
        { Notify(); return false; }
        _confirmation = candidate;
        _confirmedPassword = candidate.Action is NasDdnsAction.Save or NasDdnsAction.Test ? Draft.Password : null;
        Notify(); return true;
    }
    private NasDdnsMutationRequest? BuildRequest(Guid id)
    {
        if (_repository is null || SelectedAction is null) return null;
        var action = SelectedAction.Value;
        var desired = action is NasDdnsAction.Save or NasDdnsAction.Test && IsEditing
            ? (_baseline ?? new NasDDNSRecord(Draft.ProviderId?.Trim() ?? "", Draft.ProviderId?.Trim() ?? "", "", "", "0.0.0.0", null, true)
                { NetworkType = "auto", Ipv6 = "0:0:0:0:0:0:0:0", InterfaceV4 = "", InterfaceV6 = "" }) with
                { Id = Draft.ProviderId?.Trim() ?? "", ProviderId = Draft.ProviderId?.Trim() ?? "", Hostname = Draft.Hostname?.Trim().ToLowerInvariant() ?? "",
                    Username = Draft.Username?.Trim() ?? "", IsEnabled = Draft.IsEnabled, Heartbeat = Draft.Heartbeat }
            : null;
        return new(_repository.ProfileId, action, action == NasDdnsAction.Delete ? _target : action == NasDdnsAction.UpdateAddress ? null : _baseline,
            desired, action == NasDdnsAction.UpdateAddress ? Records.Select(r => r.ProviderId).Order(StringComparer.Ordinal).ToArray() : [], id, true);
    }
    private bool TargetsStillPresent(NasDdnsMutationRequest request)
    {
        if (request.Action == NasDdnsAction.UpdateAddress) return Records.Count > 0;
        if (request.Baseline is { } baseline && !Records.Contains(baseline)) return false;
        return request.Desired is not { } desired || Providers.Any(p => p.Id == desired.ProviderId) &&
            (request.Baseline is not null || !Records.Any(r => r.ProviderId == desired.ProviderId));
    }
    private bool ConfirmationStillMatches()
    {
        if (_confirmation is not { } confirmed || BuildRequest(confirmed.RequestId) is not { } current) return false;
        return current.ProfileId == confirmed.ProfileId && current.Action == confirmed.Action && current.Baseline == confirmed.Baseline &&
            current.Desired == confirmed.Desired && current.ExpectedProviderIds.SequenceEqual(confirmed.ExpectedProviderIds) &&
            (current.Action is not (NasDdnsAction.Save or NasDdnsAction.Test) || Draft.Password == _confirmedPassword) && TargetsStillPresent(current);
    }
    public Task SaveAsync(string? existingRecordId = null) => existingRecordId is null || existingRecordId == _baseline?.Id
        ? ExecuteForActionAsync(NasDdnsAction.Save) : Task.CompletedTask;
    public Task DeleteAsync(string recordId) => _confirmation?.Baseline?.Id == recordId ? ExecuteForActionAsync(NasDdnsAction.Delete) : Task.CompletedTask;
    public Task TestAsync(string recordId) => _confirmation?.Desired?.ProviderId == recordId ? ExecuteForActionAsync(NasDdnsAction.Test) : Task.CompletedTask;
    private Task ExecuteForActionAsync(NasDdnsAction action)
    {
        if (SelectedAction == action && CanExecute) return ExecuteConfirmedAsync();
        if (!IsBusy) { ErrorMessage = L.Get("NasDdnsConfirmAgain"); Notify(); }
        return Task.CompletedTask;
    }
    public async Task ExecuteConfirmedAsync()
    {
        if (!CanExecute || _repository is null || _confirmation is null) return;
        var repository = _repository; var confirmation = _confirmation; var password = _confirmedPassword;
        var request = BeginRequest(); LastAction = confirmation.Action; LastResult = null; ErrorMessage = null;
        IsTesting = confirmation.Action == NasDdnsAction.Test; IsSaving = !IsTesting;
        Draft.Password = null; InvalidateConfirmation(); Notify();
        try
        {
            var pending = repository.MutateDdnsAsync(confirmation, password, request.Token); password = null;
            var result = await pending;
            if (!IsCurrent(request.Generation, repository)) return;
            LastResult = result; NeedsReview = result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict;
            if (result.Status == MutationResultStatus.ConfirmedSuccess && confirmation.Action != NasDdnsAction.Test)
            {
                ResetEditor();
                try { await LoadDirectoryAsync(repository, request); }
                catch { if (IsCurrent(request.Generation, repository)) { _loaded = false; ErrorMessage = L.Get("NasSettingsLoadError"); } }
            }
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "ddnsMutation", true, true, new(0, 0, 1)); NeedsReview = true;
            }
        }
        finally { password = null; if (IsCurrent(request.Generation, repository)) { IsSaving = false; IsTesting = false; Notify(); } }
    }
    private void ResetEditor()
    {
        Draft.Password = null; Draft = new(); _baseline = null; _target = null; IsEditing = false;
        SelectedAction = null; InvalidateConfirmation();
    }
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _loaded = false; ResetEditor(); Providers.Clear(); Records.Clear();
        IsLoading = false; IsSaving = false; IsTesting = false; NeedsReview = false; ErrorMessage = null;
        LastResult = null; LastAction = null; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private RequestState BeginRequest()
    {
        CancelRequest(); _requestCancellation = new(); return new(++_generation, _requestCancellation.Token);
    }
    private void CancelRequest()
    {
        _generation++; var cancellation = _requestCancellation; _requestCancellation = null; cancellation?.Cancel(); cancellation?.Dispose();
    }
    private bool IsCurrent(long generation, INasSettingsRepository repository) => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
