using System.Collections.Immutable;
using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 内部设置接口；版本、字段和降级依据 file-station-package-settings 记录。
    private const string FileSettingsApi = "SYNO.FileStation.Settings", FileMountUserApi = "SYNO.FileStation.VFS.User",
        FileBandwidthApi = "SYNO.Core.BandwidthControl", FileLdapApi = "SYNO.Core.Directory.LDAP", FileDomainApi = "SYNO.Core.Directory.Domain";
    private Task<JsonObject> FileSettingsCall(string api, string method, Dictionary<string, string>? fields, CancellationToken token, int version = 1)
    {
        if (_profile.Id != _session.ProfileId || string.IsNullOrEmpty(_session.Sid) || !HasFixedCapability(api, version)) throw new NotSupportedException("file.settings.unavailable");
        return _api.CallAsync(_profile, _session, FixedCapability(api, version), method, fields, token);
    }
    public async Task<bool> CanWriteFileStationSettingsAsync(CancellationToken token = default)
    {
        if (_profile.Id != _session.ProfileId || string.IsNullOrEmpty(_session.Sid)) return false;
        var access = await LoadFileAdvancedAccessAsync(token).ConfigureAwait(false); return access.Allowed && access.Administrator;
    }
    private async Task RequireFileSettingsWrite(CancellationToken token)
    { if (!await CanWriteFileStationSettingsAsync(token).ConfigureAwait(false)) throw new DsmException("file.settings.denied", "file.settings.refresh", code: 105); }
    public async Task<FileStationGeneralSettings> LoadFileStationSettingsAsync(CancellationToken token = default)
    {
        var d = await FileSettingsCall(FileSettingsApi, "get", null, token).ConfigureAwait(false);
        var limitText = SettingsText(d, "sharing_default_limit");
        if (!limitText.All(char.IsAsciiDigit) || !int.TryParse(limitText, NumberStyles.None, CultureInfo.InvariantCulture, out var limit)) throw SettingsInvalid();
        var value = new FileStationGeneralSettings(ProfileId, SettingsBool(d, "transfer_log_enable"), SettingsBool(d, "use_unix_default_perm"), SettingsBool(d, "enable_list_usergrp"),
            SettingsAccess(SettingsText(d, "sharing_allow")), SettingsAccess(SettingsText(d, "file_request_allow")), SettingsAccess(SettingsText(d, "rf_allow")), SettingsAccess(SettingsText(d, "vd_allow")),
            SettingsMembers(d, "sharing"), SettingsMembers(d, "file_request"), limit, SettingsText(d, "bandwidth_enable") switch
            { "bandwidth_disable" => FileStationBandwidthPolicy.Disabled, "bandwidth_enable" => FileStationBandwidthPolicy.Enabled, "bandwidth_schedule" => FileStationBandwidthPolicy.Scheduled, _ => throw SettingsInvalid() },
            SettingsText(d, "schedule_plan"), d["enable_sharing_custom_setting"] is JsonValue custom && custom.TryGetValue<string>(out var text) ? text switch { "true" => true, "false" => false, _ => (bool?)null } : null);
        if (!value.IsValid) throw SettingsInvalid(); return value;
    }
    private static ImmutableArray<FileStationAccountId> SettingsMembers(JsonObject d, string prefix)
    {
        var enabled = ImmutableArray.CreateBuilder<FileStationAccountId>(); var seen = new HashSet<FileStationAccountId>();
        foreach (var kind in Enum.GetValues<FileSharePrincipalKind>())
        {
            if (d[prefix + (kind == FileSharePrincipalKind.User ? "_privilege" : "_group_privilege")]?["items"] is not JsonArray rows) throw SettingsInvalid();
            foreach (var row in rows)
            {
                if (row is not JsonObject obj) throw SettingsInvalid();
                var id = new FileStationAccountId(kind, SettingsId(obj, kind, false));
                if (!seen.Add(id)) throw SettingsInvalid(); if (SettingsBool(obj, "enabled")) enabled.Add(id);
            }
        }
        return enabled.ToImmutable();
    }
    public async Task<IReadOnlyList<FileStationPolicyAccount>> ListFileStationPolicyAccountsAsync(FileSharePrincipalKind kind, CancellationToken token = default)
    {
        if (!Enum.IsDefined(kind)) throw SettingsInvalid();
        var rows = await FileSettingsPages(FileSharePrincipalsApi, kind == FileSharePrincipalKind.User ? "list_user" : "list_group",
            kind == FileSharePrincipalKind.User ? "users" : "groups", new() { ["type"] = ShareParameterString(FileSharePrincipalsApi, "all"), ["query"] = ShareParameterString(FileSharePrincipalsApi, "") }, token).ConfigureAwait(false);
        var result = rows.Select(d => new FileStationPolicyAccount(new(kind, SettingsId(d, kind, false)), SettingsName(d),
            kind == FileSharePrincipalKind.User ? SettingsBool(d, "is_admin") : StrictBool(d, "is_admin") == true)).ToArray();
        if (result.Select(v => v.Id).Distinct().Count() != result.Length) throw SettingsInvalid(); return result;
    }
    public async Task<FileStationMountAccess> LoadFileStationMountAccessAsync(CancellationToken token = default)
    {
        var data = await FileSettingsCall(FileMountUserApi, "get", new() { ["content"] = ShareParameterString(FileMountUserApi, "user_enabled_type") }, token).ConfigureAwait(false);
        return new(ProfileId, SettingsAccess(SettingsText(data, "user_enabled_type"), true));
    }
    public async Task<FileStationDirectories> LoadFileStationDirectoriesAsync(CancellationToken token = default)
    {
        var items = new List<FileStationDirectory> { new(FileStationDirectoryKind.Local) }; var unavailable = false;
        try { if (SettingsBool(await FileSettingsCall(FileLdapApi, "get", null, token).ConfigureAwait(false), "enable_client")) items.Add(new(FileStationDirectoryKind.Ldap)); }
        catch (OperationCanceledException) { throw; } catch { unavailable = true; }
        try
        {
            if (SettingsBool(await FileSettingsCall(FileDomainApi, "get", null, token).ConfigureAwait(false), "enable_domain"))
            {
                if (!SettingsBool(await FileSettingsCall(FileDomainApi, "test_dc", null, token).ConfigureAwait(false), "test_join_success")) unavailable = true;
                else
                {
                    var data = await FileSettingsCall(FileDomainApi, "get_domain_list", null, token, 2).ConfigureAwait(false);
                    if (data["domain_list"] is not JsonArray { Count: > 0 } rows) throw SettingsInvalid();
                    var domains = new List<FileStationDirectory>();
                    foreach (var row in rows)
                    {
                        string name, value;
                        if (row is JsonValue str && str.TryGetValue<string>(out var scalar)) name = value = scalar;
                        else if (row is JsonArray { Count: >= 2 } array) { name = SettingsString(array[0]); value = SettingsString(array[1]); }
                        else throw SettingsInvalid();
                        if (string.IsNullOrEmpty(name) || string.IsNullOrEmpty(value) || domains.Any(d => d.Value == value)) throw SettingsInvalid();
                        domains.Add(new(FileStationDirectoryKind.Domain, value, name));
                    }
                    items.AddRange(domains);
                }
            }
        }
        catch (OperationCanceledException) { throw; } catch { unavailable = true; }
        return new(items, unavailable);
    }
    public async Task<IReadOnlyList<FileStationMountAccount>> ListFileStationMountAccountsAsync(FileStationDirectory source, FileSharePrincipalKind kind, CancellationToken token = default)
    {
        if (!Enum.IsDefined(kind) || !Enum.IsDefined(source.Kind) || source.Kind == FileStationDirectoryKind.Domain && string.IsNullOrEmpty(source.Value)) throw SettingsInvalid();
        string Text(string s) => ShareParameterString(FileMountUserApi, s);
        var fields = new Dictionary<string, string> { ["content"] = Text(kind == FileSharePrincipalKind.User ? "user_settings" : "group_settings"),
            ["type"] = Text(source.Kind.ToString().ToLowerInvariant()), ["usergroup"] = Text(kind == FileSharePrincipalKind.User ? "user" : "group"), ["substr"] = Text("") };
        if (source.Kind == FileStationDirectoryKind.Domain) fields["domain"] = Text(source.Value);
        var rows = await FileSettingsPages(FileMountUserApi, "get", "usergrp_settings", fields, token).ConfigureAwait(false);
        var result = rows.Select(d => new FileStationMountAccount(ProfileId, source, new(kind, SettingsId(d, kind, true)), SettingsName(d), SettingsBool(d, "enabled"), SettingsBool(d, "is_modifiable"))).ToArray();
        if (result.Select(v => v.Id).Distinct().Count() != result.Length) throw SettingsInvalid(); return result;
    }
    public async Task<IReadOnlyList<FileStationBandwidth>> ListFileStationBandwidthAsync(FileStationBandwidthOwner owner, CancellationToken token = default)
    {
        var ownerText = SettingsOwner(owner);
        var rows = await FileSettingsPages(FileBandwidthApi, "list", "bandwidths", new() { ["protocol"] = ShareParameterString(FileBandwidthApi, "FileStation"), ["owner_type"] = ShareParameterString(FileBandwidthApi, ownerText) }, token).ConfigureAwait(false);
        var result = new List<FileStationBandwidth>();
        foreach (var d in rows)
        {
            if (SettingsText(d, "protocol") != "FileStation" || SettingsText(d, "owner_type") != ownerText) throw SettingsInvalid();
            var entry = new FileStationBandwidth(ProfileId, SettingsName(d), owner, SettingsText(d, "policy") switch
            { "disabled" => FileStationBandwidthPolicy.Disabled, "enabled" => FileStationBandwidthPolicy.Enabled, "scheduled" => FileStationBandwidthPolicy.Scheduled, "notexist" => FileStationBandwidthPolicy.NotConfigured, _ => throw SettingsInvalid() },
                SettingsText(d, "schedule_plan"), SettingsInt(d, "upload_limit_1"), SettingsInt(d, "download_limit_1"), SettingsInt(d, "upload_limit_2"), SettingsInt(d, "download_limit_2"));
            if (!entry.IsValid || result.Any(v => v.Name == entry.Name)) throw SettingsInvalid(); result.Add(entry);
        }
        return result;
    }
    private async Task<IReadOnlyList<JsonObject>> FileSettingsPages(string api, string method, string root, Dictionary<string, string> fields, CancellationToken token)
    {
        var result = new List<JsonObject>(); int? expected = null;
        for (var offset = 0; ;)
        {
            fields["offset"] = offset.ToString(CultureInfo.InvariantCulture); fields["limit"] = "200";
            var d = await FileSettingsCall(api, method, fields, token).ConfigureAwait(false);
            if (StrictInt(d, "total") is not { } total || total < offset || expected.HasValue && expected != total ||
                d.ContainsKey("offset") && StrictInt(d, "offset") != offset || d[root] is not JsonArray rows || rows.Count > 200 || rows.Count > total - offset || rows.Count == 0 && total != offset) throw SettingsInvalid();
            expected = total;
            foreach (var row in rows) result.Add(row as JsonObject ?? throw SettingsInvalid());
            offset += rows.Count; if (offset == total) return result; token.ThrowIfCancellationRequested();
        }
    }
    private static string SettingsOwner(FileStationBandwidthOwner owner) => owner switch { FileStationBandwidthOwner.LocalUser => "local_user", FileStationBandwidthOwner.LocalGroup => "local_group",
        FileStationBandwidthOwner.LdapUser => "ldap_user", FileStationBandwidthOwner.LdapGroup => "ldap_group", FileStationBandwidthOwner.DomainUser => "domain_user", FileStationBandwidthOwner.DomainGroup => "domain_group", _ => throw SettingsInvalid() };
    private static FileStationAccess SettingsAccess(string value, bool mount = false) => value switch { "admin" => FileStationAccess.Administrators, "all" when mount => FileStationAccess.Everyone,
        "everyone" when !mount => FileStationAccess.Everyone, "custom" when mount => FileStationAccess.Selected, "per_user" when !mount => FileStationAccess.Selected, _ => throw SettingsInvalid() };
    private static string SettingsAccessValue(FileStationAccess value, bool mount = false) => value switch { FileStationAccess.Administrators => "admin", FileStationAccess.Everyone => mount ? "all" : "everyone", FileStationAccess.Selected => mount ? "custom" : "per_user", _ => throw SettingsInvalid() };
    private static int SettingsId(JsonObject d, FileSharePrincipalKind kind, bool acceptString)
    {
        var key = kind == FileSharePrincipalKind.User ? "uid" : "gid"; var id = StrictInt(d, key);
        if (id is null && acceptString && d[key] is JsonValue str && str.TryGetValue<string>(out var text) && text.Length > 0 && text.All(char.IsAsciiDigit) && int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)) id = parsed;
        return id is >= 0 ? id.Value : throw SettingsInvalid();
    }
    private static string SettingsName(JsonObject d) => SettingsText(d, "name") is { Length: > 0 } name ? name : throw SettingsInvalid();
    private static string SettingsText(JsonObject d, string key) => SettingsString(d[key]);
    private static string SettingsString(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var str) ? str : throw SettingsInvalid();
    private static bool SettingsBool(JsonObject d, string key) => StrictBool(d, key) ?? throw SettingsInvalid();
    private static int SettingsInt(JsonObject d, string key) => StrictInt(d, key) ?? throw SettingsInvalid();
    private static InvalidDataException SettingsInvalid() => new("file.settings.changed");
}
