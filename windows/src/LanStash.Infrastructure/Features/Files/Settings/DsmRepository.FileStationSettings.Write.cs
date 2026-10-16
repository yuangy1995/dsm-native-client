using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<FileStationSettingsProgress> SaveFileStationSettingAsync(FileStationSettingsChange change, CancellationToken token = default)
    {
        FileStationSettingsProgress Reject(MutationErrorCategory error, bool sent = false) => SettingsResult(change,
            error == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : error == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure, sent, error);
        if (!change.IsValid || change.Baseline.ProfileId != ProfileId) return Reject(MutationErrorCategory.Validation);
        if (token.IsCancellationRequested) return SettingsResult(change, MutationResultStatus.CancelledBeforeSubmission, false);
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict);
        try
        {
            var scope = ServiceScope();
            if (shared.FileStationSettings.TryGetValue((scope, change.RequestId), out var prior))
                return SameSettingsChange(prior.Change, change) ? await ReviewSettingsCore(prior, token).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            if (shared.FileStationSettings.Any(p => p.Key.Scope == scope && !p.Value.Complete && p.Value.Change.Baseline.Target == change.Baseline.Target)) return Reject(MutationErrorCategory.Conflict);
            string api; Dictionary<string, string> fields;
            try
            {
                await RequireFileSettingsWrite(token).ConfigureAwait(false);
                if (!await FileSettingMatches(change.Baseline, token).ConfigureAwait(false)) throw SettingsInvalid();
                (api, fields) = await FileSettingsFields(change, token).ConfigureAwait(false);
                if (fields.Count == 0 || !HasFixedCapability(api, 1)) throw new NotSupportedException();
                if (!await FileSettingMatches(change.Baseline, token).ConfigureAwait(false)) throw SettingsInvalid();
                await RequireFileSettingsWrite(token).ConfigureAwait(false); token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return SettingsResult(change, MutationResultStatus.CancelledBeforeSubmission, false); }
            catch (DsmException e) { return Reject(ServiceErrorCategory(e)); }
            catch (NotSupportedException) { return Reject(MutationErrorCategory.Unsupported); }
            catch (InvalidDataException) { return Reject(MutationErrorCategory.Conflict); }
            catch { return Reject(MutationErrorCategory.Network); }
            var pending = new PendingFileStationSetting(change); shared.FileStationSettings.Add((scope, change.RequestId), pending);
            try { await FileSettingsCall(api, "set", fields, token).ConfigureAwait(false); pending.Accepted = true; }
            catch (DsmException e) when (DsmApiClient.IsExplicitApiRejection(e))
            { shared.FileStationSettings.Remove((scope, change.RequestId)); return Reject(ServiceErrorCategory(e), true); }
            catch { /* 请求可能已到达；保留原目标与快照，仅允许只读恢复。 */ }
            return await ReviewSettingsCore(pending, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<FileStationSettingsProgress>> GetFileStationSettingsOperationsAsync(CancellationToken token = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(token).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.FileStationSettings.Where(p => p.Key.Scope == scope && !p.Value.Complete).Select(p => SettingsResult(p.Value.Change, MutationResultStatus.SubmittedButUnverified, true)).ToArray(); }
        finally { shared.Gate.Release(); }
    }
    public async Task<FileStationSettingsProgress?> ReviewFileStationSettingAsync(Guid requestId, CancellationToken token = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(token).ConfigureAwait(false);
        try { return shared.FileStationSettings.TryGetValue((ServiceScope(), requestId), out var pending) ? await ReviewSettingsCore(pending, token).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<FileStationSettingsProgress> ReviewSettingsCore(PendingFileStationSetting pending, CancellationToken token)
    {
        if (!pending.Complete)
        {
            try
            {
                if (pending.Change.Baseline is FileStationTheme old && pending.Change.Desired is FileStationTheme next)
                {
                    var current = await LoadFileStationThemeAsync(token).ConfigureAwait(false);
                    pending.Complete = pending.Accepted && current.SameLayout(next) &&
                        (next.LogoImage is null || current.LogoSequence is not null && current.LogoSequence != old.LogoSequence) &&
                        (next.BackgroundImage is null || current.BackgroundSequence is not null && current.BackgroundSequence != old.BackgroundSequence);
                    if (pending.Complete) pending.Verified = current;
                }
                else { var matches = await FileSettingMatches(pending.Change.Desired, token).ConfigureAwait(false); pending.Complete = pending.Accepted && matches; }
            }
            catch { /* 回读失败不清除已经发送的事实，也不补发。 */ }
        }
        return SettingsResult(pending.Verified is { } verified ? pending.Change with { Desired = verified } : pending.Change,
            pending.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, true);
    }
    private async Task<bool> FileSettingMatches(FileStationSetting expected, CancellationToken token)
    {
        if (expected.ProfileId != ProfileId) return false;
        return expected switch
        {
            FileStationGeneralSettings => expected.Equivalent(await LoadFileStationSettingsAsync(token).ConfigureAwait(false)),
            FileStationTheme => expected.Equivalent(await LoadFileStationThemeAsync(token).ConfigureAwait(false)),
            FileStationMountAccess => expected.Equivalent(await LoadFileStationMountAccessAsync(token).ConfigureAwait(false)),
            FileStationMountAccount a => (await LoadFileStationDirectoriesAsync(token).ConfigureAwait(false)).Items.Contains(a.Source) &&
                (await ListFileStationMountAccountsAsync(a.Source, a.Id.Kind, token).ConfigureAwait(false)).Any(a.Equivalent),
            FileStationBandwidth b => (await ListFileStationBandwidthAsync(b.Owner, token).ConfigureAwait(false)).Any(b.Equivalent),
            _ => false,
        };
    }
    private async Task<(string, Dictionary<string, string>)> FileSettingsFields(FileStationSettingsChange change, CancellationToken token)
    {
        switch (change.Baseline, change.Desired)
        {
            case (FileStationTheme old, FileStationTheme next): return (FileThemeApi, await FileThemeFields(old, next, token).ConfigureAwait(false));
            case (FileStationGeneralSettings old, FileStationGeneralSettings next):
                var result = new Dictionary<string, string>();
                void Text(string key, string before, string after) { if (before != after) result[key] = ShareParameterString(FileSettingsApi, after); }
                void Boolean(string key, bool before, bool after) { if (before != after) result[key] = after ? "true" : "false"; }
                Boolean("transfer_log_enable", old.RecordsTransfers, next.RecordsTransfers); Boolean("use_unix_default_perm", old.UsesDefaultPermissions, next.UsesDefaultPermissions);
                Boolean("enable_list_usergrp", old.ShowsAccounts, next.ShowsAccounts);
                Text("sharing_allow", SettingsAccessValue(old.Sharing), SettingsAccessValue(next.Sharing)); Text("file_request_allow", SettingsAccessValue(old.FileRequests), SettingsAccessValue(next.FileRequests));
                Text("rf_allow", SettingsAccessValue(old.RemoteMounts), SettingsAccessValue(next.RemoteMounts)); Text("vd_allow", SettingsAccessValue(old.IsoMounts), SettingsAccessValue(next.IsoMounts));
                Text("schedule_plan", old.Schedule, next.Schedule);
                if (old.DefaultLinkLimit != next.DefaultLinkLimit) result["sharing_default_limit"] = next.DefaultLinkLimit.ToString(CultureInfo.InvariantCulture);
                if (old.Bandwidth != next.Bandwidth) result["bandwidth_enable"] = ShareParameterString(FileSettingsApi, next.Bandwidth switch { FileStationBandwidthPolicy.Disabled => "bandwidth_disable", FileStationBandwidthPolicy.Enabled => "bandwidth_enable", _ => "bandwidth_schedule" });
                if (old.UsesCustomSharingPage != next.UsesCustomSharingPage)
                { if (old.UsesCustomSharingPage is not { } before || next.UsesCustomSharingPage is not { } after) throw SettingsInvalid(); Boolean("enable_sharing_custom_setting", before, after); }
                foreach (var (prefix, before, after) in new[] { ("sharing", old.SharingAccounts, next.SharingAccounts), ("file_request", old.RequestAccounts, next.RequestAccounts) })
                {
                    foreach (var kind in Enum.GetValues<FileSharePrincipalKind>())
                    {
                        var added = after.Except(before).Where(a => a.Kind == kind).ToArray(); var removed = before.Except(after).Where(a => a.Kind == kind).ToArray();
                        var affected = added.Concat(removed).ToArray(); if (affected.Length == 0) continue;
                        var accounts = await ListFileStationPolicyAccountsAsync(kind, token).ConfigureAwait(false);
                        foreach (var id in affected)
                        {
                            var account = accounts.SingleOrDefault(a => a.Id == id) ?? throw SettingsInvalid();
                            if (account.IsAdministrator) throw new DsmException("file.settings.admin", "file.settings.refresh", code: 105);
                        }
                        var field = prefix + (kind == FileSharePrincipalKind.User ? "_privilege" : "_group_privilege");
                        if (added.Length > 0) result["enabled_" + field] = ShareParameterString(FileSettingsApi, string.Join(',', added.OrderBy(a => a.Value).Select(a => a.Value.ToString(CultureInfo.InvariantCulture))));
                        if (removed.Length > 0) result["disabled_" + field] = ShareParameterString(FileSettingsApi, string.Join(',', removed.OrderBy(a => a.Value).Select(a => a.Value.ToString(CultureInfo.InvariantCulture))));
                    }
                }
                return (FileSettingsApi, result);
            case (FileStationMountAccess, FileStationMountAccess next):
                return (FileMountUserApi, new() { ["settings"] = new JsonObject { ["user_enabled_type"] = SettingsAccessValue(next.Access, true) }.ToJsonString() });
            case (FileStationMountAccount old, FileStationMountAccount next):
                if (old with { Enabled = next.Enabled } != next || !old.CanModify || old.Enabled == next.Enabled) throw SettingsInvalid();
                var accountSettings = new JsonObject { [old.Id.Kind == FileSharePrincipalKind.User ? "user_settings" : "group_settings"] = new JsonArray(new JsonObject
                    { [old.Id.Kind == FileSharePrincipalKind.User ? "uid" : "gid"] = old.Id.Value, ["enabled"] = next.Enabled }) };
                return (FileMountUserApi, new() { ["settings"] = accountSettings.ToJsonString() });
            case (FileStationBandwidth old, FileStationBandwidth next):
                if (next.Policy == FileStationBandwidthPolicy.NotConfigured || old.Owner != next.Owner || old.Name != next.Name) throw SettingsInvalid();
                return (FileBandwidthApi, new() { ["bandwidths"] = new JsonArray(new JsonObject { ["name"] = next.Name, ["protocol"] = "FileStation",
                    ["owner_type"] = SettingsOwner(next.Owner), ["policy"] = next.Policy.ToString().ToLowerInvariant(), ["schedule_plan"] = next.Schedule,
                    ["upload_limit_1"] = next.UploadLimit, ["download_limit_1"] = next.DownloadLimit, ["upload_limit_2"] = next.AlternateUploadLimit, ["download_limit_2"] = next.AlternateDownloadLimit }).ToJsonString() });
            default: throw SettingsInvalid();
        }
    }
    private static bool SameSettingsChange(FileStationSettingsChange left, FileStationSettingsChange right) => left.RequestId == right.RequestId &&
        left.Confirmed == right.Confirmed && left.Baseline.Equivalent(right.Baseline) && left.Desired.Equivalent(right.Desired);
    private static FileStationSettingsProgress SettingsResult(FileStationSettingsChange change, MutationResultStatus status, bool sent, MutationErrorCategory? error = null) =>
        new(change, new(1, status, "fileStationSettings", sent, status == MutationResultStatus.SubmittedButUnverified,
            new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0,
                status == MutationResultStatus.SubmittedButUnverified ? 1 : 0), error, diagnosticTag: "file.settings"));
    private sealed class PendingFileStationSetting(FileStationSettingsChange change)
    { public FileStationSettingsChange Change { get; } = change; public bool Accepted { get; set; } public bool Complete { get; set; } public FileStationSetting? Verified { get; set; } }
}
