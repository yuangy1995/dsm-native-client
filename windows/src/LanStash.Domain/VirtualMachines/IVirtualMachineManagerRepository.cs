namespace LanStash.Domain;

public interface IVirtualMachineManagerRepository
{
    Guid ProfileId { get; }
    VirtualMachineManagerAvailability Availability { get; }
    bool CanReadNetworkManagement => false;
    bool CanManageNetworks => false;
    Task<VirtualMachineNetworkInventory> LoadNetworkManagementAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineNetworkInventory>(new NotSupportedException());
    Task<MutationResult> MutateNetworkAsync(VirtualMachineNetworkRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineNetworkRecovery>> GetNetworkRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineNetworkRecovery>>([]);
    Task<MutationResult?> ReviewNetworkAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);
    bool CanControlPower => false;
    bool CanOpenConsole => false;
    Task<VirtualMachineConsoleSession> OpenConsoleAsync(VirtualMachineSummary baseline, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineConsoleSession>(new NotSupportedException());
    bool CanDeleteMachines => false;
    bool CanDeleteImages => false;
    bool CanImportImages => false;
    Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageImportStoragesAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<VirtualizationResourceSummary>>(new NotSupportedException());
    Task<VirtualMachineImageImportResult> ImportImageAsync(VirtualMachineImageImportRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineImageImportResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineImageImportRequest>> GetImageImportRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineImageImportRequest>>([]);
    Task<VirtualMachineImageImportResult?> ReviewImageImportAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromResult<VirtualMachineImageImportResult?>(null);
    Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<VirtualizationResourceSummary>>(new NotSupportedException());
    Task<MutationResult> DeleteImageAsync(VirtualMachineImageDeleteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>([]);
    Task<MutationResult?> ReviewImageDeletionAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);
    Task<MutationResult> DeleteMachineAsync(VirtualMachineDeleteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetDeletionRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>([]);
    Task<MutationResult?> ReviewDeletionAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromResult<MutationResult?>(null);
    bool CanCreateMachine => false;
    bool CanCreateAdvancedMachine => false;
    bool CanReadAdvancedCreation => false;
    Task<VirtualMachineAdvancedCreationInventory> LoadAdvancedCreationInventoryAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineAdvancedCreationInventory>(new NotSupportedException());
    Task<VirtualMachineAdvancedSettings> LoadAdvancedSettingsAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineAdvancedSettings>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineCreationRecovery>> GetCreationRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineCreationRecovery>>([]);
    Task<VirtualMachineCreationResult> CreateMachineAsync(VirtualMachineCreationRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineCreationResult>(new NotSupportedException());
    Task<VirtualMachineCreationResult?> ReviewCreationAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineCreationResult?>(new NotSupportedException());
    Task<VirtualMachineCreationResult?> ContinueCreationAsync(Guid requestId, bool riskConfirmed, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineCreationResult?>(new NotSupportedException());
    bool CanReadTasks => false;
    bool CanClearTasks => false;
    Task<VirtualMachineTaskCleanupResult> ClearFinishedTasksAsync(VirtualMachineTaskCleanupRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineTaskCleanupResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineTaskCleanupRecovery>> GetTaskCleanupRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineTaskCleanupRecovery>>([]);
    Task<VirtualMachineTaskCleanupResult?> ReviewTaskCleanupAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromResult<VirtualMachineTaskCleanupResult?>(null);
    Task<IReadOnlyList<VirtualMachineTaskSummary>> LoadVirtualMachineTasksAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<VirtualMachineTaskSummary>>(new NotSupportedException());
    bool CanEditSettings => false;
    bool CanEditPriority => false;
    Task<VirtualMachineSettings> LoadSettingsAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromException<VirtualMachineSettings>(new NotSupportedException());
    Task<MutationResult> SaveSettingsAsync(VirtualMachineSettingsRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachineSettingsRecovery>> GetSettingsRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachineSettingsRecovery>>([]);
    Task<MutationResult?> ReviewSettingsAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());
    Task<MutationResult> ControlPowerAsync(VirtualMachinePowerRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<VirtualMachinePowerRecovery>> GetPowerRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<VirtualMachinePowerRecovery>>([]);
    Task<MutationResult?> ReviewPowerAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());

    Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);
}
