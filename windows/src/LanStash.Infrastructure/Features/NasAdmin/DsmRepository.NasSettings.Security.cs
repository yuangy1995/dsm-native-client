using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // DSM 内部安全配置按独立分区读取；不能把错误映射成保护已关闭。
    public async Task<NasSecuritySettings> LoadSecuritySettingsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = new NasSecuritySettings(null, null, null, null, null, null, null);
        var any = false;
        foreach (var (name, section) in new[]
        {
            ("SYNO.Core.Security.AutoBlock", NasSecuritySections.AutoBlock),
            ("SYNO.Core.Security.Firewall", NasSecuritySections.Firewall),
            ("SYNO.Core.Security.Firewall.Conf", NasSecuritySections.PortScan),
            ("SYNO.Core.Security.DoS", NasSecuritySections.Dos),
        })
        {
            if (!_capabilities.ContainsKey(name)) continue;
            any = true; cancellationToken.ThrowIfCancellationRequested();
            try
            {
                if (section == NasSecuritySections.Dos)
                {
                    var rows = await LoadDosProtectionAsync(cancellationToken).ConfigureAwait(false);
                    var aggregate = rows.Count == 0 || rows.Any(row => row.Enabled != rows[0].Enabled) ? (bool?)null : rows[0].Enabled;
                    result = result with { DosProtection = rows, DosProtectionEnabled = aggregate };
                }
                else
                {
                    var data = await ReadNasServiceSettingsAsync(name, 1, cancellationToken).ConfigureAwait(false);
                    switch (section)
                    {
                        case NasSecuritySections.AutoBlock:
                            var enabled = data.Bool("enable"); var attempts = data.Int("attempts");
                            var minutes = data.Int("within_mins"); var expiry = data.Int("expire_day");
                            result = result with { AutoBlockEnabled = enabled,
                                AutoBlockFailedAttempts = attempts is > 0 ? attempts : null,
                                AutoBlockWithinMinutes = minutes is > 0 ? minutes : null,
                                AutoBlockExpiryDays = expiry is >= 0 ? expiry : null };
                            if (enabled is null || attempts is not > 0 || minutes is not > 0 || expiry is not >= 0)
                                throw InvalidNasServiceSettings();
                            break;
                        case NasSecuritySections.Firewall:
                            result = result with { FirewallEnabled = data.Bool("enable_firewall"), FirewallProfileName = data.String("profile_name") };
                            if (result.FirewallEnabled is null) throw InvalidNasServiceSettings();
                            break;
                        case NasSecuritySections.PortScan:
                            result = result with { PortScanEnabled = data.Bool("enable_port_check") };
                            if (result.PortScanEnabled is null) throw InvalidNasServiceSettings();
                            break;
                    }
                }
                result = result with { AvailableSections = result.AvailableSections | section };
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception) { result = result with { FailedSections = result.FailedSections | section }; }
        }
        if (!any) throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        return result;
    }

    private async Task<IReadOnlyList<NasDoSProtectionSetting>> LoadDosProtectionAsync(CancellationToken token)
    {
        if (!_capabilities.TryGetValue("SYNO.Core.Security.DoS", out var dos) || dos.Name != "SYNO.Core.Security.DoS" ||
            dos.MinVersion > 2 || dos.MaxVersion < 2 ||
            !_capabilities.TryGetValue("SYNO.Core.Network.Ethernet", out var ethernet) || ethernet.Name != "SYNO.Core.Network.Ethernet" ||
            ethernet.MinVersion > 2 || ethernet.MaxVersion < 2) throw InvalidNasServiceSettings();
        var adapters = await _api.CallReadJsonObjectAsync(_profile, _session, ethernet, 2, "list",
            cancellationToken: token).ConfigureAwait(false);
        var list = adapters["interfaces"] as JsonArray ?? adapters["adapters"] as JsonArray ?? throw InvalidNasServiceSettings();
        var names = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in list)
        {
            if (item is not JsonObject row) throw InvalidNasServiceSettings();
            var id = row.String("id") ?? row.String("ifname") ?? row.String("name");
            if (string.IsNullOrWhiteSpace(id) || !id.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-'))
                throw InvalidNasServiceSettings();
            names[id] = row.String("display") ?? row.String("display_name") ?? id;
        }
        if (names.Count == 0) return [];
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, dos, 2, "get",
            new Dictionary<string, string> { ["configs"] = JsonSerializer.Serialize(names.Keys.Select(id => new { adapter = id })) }, token).ConfigureAwait(false);
        if (data["configs"] is not JsonArray configs) throw InvalidNasServiceSettings();
        var values = new Dictionary<string, bool>(StringComparer.Ordinal);
        foreach (var item in configs)
        {
            if (item is not JsonObject row || row.String("adapter") is not { } id ||
                row.Bool("dos_protect_enable") is not bool enabled) throw InvalidNasServiceSettings();
            if (names.ContainsKey(id)) values[id] = enabled; // 已记录的重复响应以后返回状态为准。
        }
        if (names.Keys.Any(id => !values.ContainsKey(id))) throw InvalidNasServiceSettings();
        return Array.AsReadOnly(names.Select(pair => new NasDoSProtectionSetting(pair.Key, pair.Value, values[pair.Key])).ToArray());
    }

    public Task<MutationResult> SaveSecuritySettingsAsync(NasSecuritySettings settings, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // 旧签名既没有完整基线也没有配置档任务恢复，绝不能启动后台任务后直接宣称成功。
        return Task.FromResult(UnsupportedResult("saveSecurity"));
    }
}
