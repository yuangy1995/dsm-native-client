namespace LanStash.Domain;

public interface IVirtualMachineManagerRepository
{
    Guid ProfileId { get; }
    VirtualMachineManagerAvailability Availability { get; }

    Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);
}
