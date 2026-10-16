using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendFilesAsync(PhotoFileChangeTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            _ = await PrepareFilesCoreAsync(task.Record, token).ConfigureAwait(false);
            var command = task.Record.Command;
            var fields = Parameters(("item_id", command.Photos.Select(photo => photo.Id.ItemId).ToArray()), ("folder_id", command.Folders.Select(folder => folder.Id).ToArray()));
            if (command.Destination is { } destination)
            {
                Add(fields, Parameters(("target_folder_id", destination.Id), ("action", command.Duplicate == SynologyPhotoFileDuplicate.Skip ? "skip" : "overwrite")));
                if (command.Action == SynologyPhotoFileAction.Move)
                {
                    var info = new JsonObject { ["version"] = 2, ["source_library"] = command.Space == SynologyPhotoSpace.Personal ? "personal_space" : "shared_space" };
                    if (command.Folders.Count > 0) info["source_folder_ids"] = new JsonArray(JsonValue.Create(command.Folders[0].ParentId));
                    fields["extra_info"] = JsonSerializer.Serialize(info.ToJsonString());
                }
            }
            var capability = Capability("BackgroundTask.File", 1, command.Space);
            var method = command.Action switch { SynologyPhotoFileAction.Copy => "copy", SynologyPhotoFileAction.Move => "move", _ => "delete" };
            task.Record = task.Record with { State = SynologyPhotoFileState.Submitting, Failure = null };
            await SaveFileChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFileOwner(task.Record);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, 1, method, fields, token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoFileState.Failed : SynologyPhotoFileState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure };
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted)
            {
                var info = Object(receipt.Data?["task_info"]);
                task.Record = task.Record with { TaskId = Positive(info, "id") };
                await SaveFileChangeAsync(task).ConfigureAwait(false);
                try { task.Record = ReadFileTaskMetadata(task.Record, info); }
                catch (SynologyPhotoException)
                {
                    task.Record = task.Record with { ReceiptConflict = true };
                    await SaveFileChangeAsync(task).ConfigureAwait(false); throw;
                }
            }
            await SaveFileChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFileOwner(task.Record);
            await ReviewFilesCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore();
            task.Record = task.Record with { State = sent ? SynologyPhotoFileState.PendingReview : SynologyPhotoFileState.Failed, Failure = UploadFailure(error) };
            await SaveFileChangeAsync(task).ConfigureAwait(false);
        }
    }
    private PhotoFileChangeRecord ReadFileTaskMetadata(PhotoFileChangeRecord record, JsonObject info)
    {
        if (Positive(info, "id") != record.TaskId) throw Invalid();
        var total = info["total"] is null ? record.Total : Number(info, "total");
        if (total < 0 || record.Command.Folders.Count == 0 && total is not null && total != record.Command.Photos.Count) throw Invalid();
        if (record.Command.Action == SynologyPhotoFileAction.Delete) return record with { Total = total };
        var target = record.Command.Destination!; var rawTarget = OptionalObject(info, "target_folder");
        if (rawTarget is null || total is null) return record with { Total = total };
        if (Positive(rawTarget, "id") != target.Id || Number(rawTarget, "owner_user_id") != (target.Space == SynologyPhotoSpace.Shared ? 0 : _currentUserId)) throw Invalid();
        return record with { Total = total, TargetVerified = true };
    }
    private async Task ReviewFilesCoreAsync(PhotoFileChangeTask task, CancellationToken token)
    {
        CheckFileOwner(task.Record);
        if (task.Record.State is not (SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview) || !task.Record.Accepted || task.Record.TaskId is null || task.Record.ReceiptConflict) return;
        try
        {
            var command = task.Record.Command; var taskId = task.Record.TaskId.Value; var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync(new[] { command.Space, command.Destination?.Space ?? command.Space }.Distinct().ToArray(), token).ConfigureAwait(false);
            if (command.Action != SynologyPhotoFileAction.Delete && (command.Folders.Count > 0 || command.Destination!.Space != command.Space) && !task.Record.TargetVerified)
            {
                var listed = List(await ReadAsync("BackgroundTask.Info", 1, "list_user_task", cancellationToken: token, space: null).ConfigureAwait(false));
                var matches = listed.Where(item => Positive(item, "id") == task.Record.TaskId).ToArray();
                if (matches.Length != 1) return;
                task.Record = ReadFileTaskMetadata(task.Record, matches[0]); await SaveFileChangeAsync(task).ConfigureAwait(false);
                if (!task.Record.TargetVerified) return;
            }
            var statuses = List(await ReadAsync("BackgroundTask.Info", 1, "get_status", Parameters(("id", new[] { taskId })), token, null).ConfigureAwait(false));
            if (statuses.Length != 1 || Positive(statuses[0], "id") != task.Record.TaskId || Text(statuses[0], "status") != "done") return;
            var status = statuses[0];
            var total = command.Folders.Count == 0 ? command.Photos.Count : task.Record.Total;
            if (status["total"] is not null)
            {
                var reported = Number(status, "total");
                if (reported < 0 || total is not null && reported != total) throw Invalid(); total = reported;
            }
            var completion = Number(status, "completion"); var errors = Number(status, "error"); var skip = Number(status, "skip");
            // 已观察的纯照片删除状态可省略 overwrite；目录与传输仍要求明确字段。
            var overwrite = command.Action == SynologyPhotoFileAction.Delete && command.Folders.Count == 0 && status["overwrite"] is null ? 0 : Number(status, "overwrite");
            if (completion < 0 || total is not null && completion > total || errors < 0 || errors > completion || skip < 0 || skip > completion ||
                overwrite < 0 || overwrite > completion || errors > completion - skip || overwrite > completion - errors - skip ||
                command.Duplicate != SynologyPhotoFileDuplicate.Overwrite && overwrite != 0 ||
                command.Action != SynologyPhotoFileAction.Delete && total is null) throw Invalid();
            var counts = total is { } size ? new SynologyPhotoFileCounts(size, completion, errors, skip, overwrite) : null;
            if (errors > 0 || skip > 0 || total is not null && completion < total)
            {
                RequireGeneration(generation, token); CheckFileOwner(task.Record);
                task.Record = task.Record with { State = SynologyPhotoFileState.Partial, Counts = counts, Failure = null };
                await SaveFileChangeAsync(task).ConfigureAwait(false); return;
            }
            if (command.Action == SynologyPhotoFileAction.Delete)
            { if (!await VerifyDeletedFilesAsync(task.Record, token).ConfigureAwait(false)) return; }
            else
            {
                var destination = command.Destination!;
                var current = PhotoFolder(await ReadPhotoFolderAsync(destination.Id, destination.Space, PhotoFolderRight.Upload, token).ConfigureAwait(false), destination.Space);
                if (!SamePhotoFolder(current, destination)) return;
                if (command.Action == SynologyPhotoFileAction.Move && destination.Space == command.Space)
                {
                    foreach (var photo in command.Photos)
                    {
                        var moved = await ReadOriginalFilePhotoAsync(photo, token).ConfigureAwait(false);
                        if (!photo.IsSameDeletionTarget(moved with { FolderId = photo.FolderId }) || moved.FolderId != destination.Id) return;
                    }
                    foreach (var folder in command.Folders)
                    {
                        var moved = PhotoFolder(await ReadPhotoFolderAsync(folder.Id, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
                        if (moved.ParentId != destination.Id || moved.Path != ChildFolderPath(destination.Path, folder.Name)) return;
                    }
                }
            }
            RequireGeneration(generation, token); CheckFileOwner(task.Record);
            task.Record = task.Record with { State = SynologyPhotoFileState.Completed, Counts = counts, Failure = null };
            await SaveFileChangeAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    private async Task<bool> VerifyDeletedFilesAsync(PhotoFileChangeRecord record, CancellationToken token)
    {
        var command = record.Command;
        foreach (var original in record.Parents)
        {
            var parent = PhotoFolder(await ReadPhotoFolderAsync(original.Id, original.Space, PhotoFolderRight.View, token).ConfigureAwait(false), original.Space);
            if (!SamePhotoFolder(original, parent)) return false;
            if (!command.Folders.Any(folder => folder.ParentId == parent.Id)) continue;
            var ids = new HashSet<long>(); var offset = 0;
            while (true)
            {
                var page = await FoldersAsync(parent.Id, offset, 100, token, parent.Space).ConfigureAwait(false);
                foreach (var folder in page)
                    if (folder.ParentId != parent.Id || !ids.Add(folder.Id) || folder.Path is null || folder.Path != ChildFolderPath(parent.Path, folder.Name)) throw Invalid();
                offset = checked(offset + page.Count); if (page.Count < 100) break;
            }
            if (command.Folders.Any(folder => folder.ParentId == parent.Id && ids.Contains(folder.Id))) return false;
        }
        foreach (var photo in command.Photos)
        {
            var entries = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { photo.Id.ItemId })), token, command.Space).ConfigureAwait(false));
            if (entries.Length != 0) return false;
        }
        return true;
    }
}
