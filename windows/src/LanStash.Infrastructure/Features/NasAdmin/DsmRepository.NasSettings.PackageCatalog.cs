using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Uri? PackageCenterWebUri
    {
        get
        {
            var uri = _api.GetBaseUri(_profile);
            return uri.Scheme is "http" or "https" && uri.UserInfo.Length == 0 ?
                new UriBuilder(uri) { Query = "", Fragment = "", Path = "/" }.Uri : null;
        }
    }
    // 安装会执行套件代码；在专用 NAS 验收前独立保护，不影响目录与只读准备。
    public bool AllowsPackageInstallation { get; init; }
    public bool AllowsPackageAutomaticUpdates { get; init; }
    public bool AllowsPackageSourceTrust { get; init; }
    public NasPackageCenterAvailability PackageCenterAvailability => new(
        SecurityCapability("SYNO.Core.Package", 2) is not null && SecurityCapability("SYNO.Core.Package.Server", 2) is not null,
        AllowsPackageInstallation && PackageAdministrator && HasPackageInstallationCapabilities,
        AllowsPackageInstallation && PackageAdministrator && HasPackageInstallationCapabilities && HasPackageConfigurationCapabilities && _api.CanUploadPackage,
        PackageAdministrator && SecurityCapability("SYNO.Core.Package.Setting", 1) is not null,
        PackageAdministrator && SecurityCapability("SYNO.Core.Package.Feed", 1) is not null,
        AllowsPackageAutomaticUpdates, AllowsPackageSourceTrust);
    private bool PackageAdministrator => _nasServiceSessionVerified && _nasServiceAdministrator;
    private bool HasPackageInstallationCapabilities => SecurityCapability("SYNO.Core.Package", 1) is not null &&
        SecurityCapability("SYNO.Core.Package", 2) is not null && SecurityCapability("SYNO.Core.Package.Installation", 1) is not null &&
        SecurityCapability("SYNO.Core.Package.Installation", 2) is not null;
    private bool HasPackageConfigurationCapabilities => SecurityCapability("SYNO.Core.Package.Setting", 1) is not null &&
        SecurityCapability("SYNO.Core.Package.Setting.Volume", 1) is not null;
    private void RequirePackageWorkflowCapabilities(PackageCandidate candidate)
    {
        if (!candidate.Quick && (!HasPackageConfigurationCapabilities || SecurityCapability("SYNO.Core.Package.Installation.Download", 1) is null))
            throw PackageError("NasPackageUnsupported", MutationErrorCategory.Unsupported);
    }
    private static NasPackageCenterException PackageError(string key = "NasPackageCenterChanged", MutationErrorCategory category = MutationErrorCategory.Validation) => new(key, category);
    private Task<JsonObject> PackageCallAsync(string api, int version, string method, Dictionary<string, object> parameters, CancellationToken token) =>
        SecurityCallAsync(SecurityCapability(api, version) ?? throw PackageError("NasPackageUnsupported", MutationErrorCategory.Unsupported), method, parameters, token);
    private async Task RequirePackagePermissionAsync(CancellationToken token)
    {
        await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (!_nasServiceSessionVerified) throw PackageError("NasPackageAuthentication", MutationErrorCategory.Authentication);
        if (!_nasServiceAdministrator) throw PackageError("NasPackagePermission", MutationErrorCategory.Permission);
    }
    public async Task<NasPackageCatalog> LoadPackageCatalogAsync(CancellationToken token = default) =>
        (await ReadPackageCatalogAsync(token).ConfigureAwait(false)).Catalog;
    private async Task<PackageCatalogState> ReadPackageCatalogAsync(CancellationToken token)
    {
        var installed = await ReadPackageDirectoryAsync(token).ConfigureAwait(false);
        var official = await PackageCallAsync("SYNO.Core.Package.Server", 2, "list",
            new() { ["blforcereload"] = false, ["blloadothers"] = false }, token).ConfigureAwait(false);
        if (official["packages"] is not JsonArray stable || official["beta_packages"] is not JsonArray beta) throw InvalidNasServiceSettings();
        var rows = stable.Concat(beta).ToList(); var communityAvailable = true;
        try
        {
            var others = await PackageCallAsync("SYNO.Core.Package.Server", 2, "list",
                new() { ["blforcereload"] = false, ["blloadothers"] = true }, token).ConfigureAwait(false);
            if (others["packages"] is not JsonArray community) throw InvalidNasServiceSettings();
            rows.AddRange(community);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) when (!PackageTrustOrPermissionFailure(error)) { communityAvailable = false; }
        token.ThrowIfCancellationRequested();
        var candidates = new Dictionary<string, PackageCandidate>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            var candidate = ParsePackageCandidate(row as JsonObject ?? throw InvalidNasServiceSettings(), installed.Packages);
            if (!candidates.TryGetValue(candidate.Entry.Id, out var old) || !old.Entry.IsOfficial) candidates[candidate.Entry.Id] = candidate;
        }
        foreach (var pair in installed.Upgrades)
        {
            var candidate = ParsePackageCandidate(pair.Value, installed.Packages, pair.Key, true);
            candidates[candidate.Entry.Id] = candidate;
        }
        var categories = official["categories"] is null ? [] : ParsePackageCategories(official["categories"]);
        return new(new(candidates.Values.Select(candidate => candidate.Entry).OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase).ToArray(),
            categories, communityAvailable), candidates, installed.Packages);
    }
    private static PackageCandidate ParsePackageCandidate(JsonObject raw, IReadOnlyList<NasPackageSummary> installed, string? expectedId = null, bool explicitUpgrade = false)
    {
        var id = PackageText(raw, "id"); var name = PackageText(raw, "dname") ?? PackageText(raw, "name"); var version = PackageText(raw, "version");
        if (!StablePackageId(id) || expectedId is not null && id != expectedId || string.IsNullOrWhiteSpace(name) || string.IsNullOrWhiteSpace(version)) throw InvalidNasServiceSettings();
        var current = installed.FirstOrDefault(item => item.Id == id);
        if (current is not null && string.IsNullOrWhiteSpace(current.Version)) throw InvalidNasServiceSettings();
        var categories = PackageStrings(raw, "category", false) ?? [];
        return new(new(id!, name, version, PackageText(raw, "desc") ?? PackageText(raw, "description") ?? "",
            PackageText(raw, "changelog") ?? "", PackageText(raw, "distributor") ?? PackageText(raw, "maintainer") ?? "", categories,
            PackageBoolean(raw, "beta") == true, PackageText(raw, "source") == "syno", PackageInteger(raw, "size"),
            current?.Version, current is not null && current.Version != version && explicitUpgrade), (JsonObject)raw.DeepClone());
    }
    private static NasPackageCategory[] ParsePackageCategories(JsonNode? value)
    {
        if (value is not JsonArray rows) throw InvalidNasServiceSettings();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return rows.Select(node =>
        {
            if (node is not JsonObject row || PackageText(row, "id") is not { } id || !StablePackageId(id) ||
                PackageText(row, "dname") is not { } name || !seen.Add(id)) throw InvalidNasServiceSettings();
            return new NasPackageCategory(id, name);
        }).ToArray();
    }
    private static NasPackageInstallVolume[] PackageVolumes(JsonNode? value)
    {
        if (value is not JsonArray rows) throw InvalidNasServiceSettings();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        return rows.Select(node =>
        {
            if (node is not JsonObject row || PackageText(row, "mount_point") is not { Length: > 0 } id ||
                PackageText(row, "display") is not { } name || !seen.Add(id)) throw InvalidNasServiceSettings();
            return new NasPackageInstallVolume(id, name);
        }).ToArray();
    }
    private sealed record PackageCatalogState(NasPackageCatalog Catalog, IReadOnlyDictionary<string, PackageCandidate> Candidates, IReadOnlyList<NasPackageSummary> Installed);
    private sealed record PackageCandidate(NasPackageCatalogEntry Entry, JsonObject Raw)
    {
        public bool Quick => Entry.IsOfficial && PackageBoolean(Raw, Entry.InstalledVersion is null ? "qinst" : "qupgrade") != false &&
            (Raw["info"] is not JsonObject info || PackageBoolean(info, "blqinst") != false);
    }
    private static bool PackageTrustOrPermissionFailure(Exception error) => error is CertificateTrustChallengeException ||
        error is DsmException dsm && (dsm.AuthenticationFailure || dsm.Code is 105 or 106 or 107 or 119) ||
        error is NasPackageCenterException package && package.Category is MutationErrorCategory.Permission or MutationErrorCategory.Authentication;
}
