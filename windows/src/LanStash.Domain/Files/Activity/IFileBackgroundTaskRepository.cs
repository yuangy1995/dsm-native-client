namespace LanStash.Domain;

public interface IFileBackgroundTaskRepository
{
    Guid ProfileId { get; }
    bool IsAvailable { get; }

    Task<FileBackgroundTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default);

    bool CanControlTask(FileBackgroundTaskSummary task, FileBackgroundTaskAction action) => false;
    Task<FileBackgroundTaskProgress> ControlTaskAsync(FileBackgroundTaskChange change, CancellationToken token = default) =>
        Task.FromException<FileBackgroundTaskProgress>(new NotSupportedException());
    Task<IReadOnlyList<FileBackgroundTaskProgress>> GetTaskOperationsAsync(CancellationToken token = default) =>
        Task.FromResult<IReadOnlyList<FileBackgroundTaskProgress>>([]);
    Task<FileBackgroundTaskProgress?> ReviewTaskAsync(Guid requestId, CancellationToken token = default) =>
        Task.FromResult<FileBackgroundTaskProgress?>(null);
}
