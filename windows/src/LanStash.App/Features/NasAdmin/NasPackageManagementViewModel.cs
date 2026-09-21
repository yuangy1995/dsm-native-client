using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.NasAdmin;

public sealed class NasPackageManagementViewModel : ObservableObject, IDisposable
{
    private INasSettingsRepository? _repository;
    private CancellationTokenSource? _cancellation;
    private long _generation;
    private bool _disposed, _loaded, _refreshRequired;
    private NasPackageMutationRequest? _confirmation;
    public ObservableCollection<NasPackageSummary> Packages { get; } = [];
    public ObservableCollection<NasPackageRecoveryInfo> Pending { get; } = [];
    public NasPackageSummary? Selected { get; private set; }
    public NasPackageAction? SelectedAction { get; private set; }
    public string SearchText { get; private set; } = "";
    public bool IsBusy { get; private set; }
    public bool IsReadOnly => _repository is null || !(_repository.PackageControlAvailability.CanStartStop || _repository.PackageControlAvailability.CanUninstall);
    public string? ErrorMessage { get; private set; }
    public MutationResult? LastResult { get; private set; }
    public NasPackageAction? LastAction { get; private set; }
    public string LastTarget { get; private set; } = "";
    public bool WasSuccessful => LastResult?.Status == MutationResultStatus.ConfirmedSuccess;
    public IReadOnlyList<NasPackageSummary> VisiblePackages => Packages.Where(item =>
        item.Name.Contains(SearchText, StringComparison.CurrentCultureIgnoreCase) || item.Id.Contains(SearchText, StringComparison.OrdinalIgnoreCase))
        .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
    public bool CanExecute => _confirmation is not null && SelectedAction == _confirmation.Action &&
        ReferenceEquals(Selected, _confirmation.Baseline) && CanChoose(_confirmation.Action);
    public string? Feedback => LastResult is null ? null : L.Format(LastResult.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => LastAction switch
        { NasPackageAction.Start => "NasPackageStarted", NasPackageAction.Stop => "NasPackageStopped", _ => "NasPackageRemoved" },
        MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => "NasPackageUnknown",
        MutationResultStatus.CancelledBeforeSubmission => "NasPackageCancelled",
        MutationResultStatus.PermissionDenied => "NasPackagePermission",
        MutationResultStatus.Unsupported => "NasPackageUnsupported",
        _ => LastResult.ErrorCategory switch
        {
            MutationErrorCategory.Authentication => "NasPackageAuthentication", MutationErrorCategory.Permission => "NasPackagePermission",
            MutationErrorCategory.Conflict => "NasPackageConflict", _ => "NasPackageFailed",
        },
    }, LastTarget);

    public async Task ActivateAsync(INasSettingsRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await LoadAsync();
    }
    public Task ReloadAsync() => _disposed || _repository is null || IsBusy ? Task.CompletedTask : LoadAsync();
    private async Task LoadAsync()
    {
        var repository = _repository!; var request = BeginRequest(); var selectedId = Selected?.Id;
        ClearConfirmation(); Selected = null; Packages.Clear(); _loaded = false; IsBusy = true; ErrorMessage = null; Notify();
        try
        {
            await repository.PrepareServiceSettingsAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            var recoveries = await repository.GetPackageRecoveriesAsync(request.Token);
            if (!IsCurrent(request, repository)) return;
            var pending = new List<NasPackageRecoveryInfo>();
            // 包含已经从目录消失的卸载目标；恢复仅查询结果，不重发控制请求。
            foreach (var item in recoveries)
            {
                var result = await repository.ReviewPackageAsync(item.PackageId, request.Token);
                if (!IsCurrent(request, repository)) return;
                if (result is null || result.Counts.Unknown > 0 || result.ErrorCategory == MutationErrorCategory.Conflict ||
                    result.Status == MutationResultStatus.CancelledBeforeSubmission) pending.Add(item);
                if (result is not null) { LastResult = result; LastAction = item.Action; LastTarget = item.DisplayName; }
            }
            Pending.Clear(); foreach (var item in pending) Pending.Add(item);
            await LoadDirectoryAsync(repository, request, selectedId);
            if (IsCurrent(request, repository)) _refreshRequired = false;
        }
        catch (OperationCanceledException) when (request.Token.IsCancellationRequested) { }
        catch { if (IsCurrent(request, repository)) ErrorMessage = L.Get("NasPackageLoadFailed"); }
        finally { if (IsCurrent(request, repository)) { IsBusy = false; Notify(); } }
    }
    private async Task LoadDirectoryAsync(INasSettingsRepository repository, RequestState request, string? selectedId)
    {
        var items = await repository.LoadPackagesAsync(request.Token);
        if (!IsCurrent(request, repository)) return;
        Packages.Clear();
        foreach (var item in items) Packages.Add(item with
        {
            AvailableOperations = item.AvailableOperations is null ? null : Array.AsReadOnly(item.AvailableOperations.ToArray()),
            DesktopApps = item.DesktopApps is null ? null : Array.AsReadOnly(item.DesktopApps.ToArray()),
        });
        Selected = VisiblePackages.FirstOrDefault(item => item.Id == selectedId); _loaded = true;
    }
    public void SetSearch(string text)
    {
        if (_disposed || IsBusy || SearchText == text) return;
        SearchText = text; ClearConfirmation();
        if (Selected is not null && !VisiblePackages.Contains(Selected)) Selected = null;
        Notify();
    }
    public void SelectPackage(string? id)
    {
        if (_disposed || IsBusy) return;
        var item = VisiblePackages.FirstOrDefault(item => item.Id == id);
        if (ReferenceEquals(item, Selected)) return;
        Selected = item; ClearConfirmation(); Notify();
    }
    public bool CanChoose(NasPackageAction action)
    {
        if (_disposed || !_loaded || IsBusy || _refreshRequired || ErrorMessage is not null || _repository is null || Selected is null ||
            Pending.Any(item => item.PackageId == Selected.Id)) return false;
        var available = _repository.PackageControlAvailability;
        return action switch
        {
            NasPackageAction.Start => available.CanStartStop && Selected.CanStart,
            NasPackageAction.Stop => available.CanStartStop && Selected.CanStop,
            NasPackageAction.Uninstall => available.CanUninstall && Selected.CanUninstall,
            _ => false,
        };
    }
    public void ChooseAction(NasPackageAction action)
    {
        if (!CanChoose(action)) return;
        ClearConfirmation(); SelectedAction = action; Notify();
    }
    public bool ConfirmAction(bool confirmed)
    {
        _confirmation = null;
        if (confirmed && SelectedAction is { } action && CanChoose(action))
            _confirmation = new(_repository!.ProfileId, Selected!, action, Guid.NewGuid(), true);
        Notify(); return CanExecute;
    }
    public async Task ExecuteAsync()
    {
        if (!CanExecute || _repository is null || _confirmation is null) return;
        var repository = _repository; var confirmation = _confirmation; var request = BeginRequest();
        ClearConfirmation(); LastResult = null; LastAction = confirmation.Action; LastTarget = confirmation.Baseline.Name;
        IsBusy = true; ErrorMessage = null; Notify();
        try
        {
            var result = await repository.ControlPackageAsync(confirmation, request.Token);
            if (!IsCurrent(request, repository)) return;
            LastResult = result;
            if (result.Counts.Unknown > 0)
            {
                if (!Pending.Any(item => item.PackageId == confirmation.Baseline.Id))
                    Pending.Add(new(confirmation.Baseline.Id, confirmation.Baseline.Name, confirmation.Action));
            }
            _refreshRequired = result.ErrorCategory == MutationErrorCategory.Conflict || result.RequiresRefresh && result.Counts.Unknown == 0;
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                try { await LoadDirectoryAsync(repository, request, confirmation.Baseline.Id); }
                catch { if (IsCurrent(request, repository)) { _loaded = false; ErrorMessage = L.Get("NasPackageLoadFailed"); } }
            }
        }
        catch
        {
            if (IsCurrent(request, repository))
            {
                LastResult = new(1, MutationResultStatus.SubmittedButUnverified, "controlPackage", true, true, new(0, 0, 1));
                Pending.Add(new(confirmation.Baseline.Id, confirmation.Baseline.Name, confirmation.Action));
            }
        }
        finally { if (IsCurrent(request, repository)) { IsBusy = false; Notify(); } }
    }
    private void ClearConfirmation() { _confirmation = null; SelectedAction = null; }
    public void Deactivate()
    {
        CancelRequest(); _repository = null; _loaded = false; _refreshRequired = false; IsBusy = false;
        ClearConfirmation(); Packages.Clear(); Pending.Clear(); Selected = null; SearchText = "";
        ErrorMessage = null; LastResult = null; LastAction = null; LastTarget = ""; Notify();
    }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private RequestState BeginRequest() { CancelRequest(); _cancellation = new(); return new(++_generation, _cancellation.Token); }
    private void CancelRequest() { _generation++; var previous = _cancellation; _cancellation = null; previous?.Cancel(); previous?.Dispose(); }
    private bool IsCurrent(RequestState request, INasSettingsRepository repository) => !_disposed && request.Generation == _generation && ReferenceEquals(repository, _repository);
    private void Notify() => RaisePropertyChanged(string.Empty);
    private sealed record RequestState(long Generation, CancellationToken Token);
    private static LocalizationService L => LocalizationService.Current;
}
