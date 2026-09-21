using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasConnectionManagementViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _loaded, _recoveryReady, _refreshRequired;
    private NasConnectionDisconnectRequest? _confirmation;
    public ObservableCollection<NasConnectionEntry> Connections { get; } = [];
    public ObservableCollection<NasConnectionRecoveryInfo> Pending { get; } = [];
    public NasConnectionEntry? Selected { get; private set; }
    public string SearchText { get; private set; } = "";
    public bool IsBusy { get; private set; }
    public bool IsComplete { get; private set; }
    public bool IsReadOnly => _repository?.WriteAvailability.CanConnectionDisconnect != true;
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public string LastTarget { get; private set; } = "";
    public int ConfirmationVersion { get; private set; }
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public IReadOnlyList<NasConnectionEntry> VisibleConnections => Connections.Where(item =>
        (item.Account ?? "").Contains(SearchText, StringComparison.CurrentCultureIgnoreCase) ||
        (item.Source ?? "").Contains(SearchText, StringComparison.OrdinalIgnoreCase) ||
        (item.Protocol ?? item.Type ?? "").Contains(SearchText, StringComparison.CurrentCultureIgnoreCase) ||
        (item.Description ?? "").Contains(SearchText, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    public bool CanChoose => !_disposed && _loaded && _recoveryReady && !_refreshRequired && !IsBusy && !IsReadOnly && IsComplete &&
        Selected is { CanDisconnect: true } item && item.TargetKey.Length > 0 && !Pending.Any(p => p.TargetKey == item.TargetKey || item.IdentityKeys.Contains(p.TargetKey));
    public bool CanExecute => CanChoose && _confirmation is not null && ReferenceEquals(_confirmation.Baseline, Selected);
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => "NasConnectionsDisconnected",
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasConnectionsUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasConnectionsNotSent",
        MutationResultStatus.PermissionDenied => "NasConnectionsPermission",
        MutationResultStatus.Unsupported => "NasConnectionsUnsupported",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "NasConnectionsAuthentication", MutationErrorCategory.Permission => "NasConnectionsPermission",
            MutationErrorCategory.Conflict => "NasConnectionsConflict", _ => "NasConnectionsFailed",
        },
    }, LastTarget);
    public static string Describe(string? account, string? source, string? protocol) =>
        L.Format("NasConnectionsTarget", account ?? L.Get("UnknownValue"), source ?? L.Get("UnknownValue"), protocol ?? L.Get("UnknownValue"));
    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await ReloadAsync();
    }
    public async Task ReloadAsync()
    {
        if (_disposed || IsBusy || _repository is null) return;
        var repository = _repository; var request = BeginRequest(); var selectedKey = Selected?.TargetKey;
        ResetConfirmation(); Selected = null; Connections.Clear(); IsBusy = true; _loaded = false; _recoveryReady = false; ErrorMessage = null; Notify();
        try
        {
            try
            {
                await repository.PrepareServiceSettingsAsync(request.Token);
                if (!Current(request, repository)) return;
                var recoveries = await repository.GetConnectionRecoveriesAsync(request.Token);
                if (!Current(request, repository)) return;
                var pending = new List<NasConnectionRecoveryInfo>();
                foreach (var item in recoveries)
                {
                    var result = await repository.ReviewConnectionAsync(item.TargetKey, request.Token);
                    if (!Current(request, repository)) return;
                    if (result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict || result.Status == MutationResultStatus.CancelledBeforeSubmission) pending.Add(item);
                    if (result is not null) { LastResult = result; LastTarget = Describe(item.Account, item.Source, item.Protocol); }
                }
                Pending.Clear(); foreach (var item in pending) Pending.Add(item); _recoveryReady = true;
            }
            catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { return; }
            catch { if (Current(request, repository)) ErrorMessage = L.Get("NasConnectionsRecoveryFailed"); }
            if (!Current(request, repository)) return;
            await ReadSnapshotAsync(repository, request, selectedKey);
            if (Current(request, repository)) _refreshRequired = false;
        }
        catch { if (Current(request, repository)) ErrorMessage = L.Get("NasConnectionsLoadFailed"); }
        finally { if (Current(request, repository)) { IsBusy = false; Notify(); } }
    }
    private async Task ReadSnapshotAsync(INasSettingsRepository repository, RequestState request, string? selectedKey)
    {
        var snapshot = await repository.LoadConnectionSnapshotAsync(request.Token);
        if (!Current(request, repository)) return;
        Connections.Clear(); foreach (var item in snapshot.Items) Connections.Add(item with { IdentityKeys = Array.AsReadOnly(item.IdentityKeys.ToArray()) });
        IsComplete = snapshot.IsComplete; _loaded = true;
        Selected = VisibleConnections.FirstOrDefault(item => selectedKey is not null && item.TargetKey == selectedKey);
    }
    public void SetSearch(string value)
    {
        if (_disposed || IsBusy || SearchText == value) return;
        SearchText = value; ResetConfirmation(); if (Selected is not null && !VisibleConnections.Contains(Selected)) Selected = null; Notify();
    }
    public void SelectConnection(string? id)
    {
        if (_disposed || IsBusy) return;
        var selected = VisibleConnections.FirstOrDefault(item => item.Id == id); if (ReferenceEquals(selected, Selected)) return;
        Selected = selected; ResetConfirmation(); Notify();
    }
    public bool Confirm(bool riskConfirmed, bool currentSessionConfirmed)
    {
        _confirmation = CanChoose && riskConfirmed && (Selected!.RequiresCurrentSessionConfirmation ? currentSessionConfirmed : true)
            ? new(_repository!.ProfileId, Selected!, Guid.NewGuid(), true, currentSessionConfirmed) : null;
        Notify(); return CanExecute;
    }
    public async Task DisconnectAsync()
    {
        if (!CanExecute || _repository is null || _confirmation is null) return;
        var repository = _repository; var confirmation = _confirmation; var request = BeginRequest();
        LastTarget = Describe(confirmation.Baseline.Account, confirmation.Baseline.Source, confirmation.Baseline.Protocol ?? confirmation.Baseline.Type);
        LastResult = null; ErrorMessage = null; ResetConfirmation(); IsBusy = true; Notify();
        try
        {
            var result = await repository.DisconnectConnectionAsync(confirmation, request.Token);
            if (!Current(request, repository)) return;
            LastResult = result;
            if (result.Counts.Unknown > 0) AddPending(confirmation.Baseline);
            _refreshRequired = result.ErrorCategory == MutationErrorCategory.Conflict || result.RequiresRefresh && result.Counts.Unknown == 0;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                try { await ReadSnapshotAsync(repository, request, null); }
                catch { if (Current(request, repository)) { _loaded = false; ErrorMessage = L.Get("NasConnectionsLoadFailed"); } }
            }
        }
        catch
        {
            if (Current(request, repository)) { LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "disconnectConnection", true, true, new(0, 0, 1)); AddPending(confirmation.Baseline); }
        }
        finally { if (Current(request, repository)) { IsBusy = false; Notify(); } }
    }
    private void AddPending(NasConnectionEntry entry)
    {
        if (!Pending.Any(item => item.TargetKey == entry.TargetKey)) Pending.Add(new(entry.TargetKey, entry.Account, entry.Source, entry.Protocol ?? entry.Type));
    }
    private void ResetConfirmation() { _confirmation = null; ConfirmationVersion++; }
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _loaded = false; _recoveryReady = false; _refreshRequired = false; IsBusy = false; IsComplete = false;
        Connections.Clear(); Pending.Clear(); Selected = null; SearchText = ""; LastTarget = ""; LastResult = null; ErrorMessage = null; ResetConfirmation(); Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private RequestState BeginRequest() { CancelRequest(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void CancelRequest() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private bool Current(RequestState request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
