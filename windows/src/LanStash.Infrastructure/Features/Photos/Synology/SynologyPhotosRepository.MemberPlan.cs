using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoMemberGrant(SynologyPhotoShareIdentity Id, string NameHash, string Role, bool Backup, bool Protected);
    private sealed record PhotoMembersPlan(long AdministratorId, PhotoMemberGrant[] Before, PhotoMemberGrant[] After, SynologyPhotoMemberFolderEdit[] Edits);
    private sealed record PhotoMembersRecord(PhotoMembersPlan Plan, SynologyPhotoWriteStatus[] Facts, bool Changed = false);
    private sealed record PhotoMemberStep(int Edit, bool Batch, string Endpoint, string Method, Dictionary<string,string> Parameters);
    private static PhotoMemberGrant MemberGrant(SynologyPhotoSharedMember member) => new(member.Id, PhotoTextHash(member.Recipient.Name), member.Role, member.AutoBackup, member.Protected);
    private static PhotoMemberGrant[] MemberGrants(IEnumerable<SynologyPhotoSharedMember> members) => members.Select(MemberGrant)
        .OrderBy(x => x.Id.Type, StringComparer.Ordinal).ThenBy(x => x.Id.Numeric).ThenBy(x => x.Id.Value, StringComparer.Ordinal).ToArray();
    private static SynologyPhotoMemberFolderEdit MinimalMemberEdit(SynologyPhotoMemberFolderEdit edit) => edit with
    { Original = edit.Original.OrderBy(x => x.Id).Select(x => x with { Name = "" }).ToArray(), Changes = (edit.Changes ?? []).OrderBy(x => x.FolderId).ToArray() };
    private static bool SameMembersPlan(PhotoMembersRecord? a, PhotoMembersRecord? b) => a is null ? b is null : b is not null && JsonSerializer.Serialize(a.Plan) == JsonSerializer.Serialize(b.Plan);
    public async Task<SynologyPhotoSettingsChange> SetSharedMembersAsync(Guid operationId, SynologyPhotoSharedMembers original, IReadOnlyList<SynologyPhotoSharedMember> members,
        IReadOnlyList<SynologyPhotoMemberFolderEdit> edits, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (!SettingsSafety.SharedMembers) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (original.ProfileId != ProfileId || !original.Enabled) throw Invalid();
        var candidates = members.Any(x => !original.Members.Any(y => y.Id == x.Id)) ? await SharedMemberCandidatesAsync(cancellationToken).ConfigureAwait(false) : [];
        if (!original.CanSave(members, candidates, edits.Count > 0)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var plan = new PhotoMembersPlan(original.AdministratorId, MemberGrants(original.Members), MemberGrants(members),
            edits.OrderBy(x => x.Member.Type, StringComparer.Ordinal).ThenBy(x => x.Member.Numeric).ThenBy(x => x.Member.Value, StringComparer.Ordinal).Select(MinimalMemberEdit).ToArray());
        return await SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Members: new(plan, [])), cancellationToken).ConfigureAwait(false);
    }
    private static JsonObject MemberIdentity(SynologyPhotoShareIdentity id) => new() { ["type"] = id.Type, ["id"] = ShareIdentityValue(id) };
    private static IReadOnlyList<PhotoMemberStep> MemberSteps(PhotoMembersPlan plan)
    {
        var result = new List<PhotoMemberStep>(); var list = new JsonArray();
        foreach (var (member, action) in plan.Before.Where(x => !plan.After.Any(y => y.Id == x.Id)).Select(x => (x, "delete"))
            .Concat(plan.After.Where(x => !plan.Before.Contains(x)).Select(x => (x, "update"))))
        {
            var value = MemberIdentity(member.Id); value["permission"] = member.Role; value["auto_backup"] = member.Backup; value["action"] = action; list.Add(value);
        }
        if (list.Count > 0) result.Add(new(-1, false, "Setting.TeamSpace", "update_permission", new() { ["list"] = list.ToJsonString() }));
        for (var index = 0; index < plan.Edits.Length; index++)
        {
            var edit = plan.Edits[index];
            if (edit.Batch is { } batch)
            {
                var permission = new JsonObject { ["member"] = MemberIdentity(edit.Member), ["role"] = SynologyPhotoMemberFolder.RoleText(batch.Role), ["action"] = batch.Grant ? "check_all" : "uncheck_all" };
                result.Add(new(index, true, "Sharing.FolderBatchPermission", "update_all_by_member", new() { ["permission"] = permission.ToJsonString() }));
            }
            if (edit.Changes is { Count: > 0 } changes)
            {
                var permission = MemberIdentity(edit.Member); var items = new JsonArray();
                foreach (var change in changes)
                {
                    var value = new JsonObject { ["folder_id"] = change.FolderId, ["action"] = change.Role is null ? "delete" : "update" };
                    if (change.Role is { } role) value["role"] = SynologyPhotoMemberFolder.RoleText(role); items.Add(value);
                }
                permission["list"] = items;
                result.Add(new(index, false, "Sharing.FolderBatchPermission", "update_by_member", new() { ["permission"] = permission.ToJsonString() }));
            }
        }
        return result;
    }
    private static void ValidateMembersRecord(PhotoSettingsRecord record)
    {
        if (record.Members is not { Plan: var plan, Facts: var facts }) return;
        if (plan is null || plan.AdministratorId <= 0 || plan.Before is null || plan.After is null || plan.Edits is null || facts is null) throw Invalid();
        foreach (var list in new[] { plan.Before, plan.After })
        {
            if (list.DistinctBy(x => x.Id).Count() != list.Length) throw Invalid();
            foreach (var grant in list) { _ = ShareIdentityValue(grant.Id); if (!UploadHash(grant.NameHash) || string.IsNullOrEmpty(grant.Role)) throw Invalid(); }
        }
        foreach (var before in plan.Before)
        {
            var after = plan.After.FirstOrDefault(x => x.Id == before.Id);
            if ((before.Protected || before.Role is not ("entry" or "management")) && after != before) throw Invalid();
            if (after is not null && (before.NameHash != after.NameHash || before.Protected != after.Protected)) throw Invalid();
        }
        foreach (var after in plan.After.Where(x => !plan.Before.Contains(x)))
            if (after.Protected || after.Role is not ("entry" or "management") || after.Role == "management" && !after.Backup) throw Invalid();
        if (plan.Edits.DistinctBy(x => x.Member).Count() != plan.Edits.Length) throw Invalid();
        foreach (var edit in plan.Edits)
        {
            if (!edit.CanSave || plan.After.FirstOrDefault(x => x.Id == edit.Member) is not { Role: "entry", Protected: false }) throw Invalid();
            foreach (var folder in edit.Original)
            {
                if (folder.ProfileId != record.ProfileId || folder.RootId <= 0 || folder.Id <= 0 || folder.Id == folder.RootId || folder.Id == folder.ParentId ||
                    folder.Depth is not (0 or 1) || folder.Depth == 0 && folder.ParentId != folder.RootId || folder.Depth == 1 && !edit.Original.Any(x => x.Id == folder.ParentId && x.Depth == 0 && x.RootId == folder.RootId) ||
                    folder.Name.Length != 0 || !UploadHash(folder.IdentityHash) || !UploadHash(folder.Revision) || !UploadHash(folder.OtherPermissionsHash)) throw Invalid();
            }
        }
        var steps = MemberSteps(plan);
        if (steps.Count == 0 || facts.Length > steps.Count || facts.Where((x,i) => !Enum.IsDefined(x) || i < facts.Length - 1 && x != SynologyPhotoWriteStatus.Accepted).Any() ||
            record.Submitted != (facts.Length > 0) || record.CompletedSteps < 0 || record.CompletedSteps > facts.Length ||
            record.State == SynologyPhotoChangeState.Completed && (record.CompletedSteps != steps.Count || record.SharedResult is null) ||
            record.SharedResult is { } result && (result.ProfileId != record.ProfileId || result.AdministratorId != plan.AdministratorId || !Enum.IsDefined(result.Role))) throw Invalid();
    }
    private async Task ValidateMembersAsync(PhotoSettingsRecord record, bool progress, CancellationToken token)
    {
        if (!SettingsSafety.SharedMembers) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await CheckMemberWriteConflictsAsync(record.Owner, token).ConfigureAwait(false);
        var change = record.Members!; var plan = change.Plan; var steps = MemberSteps(plan);
        foreach (var step in steps) _ = Capability(step.Endpoint, 1, step.Edit < 0 ? null : SynologyPhotoSpace.Shared);
        var current = await SharedMembersAsync(token).ConfigureAwait(false);
        if (current.AdministratorId != plan.AdministratorId || !current.Enabled) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var accepted = progress ? change.Facts.TakeWhile(x => x == SynologyPhotoWriteStatus.Accepted).Count() : 0;
        var desired = steps.Take(accepted).Any(x => x.Edit < 0) ? plan.After : plan.Before;
        if (!MemberGrants(current.Members).SequenceEqual(desired)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var added = plan.After.Where(x => !plan.Before.Any(y => y.Id == x.Id)).ToArray();
        if (added.Length > 0 && !steps.Take(accepted).Any(x => x.Edit < 0))
        {
            var candidates = await SharedMemberCandidatesAsync(token).ConfigureAwait(false);
            if (added.Any(x => !candidates.Any(y => y.Id == x.Id && PhotoTextHash(y.Name) == x.NameHash))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        for (var index = 0; index < plan.Edits.Length; index++)
        {
            var edit = plan.Edits[index]; var folders = await SharedMemberFoldersAsync(edit.Member, token).ConfigureAwait(false);
            if (!folders.Select(x => x.Id).ToHashSet().SetEquals(edit.Original.Select(x => x.Id))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var done = steps.Take(accepted).Where(x => x.Edit == index).ToArray();
            foreach (var folder in edit.Original)
            {
                var actual = folders.Single(x => x.Id == folder.Id);
                if (done.Length == 0 ? folder != actual with { Name = "" } :
                    !MemberFolderMatches(folder, actual, edit.Expected(folder, done.Any(x => !x.Batch))) || folder.OtherPermissionsHash != actual.OtherPermissionsHash)
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            }
        }
        // 完整目录读取可能较长，写前再次核对成员身份和权限。
        if (plan.Edits.Length > 0)
        {
            var latest = await SharedMembersAsync(token).ConfigureAwait(false);
            if (!latest.Enabled || latest.AdministratorId != plan.AdministratorId || !MemberGrants(latest.Members).SequenceEqual(desired))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
    }
    private static bool MemberFolderMatches(SynologyPhotoMemberFolder original, SynologyPhotoMemberFolder actual, string? target) =>
        actual.Known && actual.IdentityHash == original.IdentityHash && actual.Privacy == original.Privacy && actual.RootId == original.RootId && actual.Depth == original.Depth &&
        actual.EffectiveLevel == Math.Max(SynologyPhotoMemberFolder.Level(target), original.PublicLevel);

    private bool MembersBusy() => _changes.Settings.Values.Any(x => x.Record.Owner == UploadOwner() && x.Record.Members is not null && ActiveSettings(x.Record));
    private async Task CheckMemberWriteConflictsAsync(string owner, CancellationToken token)
    {
        if (_changes.Tasks.Values.Any(x => x.Record.Owner == owner && (x.Record.Kind == SynologyPhotoEditKind.CreateTag && x.Record.Space == SynologyPhotoSpace.Shared && x.Record.TagState is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview ||
            x.Record.Items.Any(y => y.Original.Id.Space == SynologyPhotoSpace.Shared && y.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview))) ||
            _changes.Folders.Values.Any(x => x.Record.Owner == owner && x.Record.Edit.Folder.Space == SynologyPhotoSpace.Shared && ActiveFolderChange(x.Record)) ||
            _changes.Files.Values.Any(x => x.Record.Owner == owner && ActiveFileChange(x.Record) && (x.Record.Command.Photos.Any(y => y.Id.Space == SynologyPhotoSpace.Shared) || x.Record.Command.Folders.Any(y => y.Space == SynologyPhotoSpace.Shared) || x.Record.Command.Destination?.Space == SynologyPhotoSpace.Shared)) ||
            _changes.FolderSharing.Values.Any(x => x.Record.Owner == owner && ActiveFolderSharing(x.Record)) ||
            _changes.Requests.Values.Any(x => x.Record.Owner == owner && x.Record.Space == SynologyPhotoSpace.Shared && ActiveRequest(x.Record)) ||
            _changes.Albums.Values.Any(x => x.Record.Owner == owner && ActiveAlbumChange(x.Record) && (x.Record.Edit.ConditionSpace == SynologyPhotoSpace.Shared || x.Record.Edit.Photos.Any(y => y.Id.Space == SynologyPhotoSpace.Shared))) ||
            _changes.Recognition.Values.Any(x => x.Record.Owner == owner && x.Record.Space == SynologyPhotoSpace.Shared && ActiveRecognition(x.Record)) ||
            PreviewFolders(SynologyPhotoSpace.Shared, Guid.Empty).Any() || AutomaticBackgroundBusy(SynologyPhotoSpace.Shared, Guid.Empty))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (_uploadStore is null) return;
        await LoadUploadsAsync().ConfigureAwait(false); token.ThrowIfCancellationRequested();
        if (_uploads.Tasks.Values.Any(x => x.Record.Owner == owner && x.Record.Target.Space == SynologyPhotoSpace.Shared && x.Record.Items.Any(y => y.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
    }
}
