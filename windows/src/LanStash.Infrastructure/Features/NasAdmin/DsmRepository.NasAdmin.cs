using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasSettingsSnapshot> LoadNasSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        var system = await TryCallFirstAsync("SYNO.Core.System", ["info", "get"], cancellationToken)
            .ConfigureAwait(false);
        var storage = await TryCallFirstAsync(
            "SYNO.Storage.CGI.Storage",
            ["load_info", "get"],
            cancellationToken).ConfigureAwait(false);
        var packages = await TryLoadResourcesAsync("SYNO.Core.Package", "packages", cancellationToken)
            .ConfigureAwait(false);
        var users = await TryLoadResourcesAsync("SYNO.Core.User", "users", cancellationToken)
            .ConfigureAwait(false);
        var groups = await TryLoadResourcesAsync("SYNO.Core.Group", "groups", cancellationToken)
            .ConfigureAwait(false);
        var logData = await TryCallFirstAsync(
            PreferredOptional("SYNO.LogCenter.History", "SYNO.Core.SyslogClient.Log"),
            ["list", "get"],
            cancellationToken).ConfigureAwait(false);
        var connections = await TryLoadResourcesAsync(
            "SYNO.Core.CurrentConnection",
            "connections",
            cancellationToken).ConfigureAwait(false);
        var networks = await TryLoadResourcesAsync(
            "SYNO.Core.Network.Ethernet",
            "interfaces",
            cancellationToken).ConfigureAwait(false);
        return new NasSettingsSnapshot(
            system is null ? null : new SystemOverview(
                system.String("server_name") ?? system.String("hostname") ?? "NAS",
                system.String("model"),
                system.String("firmware_ver") ?? system.String("version"),
                system.Long("up_time") ?? system.Long("uptime"),
                system.String("cpu_model"),
                system.Long("ram_size") ?? system.Long("memory_size")),
            storage is null ? [] : ParseResources(storage, "volumes"),
            storage is null ? [] : ParseResources(storage, "storagePools", "pools"),
            storage is null ? [] : ParseResources(storage, "disks"),
            packages,
            users,
            groups,
            logData is null ? [] : ParseLogs(logData),
            connections,
            networks,
            await LoadSecurityAsync(cancellationToken).ConfigureAwait(false));
    }

    private async Task<IReadOnlyList<ResourceItem>> LoadSecurityAsync(
        CancellationToken cancellationToken)
    {
        var result = new List<ResourceItem>();
        foreach (var (apiName, title) in new[]
        {
            ("SYNO.Core.Security.AutoBlock", UserText.Key("WinSharedb4ffcaefff280faf")),
            ("SYNO.Core.Security.DoS", UserText.Key("WinShareda167a95b73b968b4")),
            ("SYNO.Core.Security.Firewall", UserText.Key("WinSharedeee30e9d97ca1e61")),
        })
        {
            var data = await TryCallFirstAsync(apiName, ["get", "list"], cancellationToken)
                .ConfigureAwait(false);
            if (data is null)
            {
                continue;
            }
            var enabled = data.Bool("enable") ?? data.Bool("enabled");
            result.Add(new ResourceItem(
                apiName,
                title,
                enabled is false ? UserText.Key("WinShared6744b4c6a9aa0038") : UserText.Key("WinShared8a4ef3e48e4e8a5a"),
                enabled is false ? ResourceState.Warning : ResourceState.Healthy));
        }
        return result;
    }

}
