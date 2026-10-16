using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendAlbumChangeAsync(PhotoAlbumChangeTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            var rights = await PrepareAlbumCoreAsync(task.Record, token, task.Condition).ConfigureAwait(false);
            var edit = task.Record.Edit; var members = task.Record.Members;
            if (AlbumMembership(edit.Kind))
            {
                var present = await AlbumMemberMatchesAsync(edit.Album!.Id, edit.Photos, token).ConfigureAwait(false);
                members = members.Select((item, index) => item.State == SynologyPhotoChangeState.Completed || present[index] == (edit.Kind == SynologyPhotoAlbumEditKind.AddMembers)
                    ? item with { State = SynologyPhotoChangeState.Completed } : item).ToArray();
            }
            if (AlbumMembership(edit.Kind) && members.All(item => item.State == SynologyPhotoChangeState.Completed) ||
                edit.Kind == SynologyPhotoAlbumEditKind.Rename && PhotoTextHash(edit.Album!.Name) == task.Record.NameHash ||
                edit.Kind == SynologyPhotoAlbumEditKind.Sort && edit.Sort == edit.Album!.Sort ||
                edit.Kind == SynologyPhotoAlbumEditKind.ListSort && edit.ListSort == edit.OriginalListSort ||
                edit.Kind == SynologyPhotoAlbumEditKind.ListDisplay && edit.Display == edit.OriginalDisplay)
            {
                task.Record = task.Record with { State = SynologyPhotoChangeState.Completed, Members = members, Failure = null };
                task.Result = edit.Album; await SaveAlbumChangeAsync(task).ConfigureAwait(false); return;
            }
            var ids = members.Where(item => item.State != SynologyPhotoChangeState.Completed).Select(item => item.Photo.Id.ItemId).ToArray();
            var fields = edit.Kind switch
            {
                SynologyPhotoAlbumEditKind.Create => Parameters(("name", task.Name!), ("item", ids)),
                SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild => Parameters(("name", task.Name!), ("condition", ConditionParameters(task.Condition!))),
                SynologyPhotoAlbumEditKind.Condition => Parameters(("id", edit.Album!.Id), ("condition", ConditionParameters(task.Condition!))),
                SynologyPhotoAlbumEditKind.Unfreeze => Parameters(("id", edit.Album!.Id)),
                SynologyPhotoAlbumEditKind.Rename => Parameters(("id", edit.Album!.Id), ("name", task.Name!)),
                SynologyPhotoAlbumEditKind.Delete => Parameters(("id", new[] { edit.Album!.Id })),
                SynologyPhotoAlbumEditKind.Cover => Parameters(("id", edit.Album!.Id), ("id_item", edit.Photos[0].Id.ItemId)),
                SynologyPhotoAlbumEditKind.Sort => Parameters(("id", edit.Album!.Id), ("sort_by", SortField(edit.Sort!.Field)), ("sort_direction", edit.Sort.Descending ? "desc" : "asc")),
                SynologyPhotoAlbumEditKind.ListSort => Parameters((AlbumScope(edit.Scope) + "_sort_by", AlbumListField(edit.ListSort!.Field)), (AlbumScope(edit.Scope) + "_sort_direction", edit.ListSort.Descending ? "desc" : "asc")),
                SynologyPhotoAlbumEditKind.ListDisplay => Parameters(("album_display_type", edit.Display == SynologyPhotoAlbumDisplay.All ? "all_album" : "my_album")),
                _ => Parameters(("item", ids)),
            };
            if (AlbumMembership(edit.Kind)) Add(fields, rights!.Passphrase is { } passphrase ? Parameters(("passphrase", passphrase)) : Parameters(("id", edit.Album!.Id)));
            var route = AlbumWriteRoute(edit.Kind); var capability = Capability(route.Api, route.Version, null);
            task.Record = task.Record with { State = SynologyPhotoChangeState.Submitting, Accepted = false, MemberFailures = false, Failure = null,
                Members = members.Select(item => item.State == SynologyPhotoChangeState.Completed ? item : item with { State = SynologyPhotoChangeState.Submitting }).ToArray() };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckAlbumOwner(task.Record);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, route.Version, route.Method, fields, token).ConfigureAwait(false);
            var state = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview;
            task.Record = task.Record with { State = state, Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure,
                Members = task.Record.Members.Select(item => item.State == SynologyPhotoChangeState.Completed ? item : item with { State = state }).ToArray() };
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted)
            {
                if (AlbumCreates(edit.Kind)) task.Record = task.Record with { CreatedId = Positive(Object(receipt.Data?["album"]), "id") };
                if (AlbumMembership(edit.Kind) && receipt.Data?["error_list"] is { } errors)
                {
                    if (errors is not JsonArray list || list.Count > ids.Length) throw Invalid();
                    task.Record = task.Record with { MemberFailures = list.Count > 0 };
                }
            }
            await SaveAlbumChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckAlbumOwner(task.Record);
            await ReviewAlbumCoreAsync(task, token).ConfigureAwait(false);
            if (task.Record.ReplacementVerified && AlbumCanContinue(task)) await SendFrozenCleanupAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); var state = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed;
            task.Record = task.Record with { State = state, Failure = UploadFailure(error), Members = task.Record.Members.Select(item =>
                item.State == SynologyPhotoChangeState.Completed ? item : item with { State = state }).ToArray() };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewAlbumCoreAsync(PhotoAlbumChangeTask task, CancellationToken token)
    {
        CheckAlbumOwner(task.Record);
        if (task.Record.Edit.Kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Unfreeze or SynologyPhotoAlbumEditKind.Rebuild)
        { await ReviewConditionAlbumAsync(task, token).ConfigureAwait(false); return; }
        if (task.Record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting)) return;
        // 相册写全部要求本次回执，外部客户端产生的同名、成员或消失不能代替本次提交证据。
        if (!task.Record.Accepted) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await FreshManagementAccessAsync([], token).ConfigureAwait(false);
            var edit = task.Record.Edit; var matches = false; SynologyPhotoAlbum? album = null;
            if (edit.Kind == SynologyPhotoAlbumEditKind.ListSort) matches = await AlbumListSortAsync(edit.Scope, token).ConfigureAwait(false) == edit.ListSort;
            else if (edit.Kind == SynologyPhotoAlbumEditKind.ListDisplay) matches = await AlbumDisplayAsync(token).ConfigureAwait(false) == edit.Display;
            else
            {
                var id = edit.Kind == SynologyPhotoAlbumEditKind.Create ? task.Record.CreatedId : edit.Album?.Id;
                if (id is null) return;
                var raw = await ReadAlbumRawAsync(id.Value, token).ConfigureAwait(false);
                if (edit.Kind == SynologyPhotoAlbumEditKind.Delete) matches = raw is null;
                else
                {
                    if (raw is null) return; album = AlbumSnapshot(raw);
                    if (edit.Kind == SynologyPhotoAlbumEditKind.Create)
                    {
                        if (!album.IsOwner || album.Conditional || album.Frozen || album.Shared != false || PhotoTextHash(album.Name) != task.Record.NameHash) return;
                        matches = (await AlbumMemberMatchesAsync(album.Id, edit.Photos, token, exact: true).ConfigureAwait(false)).All(value => value);
                        if (album.ItemCount is { } count && count != edit.Photos.Count) matches = false;
                    }
                    else
                    {
                        var original = edit.Album!;
                        if (album.OwnerUserId != original.OwnerUserId || album.CurrentUserId != original.CurrentUserId || album.Conditional != original.Conditional || album.Frozen != original.Frozen) return;
                        switch (edit.Kind)
                        {
                            case SynologyPhotoAlbumEditKind.Rename: matches = PhotoTextHash(album.Name) == task.Record.NameHash; break;
                            case SynologyPhotoAlbumEditKind.Sort: matches = ExplicitFolderSort(raw) == edit.Sort; break;
                            case SynologyPhotoAlbumEditKind.Cover: matches = album.CoverId == edit.Photos[0].Id.ItemId; break;
                            case SynologyPhotoAlbumEditKind.AddMembers or SynologyPhotoAlbumEditKind.RemoveMembers:
                                var members = await AlbumMemberMatchesAsync(album.Id, edit.Photos, token).ConfigureAwait(false);
                                var results = task.Record.Members.Select((item, index) => item.State == SynologyPhotoChangeState.Completed ? item : item with
                                { State = members[index] == (edit.Kind == SynologyPhotoAlbumEditKind.AddMembers) ? SynologyPhotoChangeState.Completed :
                                    task.Record.MemberFailures ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview }).ToArray();
                                RequireGeneration(generation, token); CheckAlbumOwner(task.Record);
                                task.Record = task.Record with { Members = results };
                                if (results.Any(item => item.State == SynologyPhotoChangeState.PendingReview)) { await SaveAlbumChangeAsync(task).ConfigureAwait(false); return; }
                                if (results.Any(item => item.State == SynologyPhotoChangeState.Failed))
                                { task.Record = task.Record with { State = SynologyPhotoChangeState.Failed, Failure = SynologyPhotoFailure.WriteFailed }; await SaveAlbumChangeAsync(task).ConfigureAwait(false); return; }
                                matches = true; break;
                        }
                    }
                }
            }
            RequireGeneration(generation, token); CheckAlbumOwner(task.Record); if (!matches) return;
            task.Result = album; task.Record = task.Record with { State = SynologyPhotoChangeState.Completed, Failure = null,
                Members = task.Record.Members.Select(item => item with { State = SynologyPhotoChangeState.Completed }).ToArray() };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
