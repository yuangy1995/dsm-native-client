namespace LanStash.Domain;

public interface IFileBackgroundTaskRepository
{
    Guid ProfileId { get; }
    bool IsAvailable { get; }

    Task<FileBackgroundTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default);
}
