namespace LanStash.Domain;

public interface IContainerManagerRepository
{
    Guid ProfileId { get; }
    ContainerManagerAvailability Availability { get; }
    bool CanPullImages => false;
    Task<ContainerImagePullResult> PullImageAsync(ContainerImagePullRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<ContainerImagePullResult>(new NotSupportedException());
    Task<IReadOnlyList<ContainerImagePullResult>> GetImagePullRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerImagePullResult>>([]);
    Task<ContainerImagePullResult?> ReviewImagePullAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromException<ContainerImagePullResult?>(new NotSupportedException());
    bool CanDeleteImages => false;
    Task<MutationResult> DeleteImagesAsync(ContainerImageDeleteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<ContainerImageDeletionRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerImageDeletionRecovery>>([]);
    Task<MutationResult?> ReviewImageDeletionAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());
    bool CanMutateContainers => false;
    Task<MutationResult> MutateContainerAsync(ContainerMutationRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<ContainerMutationRecovery>> GetContainerMutationRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerMutationRecovery>>([]);
    Task<MutationResult?> ReviewContainerMutationAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());
    bool CanBrowseRegistry => false;
    Task<IReadOnlyList<ContainerRegistryImage>> SearchRegistryAsync(string query, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<ContainerRegistryImage>>(new NotSupportedException());
    Task<IReadOnlyList<string>> LoadRegistryTagsAsync(string repository, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<string>>(new NotSupportedException());
    bool CanCreateNetworks => false;
    bool CanDeleteNetworks => false;
    Task<MutationResult> DeleteNetworksAsync(ContainerNetworkDeleteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<ContainerNetworkDeletionRecovery>> GetNetworkDeletionRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerNetworkDeletionRecovery>>([]);
    Task<MutationResult?> ReviewNetworkDeletionAsync(string id, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());
    Task PrepareNetworkManagementAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    Task<MutationResult> CreateNetworkAsync(ContainerNetworkCreateRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult>(new NotSupportedException());
    Task<IReadOnlyList<ContainerNetworkCreationRecovery>> GetNetworkCreationRecoveriesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ContainerNetworkCreationRecovery>>([]);
    Task<MutationResult?> ReviewNetworkCreationAsync(string name, CancellationToken cancellationToken = default) =>
        Task.FromException<MutationResult?>(new NotSupportedException());

    Task<ContainerManagerSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);
}
