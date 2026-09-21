using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed class VirtualMachineCreationViewModel(TimeProvider? timeProvider = null) : ObservableObject, IDisposable
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private IVirtualMachineManagerRepository? _repository;
    private CancellationTokenSource? _lifetime;
    private Task? _polling;
    private long _generation;
    private bool _disposed, _ready, _confirmed, _needsReload, _edited;
    private VirtualMachineCreationRequest? _confirmedDraft;
    public IReadOnlyList<VirtualizationResourceSummary> Storages { get; private set; } = [];
    public IReadOnlyList<VirtualizationResourceSummary> Networks { get; private set; } = [];
    public IReadOnlyList<VirtualizationResourceSummary> Images { get; private set; } = [];
    public VirtualMachineAdvancedCreationInventory? AdvancedInventory { get; private set; }
    public bool CanChooseAdvanced => _repository?.CanCreateAdvancedMachine == true && AdvancedInventory is { StoragesFrozen: false } inventory &&
        inventory.Storages.Any(item => item.Status == "online" && item.StatusType == "healthy");
    public IReadOnlyList<VirtualMachineCreationImage> BootImages => AdvancedInventory is { ImagesFrozen: false } inventory
        ? inventory.Images.Where(item => item.Type == "iso" && item.StatusType != "error").ToArray() : [];
    public IReadOnlyList<VirtualizationResourceSummary> FormStorages => Draft?.Advanced is null ? Storages : AdvancedInventory?.Storages
        .Where(item => item.Status == "online" && item.StatusType == "healthy")
        .Select(item => new VirtualizationResourceSummary(item.Id, item.Name, VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy)).ToArray() ?? [];
    public IReadOnlyList<VirtualMachineCreationRecovery> Recoveries { get; private set; } = [];
    public VirtualMachineCreationRequest? Draft { get; private set; }
    public VirtualMachineCreationRequest? ActiveRequest { get; private set; }
    public VirtualMachineCreationResult? LastResult { get; private set; }
    public long FormVersion { get; private set; }
    public bool IsBusy { get; private set; }
    public bool IsReadOnly => _repository?.CanCreateMachine != true;
    public bool CanRequestPowerOn => _repository?.CanControlPower == true;
    public bool CanEdit => !_disposed && _ready && !IsBusy && ActiveRequest is null;
    public bool CanRefresh => !_disposed && _repository is not null && !IsBusy;
    public bool CanConfirm => !_disposed && !IsBusy && !IsReadOnly && ErrorMessage is null && (ActiveRequest is not null
        ? LastResult?.CanContinue == true
        : CanEdit && !_needsReload && Draft is not null && (!Draft.PowerOnAfterCreation || CanRequestPowerOn) && VirtualMachineCreationRules.IsValid(Draft) && ResourcesMatch(Draft));
    public bool CanSubmit => CanConfirm && _confirmed && (ActiveRequest is not null || Draft is not null && _confirmedDraft is not null && SameDraft(Draft, _confirmedDraft));
    public bool NeedsParentRefresh { get; private set; }
    public string? ErrorMessage { get; private set; }
    public string? ValidationMessage => !_edited || ActiveRequest is not null || Draft is null ? null :
        Draft.PowerOnAfterCreation && !CanRequestPowerOn ? L.Get("VmCreatePowerOptionUnavailable") :
        !VirtualMachineCreationRules.IsValid(Draft) ? L.Get(Draft.Advanced is null ? "VmCreateInvalid" : "VmCreateAdvancedInvalid") : !ResourcesMatch(Draft) ? L.Get("VmCreateResourcesChanged") : null;
    public string PrimaryText => L.Get(ActiveRequest is null ? "VmCreateSubmit" : LastResult?.Stage == VirtualMachineCreationStage.PowerOn ? "VmPowerOnAction" : "VmCreateContinue");
    public string RefreshText => L.Get(ActiveRequest is null ? "VmCreateRefresh" : "VmCreateReview");
    public string? Feedback => LastResult is null ? null : L.Get(LastResult.Result.ErrorCategory switch
    {
        MutationErrorCategory.Permission => "VmCreatePermission", MutationErrorCategory.Authentication => "VmCreateReconnect",
        _ => LastResult.Stage switch
        {
            VirtualMachineCreationStage.Complete => ActiveRequest?.PowerOnAfterCreation == true ? "VmCreatePoweredOn" : "VmCreateCompleted", VirtualMachineCreationStage.VerifyReceipt => "VmCreateReceiptUnknown",
            VirtualMachineCreationStage.PowerOn => LastResult.CanContinue ? "VmCreateReadyToPowerOn" : "VmCreatePowerBlocked",
            VirtualMachineCreationStage.VerifyPower => "VmCreatePowerUnknown",
            VirtualMachineCreationStage.Configure => LastResult.CanContinue ? "VmCreateReadyToConfigure" : "VmCreateConfigurationBlocked",
            VirtualMachineCreationStage.VerifyConfiguration => "VmCreateConfigurationUnknown", VirtualMachineCreationStage.VerifyImageSource => "VmCreateImageReview",
            VirtualMachineCreationStage.Rejected => LastResult.Result.Submitted ? "VmCreatePartialFailure" : "VmCreateNotStarted", _ => "VmCreateWaiting"
        }
    });
    public async Task ActivateAsync(IVirtualMachineManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; _lifetime = new(); await RefreshAsync();
    }
    public void ChangeDraft(VirtualMachineCreationRequest draft)
    {
        if (!CanEdit || Draft is { } old && SameDraft(old, draft)) return;
        Draft = draft with { ProfileId = _repository!.ProfileId, RequestId = Guid.Empty, RiskConfirmed = false, Disks = draft.Disks.ToArray(), Networks = draft.Networks.ToArray() };
        _confirmed = false; _edited = true; LastResult = null; Notify();
    }
    public bool Confirm(bool confirmed)
    { _confirmed = confirmed && CanConfirm; _confirmedDraft = _confirmed && ActiveRequest is null && Draft is { } draft ? draft with { Disks = draft.Disks.ToArray(), Networks = draft.Networks.ToArray() } : null; Notify(); return CanSubmit; }
    public void SelectOperatingSystem(VirtualMachineOperatingSystem? operatingSystem)
    {
        if (!CanEdit || Draft is not { } draft || operatingSystem is not null && !CanChooseAdvanced) return;
        if (operatingSystem is null)
        {
            var storage = Storages.FirstOrDefault(item => item.Id == draft.Storage.Id) ?? Storages.FirstOrDefault();
            if (storage is null) return;
            ChangeDraft(draft with { Advanced = null, Storage = storage });
        }
        else
        {
            var choices = AdvancedInventory!.Storages.Where(item => item.Status == "online" && item.StatusType == "healthy").ToArray();
            var storage = choices.FirstOrDefault(item => item.Id == draft.Storage.Id) ?? choices.First();
            ChangeDraft(draft with { Storage = new(storage.Id, storage.Name, VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy),
                Advanced = new(operatingSystem.Value, draft.Advanced?.Firmware ?? VirtualMachineFirmware.Legacy, storage, draft.Advanced?.BootImage) });
        }
        FormVersion++; Notify();
    }
    public async Task SelectRecoveryAsync(VirtualMachineCreationRecovery recovery)
    {
        if (!CanRefresh || ActiveRequest?.RequestId == recovery.Request.RequestId || !Recoveries.Any(item => item.Request.RequestId == recovery.Request.RequestId) || recovery.Request.ProfileId != _repository!.ProfileId) return;
        Cancel(); _lifetime = new(); _confirmed = false; ErrorMessage = null; LastResult = null;
        ActiveRequest = recovery.Request with { Disks = recovery.Request.Disks.ToArray(), Networks = recovery.Request.Networks.ToArray(), RiskConfirmed = false };
        Draft = ActiveRequest; FormVersion++; Notify(); await RefreshAsync();
    }
    public async Task RefreshAsync()
    {
        if (!CanRefresh) return;
        var repository = _repository!; var generation = _generation; var token = _lifetime!.Token;
        IsBusy = true; _confirmed = false; ErrorMessage = null; Notify();
        try
        {
            if (ActiveRequest is { } active)
            {
                var result = await repository.ReviewCreationAsync(active.RequestId, token); if (!Current(generation, repository)) return;
                if (result is null || result.RequestId != active.RequestId) { LastResult = null; ErrorMessage = L.Get("VmCreateRecoveryMissing"); }
                else Accept(result, initialSubmission: false);
            }
            else
            {
                _ready = false;
                var recoveries = await repository.GetCreationRecoveriesAsync(token); if (!Current(generation, repository)) return;
                Recoveries = recoveries.Where(item => item.Request.ProfileId == repository.ProfileId).ToArray();
                var snapshot = await repository.LoadSnapshotAsync(token); if (!Current(generation, repository)) return;
                if (snapshot.ProfileId != repository.ProfileId || snapshot.Storages.Status != VirtualMachineManagerSectionStatus.Available) throw new InvalidOperationException("vm.create.resources");
                Storages = snapshot.Storages.Items.Where(item => item.Health == VirtualizationResourceHealth.Healthy).ToArray();
                Networks = snapshot.Networks.Status == VirtualMachineManagerSectionStatus.Available ? snapshot.Networks.Items : [];
                Images = snapshot.Images.Status == VirtualMachineManagerSectionStatus.Available ? snapshot.Images.Items.Where(item => item.Type == "disk").ToArray() : [];
                AdvancedInventory = null;
                if (repository.CanCreateAdvancedMachine)
                {
                    try
                    {
                        var advanced = await repository.LoadAdvancedCreationInventoryAsync(token); if (!Current(generation, repository)) return;
                        if (advanced.ProfileId != repository.ProfileId) throw new InvalidOperationException("vm.create.advanced_profile");
                        AdvancedInventory = advanced;
                    }
                    catch (OperationCanceledException) { throw; }
                    catch (CertificateTrustChallengeException) { throw; }
                    catch (DsmException error) when (error.AuthenticationFailure) { throw; }
                    catch { /* 高级选项显示不可用，保留公开基础创建。 */ }
                }
                if (Draft is null && Storages.FirstOrDefault() is { } storage)
                    Draft = new(repository.ProfileId, storage, [new(20480)], [new(null)], new("", "", 2, 2048, VirtualMachineAutoStart.Off), Guid.Empty, false);
                _ready = true; _needsReload = false; FormVersion++;
                if (Storages.Count == 0) ErrorMessage = L.Get("VmCreateNoStorage");
            }
        }
        catch { if (Current(generation, repository)) { ErrorMessage = L.Get("VmCreateLoadFailed"); _needsReload = true; } }
        finally { if (Current(generation, repository)) { IsBusy = false; Notify(); EnsurePolling(); } }
    }
    public async Task SubmitAsync()
    {
        if (!CanSubmit || _repository is null) return;
        var repository = _repository; var generation = _generation; var token = _lifetime!.Token; var initial = ActiveRequest is null;
        var continuingPower = !initial && LastResult?.Stage is VirtualMachineCreationStage.PowerOn or VirtualMachineCreationStage.VerifyPower;
        var request = ActiveRequest ?? _confirmedDraft! with { RequestId = Guid.NewGuid(), RiskConfirmed = true };
        ActiveRequest = request; IsBusy = true; _confirmed = false; ErrorMessage = null; Notify();
        try
        {
            var result = initial ? await repository.CreateMachineAsync(request, token) : await repository.ContinueCreationAsync(request.RequestId, true, token);
            if (!Current(generation, repository)) return;
            if (result is null || result.RequestId != request.RequestId) throw new InvalidOperationException("vm.create.result.identity");
            Accept(result, initial);
        }
        catch
        {
            if (Current(generation, repository))
            {
                LastResult = new(request.RequestId, initial ? VirtualMachineCreationStage.VerifyReceipt : continuingPower ? VirtualMachineCreationStage.VerifyPower : VirtualMachineCreationStage.VerifyConfiguration,
                    new(1, MutationResultStatus.SubmittedButUnverified, "createVirtualMachine", true, true, new(0, 0, 1)));
                ErrorMessage = L.Get(initial ? "VmCreateReceiptUnknown" : continuingPower ? "VmCreatePowerUnknown" : "VmCreateConfigurationUnknown"); NeedsParentRefresh = true;
            }
        }
        finally { if (Current(generation, repository)) { IsBusy = false; Notify(); EnsurePolling(); } }
    }
    private void Accept(VirtualMachineCreationResult result, bool initialSubmission)
    {
        LastResult = result; NeedsParentRefresh |= result.Result.Submitted || result.Result.RequiresRefresh;
        if (initialSubmission && !result.Result.Submitted) { ActiveRequest = null; _needsReload = true; }
    }
    private bool ResourcesMatch(VirtualMachineCreationRequest request) => (request.Advanced is { } advanced ? CanChooseAdvanced && AdvancedInventory!.Storages.Any(item =>
        item.Id == advanced.Storage.Id && item.Name == advanced.Storage.Name && item.HostId == advanced.Storage.HostId && item.HostName == advanced.Storage.HostName && item.Status == "online" && item.StatusType == "healthy") &&
        (advanced.BootImage is null || BootImages.Contains(advanced.BootImage)) : Storages.Any(item => item.Id == request.Storage.Id && item.Name == request.Storage.Name)) &&
        request.Disks.All(disk => disk.Image is null || Images.Any(item => item.Id == disk.Image.Id && item.Name == disk.Image.Name)) &&
        request.Networks.All(nic => nic.Network is null || Networks.Any(item => item.Id == nic.Network.Id && item.Name == nic.Network.Name));
    private static bool SameDraft(VirtualMachineCreationRequest left, VirtualMachineCreationRequest right) => left.ProfileId == right.ProfileId && left.Settings == right.Settings &&
        left.PowerOnAfterCreation == right.PowerOnAfterCreation && left.Advanced == right.Advanced && left.Storage == right.Storage && left.Disks.SequenceEqual(right.Disks) && left.Networks.SequenceEqual(right.Networks);
    private bool ShouldPoll => ActiveRequest is not null && ErrorMessage is null && LastResult?.Result.ErrorCategory != MutationErrorCategory.Authentication &&
        LastResult?.Stage is VirtualMachineCreationStage.Creating or VirtualMachineCreationStage.VerifyConfiguration or VirtualMachineCreationStage.VerifyPower;
    private void EnsurePolling()
    {
        if (!CanRefresh || !ShouldPoll || _polling is { IsCompleted: false }) return;
        _polling = PollAsync(_generation, _repository!, _lifetime!.Token);
    }
    private async Task PollAsync(long generation, IVirtualMachineManagerRepository repository, CancellationToken token)
    {
        try { while (Current(generation, repository) && ShouldPoll) { await Task.Delay(TimeSpan.FromSeconds(2), _time, token); if (Current(generation, repository) && ShouldPoll) await RefreshAsync(); } }
        catch (OperationCanceledException) { }
    }
    private bool Current(long generation, IVirtualMachineManagerRepository repository) => !_disposed && generation == _generation && ReferenceEquals(repository, _repository);
    private void Cancel() { _generation++; var old = _lifetime; _lifetime = null; old?.Cancel(); old?.Dispose(); _polling = null; }
    public void Deactivate()
    { Cancel(); _repository = null; Storages = []; Networks = []; Images = []; AdvancedInventory = null; Recoveries = []; Draft = ActiveRequest = _confirmedDraft = null; LastResult = null; ErrorMessage = null; IsBusy = _ready = _confirmed = _needsReload = _edited = NeedsParentRefresh = false; FormVersion++; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
    private static LocalizationService L => LocalizationService.Current;
}
