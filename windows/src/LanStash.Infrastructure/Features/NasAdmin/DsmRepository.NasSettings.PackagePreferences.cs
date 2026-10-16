using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasPackageCenterSettings> LoadPackageCenterSettingsAsync(CancellationToken token = default)
    {
        var data = await PackageCallAsync("SYNO.Core.Package.Setting", 1, "get", new(), token).ConfigureAwait(false);
        bool Required(string key) => PackageBoolean(data, key) ?? throw InvalidNasServiceSettings();
        var beta = Required("update_channel"); var email = Required("enable_email"); var desktop = Required("enable_dsm");
        var automatic = Required("enable_autoupdate"); var all = Required("autoupdateall"); var important = Required("autoupdateimportant");
        var volumes = PackageVolumes(data["volume_list"]); var defaultVolume = PackageText(data, "default_vol") ?? "no_default_vol";
        var list = await PackageCallAsync("SYNO.Core.Package", 2, "list", new()
        { ["offset"] = 0, ["limit"] = 1000, ["additional"] = new[] { "silent_upgrade", "autoupdate", "status" } }, token).ConfigureAwait(false);
        var rows = CompletePackageRows(list, "packages", 1000); var seen = new HashSet<string>(StringComparer.Ordinal);
        var preferences = rows.Select(node =>
        {
            if (node is not JsonObject row || PackageText(row, "id") is not { } id || !StablePackageId(id) || !seen.Add(id) ||
                PackageText(row, "name") is not { } name || row["additional"] is not JsonObject info) throw InvalidNasServiceSettings();
            var latest = PackageBoolean(info, "autoupdate"); var crucial = PackageBoolean(info, "autoupdate_important");
            var silent = PackageBoolean(info, "silent_upgrade"); var status = PackageText(info, "status"); var limit = PackageText(info, "limit_type");
            NasPackageSingleUpdatePolicy? policy = latest == true ? NasPackageSingleUpdatePolicy.Latest :
                latest is null || crucial is null ? null : crucial == true ? NasPackageSingleUpdatePolicy.Important : NasPackageSingleUpdatePolicy.Manual;
            return new NasPackageUpdatePreference(id, name, silent == true && (status != "version_limit" || limit is not ("non" or "system")), policy);
        }).OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();
        return new(beta, email, desktop, !automatic ? NasPackageUpdatePolicy.Manual : all ? NasPackageUpdatePolicy.Latest :
            important ? NasPackageUpdatePolicy.Important : NasPackageUpdatePolicy.Selected,
            defaultVolume == "no_default_vol" ? "" : defaultVolume, volumes, preferences);
    }
    public async Task<NasPackageActivity> SavePackageCenterSettingsAsync(NasPackageSettingsRequest request, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        if (request.ProfileId != ProfileId || !request.RiskConfirmed || request.RequestId == Guid.Empty) throw PackageError();
        var baseline = FreezePackageSettings(request.Baseline); var desired = FreezePackageSettings(request.Desired);
        if (!ValidPackageSettings(baseline, desired) || PackageSettingsSignature(baseline) == PackageSettingsSignature(desired)) throw PackageError();
        if (!AllowsPackageAutomaticUpdates && desired.UpdatePolicy != NasPackageUpdatePolicy.Manual &&
            (baseline.UpdatePolicy != desired.UpdatePolicy || desired.UpdatePolicy == NasPackageUpdatePolicy.Selected &&
                PackageUpdateChoices(baseline) != PackageUpdateChoices(desired))) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        var signature = ServiceHash(JsonSerializer.Serialize(new { Original = PackageSettingsSignature(baseline), Desired = PackageSettingsSignature(desired) }));
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            if (ExistingPackageRequest(request.RequestId, signature) is { } previous)
            { await ReviewPackageRecordCoreAsync(previous, token).ConfigureAwait(false); return PackageActivityInfo(previous); }
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var current = await LoadPackageCenterSettingsAsync(token).ConfigureAwait(false);
            if (PackageSettingsSignature(current) != PackageSettingsSignature(baseline)) throw PackageError();
            var parameters = new Dictionary<string, object>
            {
                ["update_channel"] = desired.BetaEnabled ? "beta" : "stable", ["enable_email"] = desired.EmailNotifications,
                ["enable_dsm"] = desired.DesktopNotifications, ["enable_autoupdate"] = desired.UpdatePolicy != NasPackageUpdatePolicy.Manual,
                ["autoupdateall"] = desired.UpdatePolicy == NasPackageUpdatePolicy.Latest,
                ["autoupdateimportant"] = desired.UpdatePolicy == NasPackageUpdatePolicy.Important,
            };
            if (desired.DefaultVolumeId != baseline.DefaultVolumeId) parameters["default_vol"] = desired.DefaultVolumeId.Length == 0 ? "no_default_vol" : desired.DefaultVolumeId;
            if (desired.UpdatePolicy == NasPackageUpdatePolicy.Selected)
            {
                // 这两项契约是 JSON 数组文本，JSON 传输格式还需外层字符串编码。
                parameters["packages"] = JsonSerializer.Serialize(desired.PackageUpdates.Where(item => item.Policy == NasPackageSingleUpdatePolicy.Latest).Select(item => item.Id).Order(StringComparer.Ordinal));
                parameters["packages_important"] = JsonSerializer.Serialize(desired.PackageUpdates.Where(item => item.Policy == NasPackageSingleUpdatePolicy.Important).Select(item => item.Id).Order(StringComparer.Ordinal));
            }
            var entry = NewPackageRecord(request.RequestId, signature, NasPackageActivityKind.Settings, ServiceHash("package-settings"), PackageSettingsTargetDigest(desired));
            await SubmitPackageCommandAsync(entry, PackageSubmissionKind.Preferences, "SYNO.Core.Package.Setting", 1, "set", parameters, token).ConfigureAwait(false);
            await TryReviewPackageRecordAsync(entry, token).ConfigureAwait(false);
            return PackageActivityInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<IReadOnlyList<NasPackageSource>> LoadPackageSourcesAsync(CancellationToken token = default)
    {
        var data = await PackageCallAsync("SYNO.Core.Package.Feed", 1, "list", new(), token).ConfigureAwait(false);
        var rows = CompletePackageRows(data, "items"); var seen = new HashSet<string>(StringComparer.Ordinal);
        return rows.Select(node =>
        {
            if (node is not JsonObject row || PackageText(row, "name") is not { Length: > 0 } name ||
                PackageText(row, "feed") is not { Length: > 0 } url || !seen.Add(url)) throw InvalidNasServiceSettings();
            return new NasPackageSource(name, url);
        }).OrderBy(source => source.Url, StringComparer.Ordinal).ToArray();
    }
    public async Task<NasPackageActivity> SavePackageSourceAsync(NasPackageSourceRequest request, CancellationToken token = default)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _packageTrackingLifetime.Token); token = lifetime.Token;
        if (request.ProfileId != ProfileId || request.RequestId == Guid.Empty || !request.RiskConfirmed || request.Baseline is null && request.Desired is null) throw PackageError();
        var target = request.Desired?.Normalize();
        if (request.Desired is not null && target is null || target == request.Baseline) throw PackageError("NasPackageCenterSourceInvalid");
        if (target is not null && !AllowsPackageSourceTrust) throw PackageError("NasPackageCenterProtected", MutationErrorCategory.Unsupported);
        var kind = target is null ? NasPackageActivityKind.RemoveSource : NasPackageActivityKind.SaveSource;
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind, request.Baseline, target }));
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            if (ExistingPackageRequest(request.RequestId, signature) is { } previous)
            { await ReviewPackageRecordCoreAsync(previous, token).ConfigureAwait(false); return PackageActivityInfo(previous); }
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var current = await LoadPackageSourcesAsync(token).ConfigureAwait(false);
            if (request.Baseline is not null && !current.Contains(request.Baseline)) throw PackageError();
            if (target is not null && current.Any(item => item.Url != request.Baseline?.Url && (item.Url == target.Url || item.Name == target.Name)))
                throw PackageError("NasPackageCenterSourceDuplicate", MutationErrorCategory.Conflict);
            var entry = NewPackageRecord(request.RequestId, signature, kind, ServiceHash((target ?? request.Baseline!).Url),
                target is null ? ServiceHash("source-removed") : PackageSourceDigest(target));
            if (target is not null && request.Baseline is not null && target.Url != request.Baseline.Url)
                entry.Package!.RemovedDigest = ServiceHash(request.Baseline.Url);
            string method, list;
            if (target is null) { method = "delete"; list = JsonSerializer.Serialize(new[] { request.Baseline!.Url }); }
            else
            {
                method = request.Baseline is null ? "add" : "set";
                var fields = new Dictionary<string, string> { ["name"] = target.Name, ["feed"] = target.Url };
                if (request.Baseline is not null) fields["orifeed"] = request.Baseline.Url;
                list = JsonSerializer.Serialize(fields);
            }
            await SubmitPackageCommandAsync(entry, PackageSubmissionKind.Preferences, "SYNO.Core.Package.Feed", 1, method, new() { ["list"] = list }, token).ConfigureAwait(false);
            await TryReviewPackageRecordAsync(entry, token).ConfigureAwait(false);
            return PackageActivityInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task TryReviewPackageRecordAsync(NasManagementRecord entry, CancellationToken token)
    {
        try { await ReviewPackageRecordCoreAsync(entry, token).ConfigureAwait(false); }
        catch { /* 已提交记录继续保留，只能刷新恢复，不依据异常重发。 */ }
    }
    private static NasPackageCenterSettings FreezePackageSettings(NasPackageCenterSettings value) => value with
    { Volumes = value.Volumes.ToArray(), PackageUpdates = value.PackageUpdates.ToArray() };
    private static bool ValidPackageSettings(NasPackageCenterSettings baseline, NasPackageCenterSettings desired) =>
        Enum.IsDefined(desired.UpdatePolicy) && baseline.Volumes.SequenceEqual(desired.Volumes) &&
        (desired.DefaultVolumeId.Length == 0 || baseline.Volumes.Any(volume => volume.Id == desired.DefaultVolumeId)) &&
        desired.PackageUpdates.Count == baseline.PackageUpdates.Count && desired.PackageUpdates.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() == desired.PackageUpdates.Count &&
        desired.PackageUpdates.All(item => (item.Policy is null || Enum.IsDefined(item.Policy.Value)) && baseline.PackageUpdates.Any(old =>
            old.Id == item.Id && old.Name == item.Name && old.CanUpdateAutomatically == item.CanUpdateAutomatically &&
            (old.CanUpdateAutomatically && old.Policy is not null && item.Policy is not null || old.Policy == item.Policy))) &&
        (desired.UpdatePolicy != NasPackageUpdatePolicy.Selected || desired.PackageUpdates.All(item => item.Policy is not null));
    private static string PackageSettingsSignature(NasPackageCenterSettings value) => JsonSerializer.Serialize(new
    {
        value.BetaEnabled, value.EmailNotifications, value.DesktopNotifications, value.UpdatePolicy, value.DefaultVolumeId,
        Volumes = value.Volumes.OrderBy(item => item.Id, StringComparer.Ordinal), Packages = value.PackageUpdates.OrderBy(item => item.Id, StringComparer.Ordinal),
    });
    private static string PackageUpdateChoices(NasPackageCenterSettings value) => JsonSerializer.Serialize(value.PackageUpdates
        .Where(item => item.Policy != NasPackageSingleUpdatePolicy.Manual).OrderBy(item => item.Id, StringComparer.Ordinal).Select(item => new { item.Id, item.Policy }));
    private static string PackageSettingsTargetDigest(NasPackageCenterSettings value) => ServiceHash(JsonSerializer.Serialize(new
    {
        value.BetaEnabled, value.EmailNotifications, value.DesktopNotifications, value.UpdatePolicy, value.DefaultVolumeId,
        Packages = value.UpdatePolicy == NasPackageUpdatePolicy.Selected ? PackageUpdateChoices(value) : "",
    }));
    private static string PackageSourceDigest(NasPackageSource value) => ServiceHash(JsonSerializer.Serialize(value));
}
