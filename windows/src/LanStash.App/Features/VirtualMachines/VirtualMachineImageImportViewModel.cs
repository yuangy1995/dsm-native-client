using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed class VirtualMachineImageImportViewModel(IVirtualMachineManagerRepository repository, TimeProvider? timeProvider = null) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private Task? _polling;
    private VirtualMachineImageImportRequest? _confirmation;
    private bool _disposed, _ready, _confirmed, _auth;
    public IReadOnlyList<VirtualizationResourceSummary> Storages { get; private set; } = [];
    public IReadOnlyList<VirtualMachineImageImportRequest> Recoveries { get; private set; } = [];
    public VirtualMachineImageImportRequest? Draft { get; private set; }
    public VirtualMachineImageImportRequest? ActiveRequest { get; private set; }
    public VirtualMachineImageImportResult? Result { get; private set; }
    public bool IsBusy { get; private set; }
    public bool IsReadOnly => !repository.CanImportImages;
    public bool CanEdit => !_disposed && !_auth && !IsBusy && _ready && ActiveRequest is null;
    public bool CanRefresh => !_disposed && !_auth && !IsBusy;
    public bool CanNew => CanRefresh && Result?.Stage is VirtualMachineImageImportStage.Complete or VirtualMachineImageImportStage.Rejected;
    public bool CanConfirm => CanEdit && !IsReadOnly && Error is null && VirtualMachineImageImportRules.IsValid(Draft) &&
        Draft!.Storages.All(expected => Storages.Contains(expected));
    public bool IsConfirmed => _confirmed;
    public bool CanSubmit => CanConfirm && _confirmed && _confirmation is { } confirmed && Draft!.Name == confirmed.Name &&
        Draft.SourcePath == confirmed.SourcePath && Draft.Type == confirmed.Type && Draft.Storages.SequenceEqual(confirmed.Storages);
    public string? Validation => Draft is not null && ActiveRequest is null && !VirtualMachineImageImportRules.IsValid(Draft) ? L.Get("VmImageImportInvalid") : null;
    public string? Error { get; private set; }
    public bool NeedsParentRefresh { get; private set; }
    private static LocalizationService L => LocalizationService.Current;
    public string? Feedback => Result is null ? null : L.Get(Result.Result.ErrorCategory switch
    {
        MutationErrorCategory.Authentication => "VmImageImportSignIn", MutationErrorCategory.Permission => "VmImageImportPermission",
        _ => Result.Stage switch
        {
            VirtualMachineImageImportStage.Complete => "VmImageImportCompleted",
            VirtualMachineImageImportStage.Rejected => "VmImageImportRejected",
            VirtualMachineImageImportStage.Importing => "VmImageImportRunning",
            _ => "VmImageImportUnknown"
        }
    });
    public string Summary => (ActiveRequest ?? Draft) is { } value ? L.Format("VmImageImportSummary", value.Name, value.SourcePath,
        string.Join(", ", value.Storages.Select(item => item.Name))) : "";
    public void Edit(string name, string path, VirtualMachineImageType type, IEnumerable<VirtualizationResourceSummary> storages)
    {
        if (!CanEdit) return;
        Draft = new(repository.ProfileId, name, path, type, storages.ToArray(), Guid.Empty, false);
        _confirmed = false; Result = null; Notify();
    }
    public void Confirm(bool value)
    {
        _confirmed = value && CanConfirm;
        _confirmation = _confirmed ? Draft! with { Storages = Draft!.Storages.ToArray() } : null; Notify();
    }
    public async Task RefreshAsync()
    {
        if (!CanRefresh) return; IsBusy = true; _confirmed = false; Error = null; Notify();
        try
        {
            if (ActiveRequest is { } request)
            {
                var result = await repository.ReviewImageImportAsync(request.RequestId, _lifetime.Token);
                if (_disposed) return;
                if (result is null || result.RequestId != request.RequestId) throw new InvalidOperationException("vm.image_import.recovery_missing");
                Accept(result);
            }
            else
            {
                _ready = false;
                var recoveries = await repository.GetImageImportRecoveriesAsync(_lifetime.Token);
                if (_disposed) return;
                Recoveries = recoveries.Where(item => item.ProfileId == repository.ProfileId).ToArray();
                var storages = await repository.LoadImageImportStoragesAsync(_lifetime.Token);
                if (_disposed) return;
                Storages = storages.Where(item => item.Health == VirtualizationResourceHealth.Healthy).ToArray();
                _ready = true;
                if (Storages.Count == 0) Error = L.Get("VmImageImportNoStorage");
            }
        }
        catch (DsmException error) when (error.AuthenticationFailure) { if (!_disposed) { _auth = true; Error = L.Get("VmImageImportSignIn"); } }
        catch { if (!_disposed) Error = L.Get("VmImageImportLoadFailed"); }
        finally { if (!_disposed) { IsBusy = false; Notify(); Poll(); } }
    }
    public async Task SelectRecoveryAsync(VirtualMachineImageImportRequest request)
    {
        if (!CanRefresh || !Recoveries.Any(item => item.RequestId == request.RequestId)) return;
        ActiveRequest = request; _confirmed = false; Result = null; await RefreshAsync();
    }
    public async Task NewAsync()
    {
        if (!CanNew) return; ActiveRequest = null; Result = null; Draft = null; await RefreshAsync();
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit) return;
        var request = _confirmation! with { RequestId = Guid.NewGuid(), RiskConfirmed = true, Storages = _confirmation!.Storages.ToArray() };
        ActiveRequest = request; _confirmed = false; IsBusy = true; Error = null; Notify();
        try
        {
            var result = await repository.ImportImageAsync(request, _lifetime.Token);
            if (_disposed) return;
            if (result.RequestId != request.RequestId) throw new InvalidOperationException("vm.image_import.result_identity");
            Accept(result);
        }
        catch
        {
            if (!_disposed) { Result = new(request.RequestId, VirtualMachineImageImportStage.VerifyReceipt,
                new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineImageImport", true, true, new(0, 0, 1))); NeedsParentRefresh = true; }
        }
        finally { if (!_disposed) { IsBusy = false; Notify(); Poll(); } }
    }
    private void Accept(VirtualMachineImageImportResult result)
    {
        Result = result; NeedsParentRefresh |= result.Result.Submitted || result.Result.RequiresRefresh;
        _auth |= result.Result.ErrorCategory == MutationErrorCategory.Authentication;
    }
    private bool ShouldPoll => !_disposed && !_auth && Error is null && Result?.Stage == VirtualMachineImageImportStage.Importing &&
        Result.Result.Status != MutationResultStatus.CancellationRequestedAfterSubmission && Result.Result.ErrorCategory is null or MutationErrorCategory.Unknown;
    private void Poll()
    {
        if (!CanRefresh || !ShouldPoll || _polling is { IsCompleted: false }) return;
        _polling = PollAsync();
    }
    private async Task PollAsync()
    {
        try { while (ShouldPoll) { await Task.Delay(TimeSpan.FromSeconds(2), _time, _lifetime.Token); if (CanRefresh && ShouldPoll) await RefreshAsync(); } }
        catch (OperationCanceledException) { }
    }
    private void Notify() => RaisePropertyChanged(string.Empty);
    public void Dispose() { if (_disposed) return; _disposed = true; _lifetime.Cancel(); _lifetime.Dispose(); }
}
