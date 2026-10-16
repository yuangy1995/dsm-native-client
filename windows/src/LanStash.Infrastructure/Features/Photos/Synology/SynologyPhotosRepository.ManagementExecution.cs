using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<SynologyPhotoChange> ContinueChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ChangeSnapshot(task);
        var ownerGate = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var ownsOwner = false;
        task.Running = true; task.Stop = false;
        try
        {
            await ownerGate.WaitAsync(cancellationToken).ConfigureAwait(false); ownsOwner = true;
            CheckChangeOwner(task.Record); await ReviewChangeCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (!UnresolvedChange(task) && task.Record.Kind == SynologyPhotoEditKind.CreateTag)
            {
                if (task.Record.CreatedTagId is null && task.Record.TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
                    await CreateManagementTagAsync(task, cancellationToken).ConfigureAwait(false);
            }
            var canRun = !UnresolvedChange(task) && (task.Record.Kind != SynologyPhotoEditKind.CreateTag || task.Record.TagState == SynologyPhotoChangeState.Completed) &&
                (task.Record.Kind != SynologyPhotoEditKind.Description || task.Text is not null);
            if (canRun && task.Record.Kind == SynologyPhotoEditKind.CreateTag && task.Record.Items.Any(item => item.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed))
            {
                try
                {
                    var tag = await ReadManagementTagAsync(task.Record.CreatedTagId!.Value, task.Record.Space, cancellationToken).ConfigureAwait(false);
                    if (tag is null || PhotoTextHash(tag.Name) != task.Record.TextHash) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    task.Text = tag.Name;
                }
                catch (Exception error) when (ManagementError(error))
                {
                    RequireManagementStore(); canRun = false;
                    for (var index = 0; index < task.Record.Items.Length; index++)
                        if (task.Record.Items[index].State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
                            await SetChangeEntryAsync(task, index, task.Record.Items[index] with { State = SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) }).ConfigureAwait(false);
                }
            }
            for (var index = 0; canRun && index < task.Record.Items.Length && !task.Stop; index++)
            {
                if (task.Record.Items[index].State is not (SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)) continue;
                await SendChangeEntryAsync(task, index, cancellationToken).ConfigureAwait(false);
                if (task.Record.Items[index].State != SynologyPhotoChangeState.Completed) break;
            }
        }
        finally
        { task.Running = false; if (ownsOwner) ownerGate.Release(); task.Gate.Release(); }
        return ChangeSnapshot(task);
    }
    private async Task CreateManagementTagAsync(PhotoChangeTask task, CancellationToken token)
    {
        if (task.Text is null) return;
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            await PrepareChangeRecordAsync(task.Record, token).ConfigureAwait(false);
            var capability = Capability("Browse.GeneralTag", 1, task.Record.Space);
            task.Record = task.Record with { TagState = SynologyPhotoChangeState.Submitting };
            await SaveChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckChangeOwner(task.Record);
            if (task.Stop) { task.Record = task.Record with { TagState = SynologyPhotoChangeState.Ready }; await SaveChangeAsync(task).ConfigureAwait(false); return; }
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, 1, "create", Parameters(("name", task.Text)), token).ConfigureAwait(false);
            task.Record = task.Record with { TagState = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview };
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted)
            {
                var tag = Object(receipt.Data?["tag"]);
                if (PhotoTextHash(Text(tag, "name")) != task.Record.TextHash) throw Invalid();
                task.Record = task.Record with { CreatedTagId = Positive(tag, "id") };
            }
            await SaveChangeAsync(task).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckChangeOwner(task.Record);
            await ReviewChangeCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore();
            task.Record = task.Record with { TagState = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed };
            await SaveChangeAsync(task).ConfigureAwait(false);
        }
    }
    private async Task SendChangeEntryAsync(PhotoChangeTask task, int index, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); CheckChangeOwner(task.Record);
            await FreshManagementAccessAsync(task.Record, token).ConfigureAwait(false);
            var entry = task.Record.Items[index];
            var current = await EditablePhotoAsync(entry, task.Record.Kind, token).ConfigureAwait(false);
            if (current.AlbumContext is { } context && task.Record.Items.Select(item => item.Original.Id.Space).Distinct().Count() > 1)
            {
                var album = await ManagementAlbumAsync(context.AlbumId, token).ConfigureAwait(false);
                if (Positive(album, "owner_user_id") != _currentUserId && context.ProviderUserId != _currentUserId)
                    throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            }
            // 重试只处理原快照对应的剩余目标；目标值已经一致时不产生写请求。
            if (ChangeMatches(task.Record, entry, current, accepted: false))
            { task.Updated[current.Id] = current; await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Completed, Failure = null }).ConfigureAwait(false); return; }
            var tags = task.Record.Kind is SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags or SynologyPhotoEditKind.CreateTag;
            var version = tags ? 1 : 2; var method = tags ? task.Record.Kind == SynologyPhotoEditKind.RemoveTags ? "remove_tag" : "add_tag" : "set";
            var parameters = Parameters(("id", new[] { entry.Original.Id.ItemId }));
            Add(parameters, task.Record.Kind switch
            {
                SynologyPhotoEditKind.Description => Parameters(("description", task.Text!)),
                SynologyPhotoEditKind.Rating => Parameters(("rating", entry.ExpectedValue!.Value)),
                SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates => Parameters(("time", entry.ExpectedValue!.Value)),
                SynologyPhotoEditKind.Rotate => Parameters(("rotate_action", "counter_clockwise")),
                SynologyPhotoEditKind.CreateTag => Parameters(("tag", new[] { task.Record.CreatedTagId!.Value })),
                _ => Parameters(("tag", task.Record.TagIds)),
            });
            var capability = Capability("Browse.Item", version, entry.Original.Id.Space);
            await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Submitting, Accepted = false, ReportedFailure = false, Failure = null }).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckChangeOwner(task.Record);
            if (task.Stop) { await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Ready }).ConfigureAwait(false); return; }
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, version, method, parameters, token).ConfigureAwait(false);
            if (receipt.Status == SynologyPhotoWriteStatus.Rejected)
            {
                await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Failed, Failure = receipt.Failure ?? SynologyPhotoFailure.WriteFailed }).ConfigureAwait(false);
                return;
            }
            var errorCount = 0;
            if (receipt.Data?["error_list"] is { } errors)
            {
                if (errors is not JsonArray values || values.Count > 1) throw Invalid();
                errorCount = values.Count;
            }
            await SetChangeEntryAsync(task, index, entry with
            {
                State = task.Record.Kind == SynologyPhotoEditKind.Rotate && errorCount > 0 ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, ReportedFailure = errorCount > 0,
                Failure = errorCount > 0 ? SynologyPhotoFailure.WriteFailed : null,
            }).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckChangeOwner(task.Record);
            await ReviewChangeEntryAsync(task, index, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); var entry = task.Record.Items[index];
            await SetChangeEntryAsync(task, index, entry with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) }).ConfigureAwait(false);
        }
    }
    public async Task<SynologyPhotoChange> ReviewChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedChange(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ChangeSnapshot(task);
        try { await ReviewChangeCoreAsync(task, cancellationToken).ConfigureAwait(false); return ChangeSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    private async Task ReviewChangeCoreAsync(PhotoChangeTask task, CancellationToken token)
    {
        CheckChangeOwner(task.Record);
        if (task.Record.Kind == SynologyPhotoEditKind.CreateTag && task.Record.CreatedTagId is { } id &&
            task.Record.TagState is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)
        {
            try
            {
                var found = await ReadManagementTagAsync(id, task.Record.Space, token).ConfigureAwait(false);
                if (found is not null && PhotoTextHash(found.Name) == task.Record.TextHash)
                {
                    task.Text ??= found.Name; task.Record = task.Record with { TagState = SynologyPhotoChangeState.Completed };
                    await SaveChangeAsync(task).ConfigureAwait(false);
                }
                else
                {
                    task.Record = task.Record with { TagState = SynologyPhotoChangeState.PendingReview };
                    await SaveChangeAsync(task).ConfigureAwait(false);
                }
            }
            catch (Exception error) when (ManagementError(error))
            {
                RequireManagementStore(); task.Record = task.Record with { TagState = SynologyPhotoChangeState.PendingReview };
                await SaveChangeAsync(task).ConfigureAwait(false);
            }
        }
        for (var index = 0; index < task.Record.Items.Length; index++)
        {
            try { await ReviewChangeEntryAsync(task, index, token).ConfigureAwait(false); }
            catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
        }
    }
    private async Task<SynologyPhotoChoice?> ReadManagementTagAsync(long id, SynologyPhotoSpace space, CancellationToken token)
    {
        var seen = new HashSet<long>();
        for (var offset = 0; ; offset = checked(offset + 500))
        {
            var rows = await TagsAsync(space, offset, 500, token).ConfigureAwait(false);
            if (rows.Any(row => !seen.Add(row.Id))) throw Invalid();
            if (rows.FirstOrDefault(row => row.Id == id) is { } found) return found;
            if (rows.Count < 500) return null;
        }
    }
    private async Task ReviewChangeEntryAsync(PhotoChangeTask task, int index, CancellationToken token)
    {
        var entry = task.Record.Items[index];
        if (entry.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting)) return;
        var generation = Volatile.Read(ref _accessGeneration); CheckChangeOwner(task.Record);
        var photo = await DetailsAsync(entry.Original, token).ConfigureAwait(false); var original = entry.Original;
        if (photo.Id != original.Id || photo.Filename != original.Filename || photo.SizeBytes != original.SizeBytes ||
            photo.FolderId != original.FolderId || photo.IndexedAt != original.IndexedAt || photo.MediaType != original.MediaType ||
            photo.AlbumContext != original.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        RequireGeneration(generation, token); CheckChangeOwner(task.Record);
        if (ChangeMatches(task.Record, entry, photo, entry.Accepted))
        {
            task.Updated[photo.Id] = photo;
            await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Completed, Failure = null }).ConfigureAwait(false);
        }
        else if (entry.ReportedFailure) await SetChangeEntryAsync(task, index, entry with { State = SynologyPhotoChangeState.Failed, Failure = SynologyPhotoFailure.WriteFailed }).ConfigureAwait(false);
    }
    private static bool ChangeMatches(PhotoChangeRecord record, PhotoChangeEntry entry, SynologyPhoto current, bool accepted)
    {
        var tags = current.Tags?.Select(tag => tag.Id).ToHashSet();
        return record.Kind switch
        {
            SynologyPhotoEditKind.Description => current.Description is not null && PhotoTextHash(current.Description) == record.TextHash,
            SynologyPhotoEditKind.Rating => current.Rating == entry.ExpectedValue,
            SynologyPhotoEditKind.Date or SynologyPhotoEditKind.ShiftDates => current.TakenAt.ToUnixTimeSeconds() == entry.ExpectedValue,
            SynologyPhotoEditKind.AddTags => tags is not null && record.TagIds.All(tags.Contains),
            SynologyPhotoEditKind.RemoveTags => tags is not null && record.TagIds.All(id => !tags.Contains(id)),
            SynologyPhotoEditKind.CreateTag => record.CreatedTagId is { } id && tags?.Contains(id) == true,
            SynologyPhotoEditKind.Rotate => current.Orientation == entry.ExpectedValue &&
                ((entry.Original.Width is null || current.Height == entry.Original.Width) && (entry.Original.Height is null || current.Width == entry.Original.Height) ||
                 accepted && current.Width == entry.Original.Width && current.Height == entry.Original.Height),
            _ => false,
        };
    }
    private static bool ManagementError(Exception error) => error is SynologyPhotoException or DsmException or IOException or
        UnauthorizedAccessException or HttpRequestException or OperationCanceledException or ObjectDisposedException;
}
