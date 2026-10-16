using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    // 内部接口统一使用 Foto；共享目标不改变后台任务路由。
    public async Task<IReadOnlyList<SynologyPhotoBackgroundTask>> BackgroundTasksAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var user = await ReadAsync("UserInfo", 1, "me", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        var userId = Positive(user, "id");
        if (!Boolean(user, "enabled") || userId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var raw = List(await ReadAsync("BackgroundTask.Info", 1, "list_user_task", cancellationToken: cancellationToken, space: null).ConfigureAwait(false));
        var values = raw.Select(value =>
        {
            var target = OptionalObject(value, "target_folder");
            var result = new SynologyPhotoBackgroundTask(ProfileId, userId, Positive(value, "id"), Text(value, "operation"),
                Text(value, "status") switch { "waiting" => SynologyPhotoBackgroundStatus.Waiting, "processing" => SynologyPhotoBackgroundStatus.Processing,
                    "aborting" => SynologyPhotoBackgroundStatus.Aborting, "done" => SynologyPhotoBackgroundStatus.Done, _ => SynologyPhotoBackgroundStatus.Unknown },
                Number(value, "total"), Number(value, "completion"), Number(value, "error"), Number(value, "skip"), Number(value, "overwrite"), Decimal(value, "create_time"),
                target is null ? null : Positive(target, "id"), target is null ? null : Number(target, "owner_user_id"));
            ValidateBackgroundTask(result); return result;
        }).ToArray();
        if (values.Select(value => value.Id).Distinct().Count() != values.Length) throw Invalid();
        RequireGeneration(generation, cancellationToken); return values;
    }
    private static void ValidateBackgroundTask(SynologyPhotoBackgroundTask task)
    {
        if (task is null || task.ProfileId == Guid.Empty || task.UserId <= 0 || task.Id <= 0 || task.Operation is null || !Enum.IsDefined(task.Status) ||
            task.Total < 0 || task.Completion < 0 || task.Completion > task.Total || task.Errors < 0 || task.Errors > task.Completion ||
            task.Skipped < 0 || task.Skipped > task.Total || task.Overwritten < 0 || task.Overwritten > task.Total ||
            !double.IsFinite(task.CreatedAt) || task.CreatedAt < 0 || task.TargetFolderId <= 0 || task.TargetOwnerId < 0 ||
            (task.TargetFolderId is null) != (task.TargetOwnerId is null)) throw Invalid();
    }
    private async Task<SynologyPhotoBackgroundTask> CurrentBackgroundTaskAsync(SynologyPhotoBackgroundTask original, CancellationToken token)
    {
        ValidateBackgroundTask(original);
        if (original.ProfileId != ProfileId || original.UserId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var current = (await BackgroundTasksAsync(token).ConfigureAwait(false)).SingleOrDefault(value => value.Id == original.Id);
        if (current is null || !current.SameIdentity(original)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return current;
    }
    public async Task<IReadOnlyList<SynologyPhotoBackgroundError>> BackgroundTaskErrorsAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var current = await CurrentBackgroundTaskAsync(task, cancellationToken).ConfigureAwait(false);
        if (current.Errors == 0) return [];
        var raw = List(await ReadAsync("BackgroundTask.Info", 1, "get_error_detail", Parameters(("id", task.Id)), cancellationToken, null).ConfigureAwait(false));
        var values = raw.Select(value => new SynologyPhotoBackgroundError(Text(value, "type") switch
            { "item" => SynologyPhotoBackgroundErrorKind.Item, "folder" => SynologyPhotoBackgroundErrorKind.Folder, _ => SynologyPhotoBackgroundErrorKind.Unknown },
            Positive(value, "id"), Text(value, "reason") switch
            { "quota_full" => SynologyPhotoBackgroundErrorReason.Quota, "space_full" => SynologyPhotoBackgroundErrorReason.Space, "skipped" => SynologyPhotoBackgroundErrorReason.Subfolder,
                "not_existed" => SynologyPhotoBackgroundErrorReason.Missing, "target_not_existed" => SynologyPhotoBackgroundErrorReason.TargetMissing,
                "excluded_extension" => SynologyPhotoBackgroundErrorReason.Excluded, _ => SynologyPhotoBackgroundErrorReason.Unknown })).ToArray();
        if (values.Select(value => (value.Kind, value.ItemId)).Distinct().Count() != values.Length) throw Invalid();
        RequireGeneration(generation, cancellationToken);
        // 名称只补充当前任务的目标来源；缺少访问权不妨碍显示已有错误原因。
        if (current.TargetSpace is not { } space) return values;
        try { RequireAccess(space); await FreshManagementAccessAsync([space], cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) when (ManagementError(error)) { RequireGeneration(generation, cancellationToken); return values; }
        var names = new Dictionary<(SynologyPhotoBackgroundErrorKind, long), (string Name, string? Path)>();
        foreach (var ids in values.Where(value => value.Kind == SynologyPhotoBackgroundErrorKind.Item).Select(value => value.ItemId).Chunk(100))
        {
            RequireGeneration(generation, cancellationToken);
            try
            {
                var items = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", ids), ("additional", new[] { "folder" })), cancellationToken, space).ConfigureAwait(false));
                var parsed = items.Select(item => (Id: Positive(item, "id"), Name: Text(item, "filename"), Path: OptionalObject(item, "additional") is { } details ? OptionalText(details, "folder") : null)).ToArray();
                if (parsed.Select(item => item.Id).Distinct().Count() != parsed.Length || parsed.Any(item => !ids.Contains(item.Id))) throw Invalid();
                foreach (var item in parsed) names[(SynologyPhotoBackgroundErrorKind.Item, item.Id)] = (item.Name, item.Path);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (ManagementError(error)) { /* 缺失原件或名称读取失败时保留原因。 */ }
        }
        foreach (var entry in values.Where(value => value.Kind == SynologyPhotoBackgroundErrorKind.Folder))
        {
            RequireGeneration(generation, cancellationToken);
            try
            {
                var folder = PhotoFolder(await ReadPhotoFolderAsync(entry.ItemId, space, PhotoFolderRight.View, cancellationToken).ConfigureAwait(false), space);
                names[(entry.Kind, entry.ItemId)] = (folder.Name, folder.Path[..Math.Max(1, folder.Path.LastIndexOf('/'))]);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (ManagementError(error)) { /* 目录不可读时仍保留原因。 */ }
        }
        RequireGeneration(generation, cancellationToken);
        return values.Select(value => names.TryGetValue((value.Kind, value.ItemId), out var name) ? value with { Name = name.Name, FolderPath = name.Path } : value).ToArray();
    }
    public async Task<IReadOnlyList<SynologyPhotoFolder>> BackgroundTaskLocationAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); var current = await CurrentBackgroundTaskAsync(task, cancellationToken).ConfigureAwait(false);
        if (current.TargetSpace is not { } space || current.TargetFolderId is not { } id) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        await FreshManagementAccessAsync([space], cancellationToken).ConfigureAwait(false);
        var visited = new HashSet<long>(); var chain = new List<SynologyPhotoFolder>();
        while (true)
        {
            if (id <= 0 || !visited.Add(id)) throw Invalid();
            var folder = PhotoFolder(await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, cancellationToken).ConfigureAwait(false), space);
            if (chain.LastOrDefault() is { } child && (child.ParentId != folder.Id || ChildFolderPath(folder.Path, child.Name) != child.Path)) throw Invalid();
            chain.Add(folder); if (folder.IsRoot) break; id = folder.ParentId;
        }
        _ = await CurrentBackgroundTaskAsync(task, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken); chain.Reverse(); return chain;
    }
}
