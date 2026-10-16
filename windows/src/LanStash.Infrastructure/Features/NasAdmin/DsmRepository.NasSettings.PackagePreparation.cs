using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private PackagePlanState? _packageInstallPlan;
    private sealed record PackagePlanState(NasPackageInstallPlan Plan, string[] RequestedIds, PackageCandidate[] Candidates,
        JsonObject Queue, IReadOnlyList<NasPackageSummary> Installed);
    public async Task<NasPackageInstallPlan> PreparePackageInstallationAsync(IReadOnlyList<string> catalogIds, CancellationToken token = default)
    {
        var requested = catalogIds.ToArray();
        if (requested.Length == 0 || requested.Distinct(StringComparer.Ordinal).Count() != requested.Length || !HasPackageInstallationCapabilities) throw PackageError();
        await EnterNasManagementAsync(token).ConfigureAwait(false);
        try
        {
            RequirePackageIdle(); _packageInstallPlan = null;
            await RequirePackagePermissionAsync(token).ConfigureAwait(false);
            var catalog = await ReadPackageCatalogAsync(token).ConfigureAwait(false);
            var state = await BuildPackagePlanAsync(requested, catalog, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested(); _packageInstallPlan = state; return state.Plan;
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task<PackagePlanState> BuildPackagePlanAsync(string[] requestedIds, PackageCatalogState catalog, CancellationToken token)
    {
        var requested = requestedIds.Select(id => catalog.Candidates.TryGetValue(id, out var candidate) && candidate.Entry.CanInstall ? candidate : throw PackageError()).ToArray();
        if (requested.Any(candidate => candidate.Entry.IsBeta)) await RequirePackageBetaAgreementAsync(token).ConfigureAwait(false);
        await PackageFeasibilityAsync(requested.Select(candidate => candidate.Entry.PackageId).ToArray(), token).ConfigureAwait(false);
        var queue = await PackageCallAsync("SYNO.Core.Package.Installation", 1, "get_queue", new()
        {
            ["pkgs"] = requested.Select(candidate => new { pkg = candidate.Entry.PackageId, operation = "install", version = candidate.Entry.Version, beta = candidate.Entry.IsBeta }).ToArray(),
        }, token).ConfigureAwait(false);
        if (queue["queue"] is not JsonArray steps || steps.Count == 0 || PackageQueueStrings(queue, "non_exist_pkgs").Length > 0 ||
            PackageQueueStrings(queue, "conflicted_pkgs", true).Length > 0) throw PackageError("NasPackageCenterDependencies");
        var affected = new[] { "broken_pkgs", "replaced_pkgs", "paused_pkgs" }.SelectMany(key => PackageQueueStrings(queue, key)).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        var candidates = new List<PackageCandidate>(); var items = new List<NasPackageInstallItem>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in steps)
        {
            token.ThrowIfCancellationRequested();
            if (node is not JsonObject step || PackageText(step, "pkg") is not { } id || PackageBoolean(step, "beta") is not { } beta || !seen.Add(id) ||
                !catalog.Candidates.TryGetValue(id + (beta ? ":beta" : ":stable"), out var candidate) ||
                PackageText(step, "version") is { } version && version != candidate.Entry.Version) throw PackageError();
            if (candidate.Entry.InstalledVersion is not null && !candidate.Entry.IsUpdateAvailable) throw PackageError();
            if (candidate.Entry.IsBeta && !requested.Any(value => value.Entry.IsBeta)) await RequirePackageBetaAgreementAsync(token).ConfigureAwait(false);
            RequirePackagePurchaseSupported(candidate);
            RequirePackageWorkflowCapabilities(candidate);
            candidates.Add(candidate); items.Add(await PackageEnvironmentAsync(candidate, token).ConfigureAwait(false));
        }
        if (requestedIds.Any(id => !candidates.Any(candidate => candidate.Entry.Id == id))) throw InvalidNasServiceSettings();
        var installed = await LoadPackagesAsync(token).ConfigureAwait(false);
        if (PackageInstalledSignature(installed) != PackageInstalledSignature(catalog.Installed)) throw PackageError();
        return new(new(Guid.NewGuid(), ProfileId, items.ToArray(), affected), requestedIds, candidates.ToArray(), (JsonObject)queue.DeepClone(), installed);
    }
    private Task<JsonObject> PackageFeasibilityAsync(string[] ids, CancellationToken token) =>
        PackageCallAsync("SYNO.Core.Package", 1, "feasibility_check", new() { ["type"] = "install_check", ["packages"] = ids }, token);
    private async Task RequirePackageBetaAgreementAsync(CancellationToken token)
    {
        var info = await PackageCallAsync("SYNO.Core.Package.Info", 1, "get", new(), token).ConfigureAwait(false);
        if (info["prerelease"] is not JsonObject agreement || PackageBoolean(agreement, "success") != true || PackageBoolean(agreement, "agreed") != true)
            throw PackageError("NasPackageCenterBetaAgreement");
    }
    private static void RequirePackagePurchaseSupported(PackageCandidate candidate)
    {
        if (candidate.Raw["price"] is not null && PackageInteger(candidate.Raw, "type") != 0) throw PackageError("NasPackageCenterPurchaseRequired");
    }
    private async Task<NasPackageInstallItem> PackageEnvironmentAsync(PackageCandidate candidate, CancellationToken token)
    {
        var parameters = new Dictionary<string, object> { ["id"] = candidate.Entry.PackageId, ["ver"] = candidate.Entry.Version,
            ["blupgrade"] = candidate.Entry.InstalledVersion is not null, ["blCheckDep"] = false };
        foreach (var key in new[] { "depsers", "deppkgs", "conflictpkgs", "breakpkgs", "replacepkgs", "size", "install_type", "install_on_cold_storage" })
            if (candidate.Raw[key] is { } value) parameters[key] = PackageParameter(value);
        var data = await PackageCallAsync("SYNO.Core.Package.Installation", 2, "check", parameters, token).ConfigureAwait(false);
        return PackageEnvironmentItem(candidate.Entry, data, PackageText(candidate.Raw, "install_type"));
    }
    private static NasPackageInstallItem PackageEnvironmentItem(NasPackageCatalogEntry entry, JsonObject data, string? installType)
    {
        if (PackageBoolean(data, "is_occupied") != false) throw PackageError("NasPackageCenterBusy", MutationErrorCategory.Conflict);
        var system = installType is "system" or "system_hidden";
        var volumes = system && data["volume_list"] is null ? [] : PackageVolumes(data["volume_list"]);
        if (volumes.Length == 0 && !system) throw PackageError("NasPackageCenterNoVolume");
        var selected = PackageText(data, "volume_path") ?? (volumes.Length == 1 ? volumes[0].Id : "");
        return new(entry, volumes, selected);
    }
    private static string[] PackageQueueStrings(JsonObject data, string key, bool allowObjects = false)
    {
        if (data[key] is not JsonArray rows) throw InvalidNasServiceSettings();
        return rows.Select(node => node is JsonValue value && value.TryGetValue<string>(out var text) ? text :
            allowObjects && node is JsonObject ? key : throw InvalidNasServiceSettings()).ToArray();
    }
    private static object PackageParameter(JsonNode value) => value is JsonValue scalar && scalar.TryGetValue<string>(out var text)
        ? text : value.DeepClone();
    private static void RequirePackageVolume(string selected, NasPackageInstallItem item)
    {
        if (!(item.Volumes.Count == 0 && selected.Length == 0) && !item.Volumes.Any(volume => volume.Id == selected))
            throw PackageError("NasPackageCenterSelectVolume");
    }
    private static string PackageInstalledSignature(IReadOnlyList<NasPackageSummary> values) => JsonSerializer.Serialize(values.OrderBy(item => item.Id, StringComparer.Ordinal)
        .Select(PackageInstallationIdentity));
    private static bool PackagePlansEqual(PackagePlanState old, PackagePlanState current) =>
        JsonSerializer.Serialize(old.Plan.Items) == JsonSerializer.Serialize(current.Plan.Items) &&
        old.Plan.AffectedPackages.SequenceEqual(current.Plan.AffectedPackages) && JsonNode.DeepEquals(old.Queue, current.Queue) &&
        old.Candidates.Length == current.Candidates.Length && old.Candidates.Zip(current.Candidates).All(pair => JsonNode.DeepEquals(pair.First.Raw, pair.Second.Raw)) &&
        PackageInstalledSignature(old.Installed) == PackageInstalledSignature(current.Installed);
}
