namespace LanStash.Domain;

public interface IFileMutationRepository
{
    Guid ProfileId { get; }
    FileMutationAvailability FileMutationAvailability { get; }
    Task<FileMutationOutcome> CreateFolderAsync(
        CreateFolderRequest request,
        CancellationToken cancellationToken = default);
    Task<FileMutationOutcome> RenameAsync(
        RenameFileItemRequest request,
        CancellationToken cancellationToken = default);
}
