using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private ApiCapability RequireDdnsRead(string name)
    {
        foreach (var required in new[] { "SYNO.Core.DDNS.Provider", "SYNO.Core.DDNS.Record" })
            if (!_capabilities.TryGetValue(required, out var item) || item.Name != required ||
                item.MinVersion != 1 || item.MaxVersion < 1 ||
                !(item.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || item.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)))
                throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        return _capabilities[name];
    }

    public async Task<IReadOnlyList<NasDDNSProvider>> LoadDDNSProvidersAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, RequireDdnsRead("SYNO.Core.DDNS.Provider"),
            1, "list", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (data["providers"] is not JsonArray rows) throw InvalidNasServiceSettings();
        var providers = new Dictionary<string, NasDDNSProvider>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var id = OptionalDdnsText(row, "id") ?? OptionalDdnsText(row, "provider");
            if (!StableDdnsIdentity(id)) throw InvalidNasServiceSettings();
            var display = OptionalDdnsText(row, "display") ?? OptionalDdnsText(row, "name");
            if (string.IsNullOrWhiteSpace(display)) display = id;
            var provider = new NasDDNSProvider(id!, display!, null);
            // 同服务商可能按协议重复，身份不变；只在旧显示名等于身份时采用更友好名称。
            if (!providers.TryGetValue(id!, out var previous) || previous.Name == previous.Id && provider.Name != provider.Id)
                providers[id!] = provider;
        }
        return Array.AsReadOnly(providers.Values.ToArray());
    }

    public async Task<IReadOnlyList<NasDDNSRecord>> LoadDDNSRecordsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, RequireDdnsRead("SYNO.Core.DDNS.Record"),
            1, "list", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (data["records"] is not JsonArray rows) throw InvalidNasServiceSettings();
        var result = new List<NasDDNSRecord>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var provider = OptionalDdnsText(row, "provider"); var hostname = OptionalDdnsText(row, "hostname");
            var username = OptionalDdnsText(row, "username");
            if (!StableDdnsIdentity(provider) || !StableDdnsIdentity(hostname) || username is null ||
                row.Bool("enable") is not bool enabled || row.Bool("heartbeat") is not bool heartbeat || !seen.Add(provider!))
                throw InvalidNasServiceSettings();
            result.Add(new(provider!, provider!, hostname!, username, OptionalDdnsText(row, "ip"),
                OptionalDdnsMetadata(row, "status"), enabled, heartbeat)
            {
                NetworkType = OptionalDdnsText(row, "net"), Ipv6 = OptionalDdnsText(row, "ipv6"),
                InterfaceV4 = OptionalDdnsText(row, "interface_v4"), InterfaceV6 = OptionalDdnsText(row, "interface_v6"),
                LastUpdated = OptionalDdnsMetadata(row, "lastupdated"),
            });
        }
        return result.AsReadOnly();
    }

    private static bool StableDdnsIdentity(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
    private static string? OptionalDdnsMetadata(JsonObject data, string key) => data[key] is JsonValue value
        ? value.TryGetValue<string>(out var text) ? text : value.ToJsonString() : null;
    private static string? OptionalDdnsText(JsonObject data, string key)
    {
        if (!data.TryGetPropertyValue(key, out var value) || value is null) return null;
        return value is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : throw InvalidNasServiceSettings();
    }

    public Task<MutationResult> SaveDDNSRecordAsync(NasDDNSDraft draft, string? existingRecordId = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(draft);
        return Task.FromResult(draft.IsValidForSubmission ? UnsupportedResult("saveDDNS") :
            ServicePreflightFailure("saveDDNS", MutationErrorCategory.Validation));
    }
    public Task<MutationResult> DeleteDDNSRecordAsync(string recordId, CancellationToken cancellationToken = default) =>
        Task.FromResult(StableDdnsIdentity(recordId) ? UnsupportedResult("deleteDDNS") : ServicePreflightFailure("deleteDDNS", MutationErrorCategory.Validation));
    public Task<MutationResult> TestDDNSRecordAsync(string recordId, CancellationToken cancellationToken = default) =>
        Task.FromResult(StableDdnsIdentity(recordId) ? UnsupportedResult("testDDNS") : ServicePreflightFailure("testDDNS", MutationErrorCategory.Validation));
    public Task<MutationResult> UpdateDDNSAddressAsync(string recordId, CancellationToken cancellationToken = default) =>
        Task.FromResult(StableDdnsIdentity(recordId) ? UnsupportedResult("updateDDNSAddress") : ServicePreflightFailure("updateDDNSAddress", MutationErrorCategory.Validation));
}
