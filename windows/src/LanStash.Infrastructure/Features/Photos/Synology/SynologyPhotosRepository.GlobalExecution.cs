using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static bool SameGlobalChange(SynologyPhotoGlobalSettingChange? a, SynologyPhotoGlobalSettingChange? b) =>
        a is null ? b is null : b is not null && a.Original.SameValues(b.Original) && a.Updated.SameValues(b.Updated);
    private async Task<SynologyPhotoSettingsChange> ExecuteGlobalSettingsAsync(PhotoSettingsTask task, CancellationToken token)
    {
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false;
        PhotoSettingStepFact[]? beforeAttempt = null; var sent = false;
        try
        {
            await owner.WaitAsync(token).ConfigureAwait(false); owns = true;
            var generation = Volatile.Read(ref _accessGeneration);
            await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token);
            var steps = GlobalSteps(task.Record);
            if (steps.Count == 0)
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.Completed, GlobalResult = task.Record.Global?.Original }).ConfigureAwait(false);
            foreach (var step in steps)
            {
                token.ThrowIfCancellationRequested(); RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                beforeAttempt = task.Record.Steps ?? []; sent = false;
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.Submitting, Submitted = true,
                    Steps = [..beforeAttempt, new(step.Kind, SynologyPhotoWriteStatus.Unknown)] }).ConfigureAwait(false);
                // 写前检查当前原值，只放行本操作已接受步骤造成的变化与已记录的识别联动。
                if (beforeAttempt.Length == 0) await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false);
                else await ValidateGlobalProgressAsync(task.Record, token).ConfigureAwait(false);
                RequireGeneration(generation, token); CheckSettingsOwner(task.Record); sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability(step.Endpoint, step.Version, null), step.Version, step.Method, step.Parameters, token).ConfigureAwait(false);
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.PendingReview,
                    Steps = [..beforeAttempt, new(step.Kind, receipt.Status)], Failure = receipt.Failure }).ConfigureAwait(false);
                beforeAttempt = null; RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                if (receipt.Status != SynologyPhotoWriteStatus.Accepted) break;
            }
            await ReviewGlobalSettingsAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore();
            var facts = !sent && beforeAttempt is not null ? beforeAttempt : task.Record.Steps ?? [];
            await SaveSettingsAsync(task, task.Record with { State = facts.Length > 0 ? SynologyPhotoChangeState.PendingReview : token.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                Submitted = facts.Length > 0, Steps = facts, Failure = PreviewFailure(error) }).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SettingsSnapshot(task);
    }
    private async Task ReviewGlobalSettingsAsync(PhotoSettingsTask task, CancellationToken token)
    {
        if (task.Record.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) return;
        try
        {
            CheckSettingsOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
            var record = task.Record; SynologyPhotoGlobalSettings? current = null; SynologyPhotoConversionCache? cache = null;
            if (record.Global is { } global)
            {
                current = await GlobalSettingsAsync(token).ConfigureAwait(false);
                if (current.AdministratorId != global.Original.AdministratorId || current.ProfileId != global.Original.ProfileId)
                    throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                RequireGeneration(generation, token); CheckSettingsOwner(record);
                await SaveSettingsAsync(task, record with { GlobalResult = current }).ConfigureAwait(false); record = task.Record;
            }
            var facts = record.Steps ?? []; var steps = GlobalSteps(record); var completed = 0;
            foreach (var fact in facts.Where(fact => fact.Status != SynologyPhotoWriteStatus.Rejected))
            {
                var matched = false;
                if (fact.Kind == SynologyPhotoSettingStep.Cache)
                {
                    cache = await ConversionCacheAsync(token).ConfigureAwait(false);
                    var administrator = record.Cache?.AdministratorId ?? record.Global!.Original.AdministratorId;
                    if (cache.AdministratorId != administrator || cache.ProfileId != record.ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                    matched = !cache.IsClearing && (fact.Status == SynologyPhotoWriteStatus.Accepted || cache.SizeBytes == 0);
                }
                else if (current is not null && record.Global is { Original: var a, Updated: var b })
                {
                    matched = fact.Kind switch
                    {
                        SynologyPhotoSettingStep.Admin => Enum.GetValues<SynologyPhotoGlobalKind>().Where(kind => a.Value(kind) != b.Value(kind)).All(kind => current.Value(kind) == b.Value(kind)) &&
                            (SynologyPhotoGlobalSettings.SameExtensions(a.ExcludedExtensions, b.ExcludedExtensions) || SynologyPhotoGlobalSettings.SameExtensions(current.ExcludedExtensions, b.ExcludedExtensions)),
                        SynologyPhotoSettingStep.Personal => Matches(a.PersonalPeople, b.PersonalPeople, current.PersonalPeople) && Matches(a.PersonalSubjects, b.PersonalSubjects, current.PersonalSubjects) && Matches(a.PersonalSimilar, b.PersonalSimilar, current.PersonalSimilar),
                        SynologyPhotoSettingStep.Shared => Matches(a.SharedPeople, b.SharedPeople, current.SharedPeople) && Matches(a.SharedSubjects, b.SharedSubjects, current.SharedSubjects) && Matches(a.SharedSimilar, b.SharedSimilar, current.SharedSimilar),
                        _ => false
                    };
                }
                if (matched) completed++;
            }
            RequireGeneration(generation, token); CheckSettingsOwner(record);
            var rejected = facts.Count(fact => fact.Status == SynologyPhotoWriteStatus.Rejected);
            var state = completed == steps.Count ? SynologyPhotoChangeState.Completed : completed + rejected == facts.Length ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview;
            await SaveSettingsAsync(task, task.Record with { State = state, CompletedSteps = completed, GlobalResult = current, CacheResult = cache,
                Failure = state == SynologyPhotoChangeState.Completed ? null : task.Record.Failure }).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
    }
    private static bool Matches(bool? original, bool? target, bool? current) => original == target || current == target;
    private async Task ValidateGlobalProgressAsync(PhotoSettingsRecord record, CancellationToken token)
    {
        if (record.Global is not { Original: var a, Updated: var b }) { await RequirePhotoAdministratorAsync(token).ConfigureAwait(false); return; }
        var actual = await GlobalSettingsAsync(token).ConfigureAwait(false);
        var accepted = (record.Steps ?? []).Where(fact => fact.Status == SynologyPhotoWriteStatus.Accepted).Select(fact => fact.Kind).ToHashSet();
        var expected = accepted.Contains(SynologyPhotoSettingStep.Admin) ? a with { People = b.People, Subjects = b.Subjects, Similar = b.Similar,
            UserSharing = b.UserSharing, GuestInfo = b.GuestInfo, OriginalJpeg = b.OriginalJpeg, ExcludedExtensions = b.ExcludedExtensions } : a;
        bool? Recognition(bool? original, bool? target, bool? current, SynologyPhotoSettingStep step)
        {
            if (accepted.Contains(step)) return target;
            // 全局关闭识别后，套件可能已同步关闭图库。仍保留本操作每一步的提交事实。
            return accepted.Contains(SynologyPhotoSettingStep.Admin) && original != target && current == target ? target : original;
        }
        expected = expected with
        {
            PersonalPeople = Recognition(a.PersonalPeople, b.PersonalPeople, actual.PersonalPeople, SynologyPhotoSettingStep.Personal),
            PersonalSubjects = Recognition(a.PersonalSubjects, b.PersonalSubjects, actual.PersonalSubjects, SynologyPhotoSettingStep.Personal),
            PersonalSimilar = Recognition(a.PersonalSimilar, b.PersonalSimilar, actual.PersonalSimilar, SynologyPhotoSettingStep.Personal),
            SharedPeople = Recognition(a.SharedPeople, b.SharedPeople, actual.SharedPeople, SynologyPhotoSettingStep.Shared),
            SharedSubjects = Recognition(a.SharedSubjects, b.SharedSubjects, actual.SharedSubjects, SynologyPhotoSettingStep.Shared),
            SharedSimilar = Recognition(a.SharedSimilar, b.SharedSimilar, actual.SharedSimilar, SynologyPhotoSettingStep.Shared)
        };
        if (!expected.SameValues(actual)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
}
