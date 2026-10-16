using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task<SynologyPhotoSettingsChange> ExecuteMembersAsync(PhotoSettingsTask task, CancellationToken token)
    {
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false;
        SynologyPhotoWriteStatus[]? beforeAttempt = null; var sent = false;
        try
        {
            await owner.WaitAsync(token).ConfigureAwait(false); owns = true;
            var generation = Volatile.Read(ref _accessGeneration);
            await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token);
            foreach (var step in MemberSteps(task.Record.Members!.Plan))
            {
                token.ThrowIfCancellationRequested(); CheckSettingsOwner(task.Record); RequireGeneration(generation, token);
                beforeAttempt = task.Record.Members!.Facts; sent = false;
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.Submitting, Submitted = true,
                    Members = task.Record.Members with { Facts = [..beforeAttempt, SynologyPhotoWriteStatus.Unknown] } }).ConfigureAwait(false);
                await ValidateMembersAsync(task.Record, beforeAttempt.Length > 0, token).ConfigureAwait(false);
                CheckSettingsOwner(task.Record); RequireGeneration(generation, token); sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability(step.Endpoint, 1, step.Edit < 0 ? null : SynologyPhotoSpace.Shared), 1,
                    step.Method, step.Parameters, token).ConfigureAwait(false);
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.PendingReview, Failure = receipt.Failure,
                    Members = task.Record.Members with { Facts = [..beforeAttempt, receipt.Status] } }).ConfigureAwait(false);
                beforeAttempt = null; RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                if (receipt.Status != SynologyPhotoWriteStatus.Accepted) break;
            }
            await ReviewMembersAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore(); var facts = !sent && beforeAttempt is not null ? beforeAttempt : task.Record.Members!.Facts;
            await SaveSettingsAsync(task, task.Record with { State = facts.Length > 0 ? SynologyPhotoChangeState.PendingReview : token.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                Submitted = facts.Length > 0, Members = task.Record.Members! with { Facts = facts }, Failure = PreviewFailure(error) }).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SettingsSnapshot(task);
    }
    private async Task ReviewMembersAsync(PhotoSettingsTask task, CancellationToken token)
    {
        try
        {
            CheckSettingsOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
            var record = task.Record; var change = record.Members!; var plan = change.Plan; var steps = MemberSteps(plan);
            var current = await SharedMembersAsync(token).ConfigureAwait(false);
            if (current.AdministratorId != plan.AdministratorId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            var grants = MemberGrants(current.Members); var changedIds = plan.Before.Select(x => x.Id).Union(plan.After.Select(x => x.Id))
                .Where(id => plan.Before.FirstOrDefault(x => x.Id == id) != plan.After.FirstOrDefault(x => x.Id == id)).ToArray();
            bool GrantMatches(SynologyPhotoShareIdentity id, PhotoMemberGrant[] target)
            { var actual = grants.FirstOrDefault(x => x.Id == id); var desired = target.FirstOrDefault(x => x.Id == id); return actual?.Id == desired?.Id && actual?.Role == desired?.Role && actual?.Backup == desired?.Backup; }
            var changed = change.Changed || changedIds.Any(id => !GrantMatches(id, plan.Before)); var completed = 0; var resolved = 0;
            var snapshots = new Dictionary<int, IReadOnlyList<SynologyPhotoMemberFolder>>();
            for (var index = 0; index < change.Facts.Length; index++)
            {
                var step = steps[index]; bool matches;
                if (step.Edit < 0) matches = current.Enabled && changedIds.All(id => GrantMatches(id, plan.After));
                else
                {
                    var edit = plan.Edits[step.Edit];
                    if (!snapshots.TryGetValue(step.Edit, out var folders))
                        snapshots[step.Edit] = folders = await SharedMemberFoldersAsync(edit.Member, token).ConfigureAwait(false);
                    var byId = folders.ToDictionary(x => x.Id);
                    changed |= edit.Original.Any(x => byId.TryGetValue(x.Id, out var actual) && x.DirectRole != actual.DirectRole);
                    bool Match(SynologyPhotoMemberFolder folder, bool final) => byId.TryGetValue(folder.Id, out var actual) && MemberFolderMatches(folder, actual, edit.Expected(folder, final));
                    if (step.Batch)
                    {
                        var following = steps.Take(change.Facts.Length).Any(x => x.Edit == step.Edit && !x.Batch);
                        matches = byId.Keys.ToHashSet().SetEquals(edit.Original.Select(x => x.Id)) && edit.Original.All(x => Match(x, false) || following && Match(x, true));
                    }
                    else
                    {
                        var direct = (edit.Changes ?? []).Select(x => x.FolderId).ToHashSet();
                        matches = edit.Original.Where(x => direct.Contains(x.Id) || x.Depth == 1 && direct.Contains(x.ParentId) && edit.Expected(x) != edit.Expected(x, false)).All(x => Match(x, true));
                    }
                }
                if (matches) completed++;
                if (matches || change.Facts[index] == SynologyPhotoWriteStatus.Rejected) resolved++;
            }
            RequireGeneration(generation, token); CheckSettingsOwner(record);
            var state = completed == steps.Count ? SynologyPhotoChangeState.Completed : resolved == change.Facts.Length ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview;
            // 即使结构化拒绝，也按实际部分结果收尾；本人权限仅从套件当前设置取得。
            var shared = state == SynologyPhotoChangeState.PendingReview ? null : await SharedSettingsAsync(token).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckSettingsOwner(record);
            await SaveSettingsAsync(task, task.Record with { State = state, CompletedSteps = completed, Members = change with { Changed = changed }, SharedResult = shared,
                Failure = state == SynologyPhotoChangeState.Completed ? null : task.Record.Failure }).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
    }
}
