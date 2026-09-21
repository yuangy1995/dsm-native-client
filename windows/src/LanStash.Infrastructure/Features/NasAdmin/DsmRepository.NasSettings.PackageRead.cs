using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly string[] PackageAdditionalFields = ["status", "description", "install_type", "startable", "dsm_apps", "available_operation", "ctl_uninstall"];

    public async Task<IReadOnlyList<NasPackageSummary>> LoadPackagesAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = SecurityCapability("SYNO.Core.Package", 2) ??
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2, "list",
            new Dictionary<string, string> { ["offset"] = "0", ["limit"] = "1000",
                ["additional"] = System.Text.Json.JsonSerializer.Serialize(PackageAdditionalFields) }, cancellationToken).ConfigureAwait(false);
        // 到达源读取边界不能把未返回的目标当作已卸载；管理操作要求完整目录。
        if (data["packages"] is not JsonArray rows || rows.Count >= 1000) throw InvalidNasServiceSettings();
        var result = new List<NasPackageSummary>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var id = PackageText(row, "id");
            if (!StablePackageId(id) || !seen.Add(id!)) throw InvalidNasServiceSettings();
            // 已记录的 additional 与平铺变体，不接受任意根或按显示名称推断身份。
            var details = row["additional"] is null ? row : row["additional"] as JsonObject ?? throw InvalidNasServiceSettings();
            var status = (PackageText(details, "status") ?? "unknown").ToLowerInvariant();
            var name = PackageText(row, "name");
            result.Add(new(id!, string.IsNullOrWhiteSpace(name) ? id! : name, PackageText(row, "version"), status, ParseState(status))
            {
                Startable = PackageBoolean(details, "startable"), InstallType = PackageText(details, "install_type")?.ToLowerInvariant(),
                UninstallAllowed = PackageBoolean(details, "ctl_uninstall"), DesktopApps = PackageStrings(details, "dsm_apps", false),
                AvailableOperations = PackageStrings(details, "available_operation", true),
            });
        }
        return result.AsReadOnly();
    }
    private static bool StablePackageId(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
    private static string? PackageText(JsonObject value, string key) => value[key] is null ? null :
        value[key] is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : throw InvalidNasServiceSettings();
    private static bool? PackageBoolean(JsonObject value, string key) => value[key] is null ? null :
        value[key] is JsonValue scalar && scalar.TryGetValue<bool>(out var enabled) ? enabled : throw InvalidNasServiceSettings();
    private static IReadOnlyList<string>? PackageStrings(JsonObject value, string key, bool lowerCase)
    {
        if (value[key] is null) return null;
        string[] strings;
        if (value[key] is JsonArray array)
            strings = array.Select(node => node is JsonValue scalar && scalar.TryGetValue<string>(out var text) && StablePackageId(text)
                ? text : throw InvalidNasServiceSettings()).ToArray();
        else if (value[key] is JsonValue scalar && scalar.TryGetValue<string>(out var text))
            strings = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        else throw InvalidNasServiceSettings();
        if (strings.Any(item => !StablePackageId(item))) throw InvalidNasServiceSettings();
        return Array.AsReadOnly(strings.Select(item => lowerCase ? item.ToLowerInvariant() : item).Distinct(StringComparer.Ordinal).ToArray());
    }
}
