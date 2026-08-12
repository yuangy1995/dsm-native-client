namespace LanStash.Domain;

public interface IFileLocationsRepository
{
    Guid ProfileId { get; }
    FileLocationsAvailability Availability { get; }

    Task<FileLocationsSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);

    /// <summary>
    /// 当前会话是否支持添加和移除收藏项。
    /// 由 <c>SYNO.FileStation.Favorite</c> 能力发现结果控制。
    /// </summary>
    bool CanWriteFavorites { get; }

    Task<MutationResult> AddFavoriteAsync(
        string path,
        string? name = null,
        CancellationToken cancellationToken = default);

    Task<MutationResult> RemoveFavoriteAsync(
        string path,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// 当前会话是否允许创建、编辑或删除远程挂载。
    /// 由 <c>SYNO.FileStation.Mount</c> 能力发现结果控制。
    /// </summary>
    bool AllowsRemoteMountManagement { get; }

    Task<MutationResult> CreateRemoteMountAsync(
        RemoteMountDraft draft,
        CancellationToken cancellationToken = default);

    Task<MutationResult> UpdateRemoteMountAsync(
        RemoteMountDraft draft,
        CancellationToken cancellationToken = default);

    Task<MutationResult> DeleteRemoteMountAsync(
        string mountPoint,
        CancellationToken cancellationToken = default);
}
