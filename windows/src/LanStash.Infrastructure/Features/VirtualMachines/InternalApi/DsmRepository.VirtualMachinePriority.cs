using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 内部 API：官方 VMM 2.6.5-12202 的 get v2 / set v1；公开 Guest API 没有 CPU 权重。
    private const string InternalSettingsGuestApi = "SYNO.Virtualization.Guest";
    public bool CanEditPriority => CanEditSettings && HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 1, 1) &&
        HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2);

    private async Task<VirtualMachineSettings> AddVirtualMachinePriorityAsync(VirtualMachineSettings baseline, CancellationToken token)
    {
        if (!HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2)) return baseline;
        try
        {
            var detail = await ReadInternalVirtualMachineSettingsAsync(baseline.Id, token).ConfigureAwait(false);
            if (detail with { Source = baseline.Source, Configuration = detail.Configuration with { CpuWeight = null } } != baseline) return baseline;
            return detail with { Source = baseline.Source };
        }
        catch (OperationCanceledException) { throw; }
        catch (CertificateTrustChallengeException) { throw; }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error)) { throw; }
        catch { return baseline; } // 附加内部读取失败不得阻断公开基础设置。
    }

    private async Task<VirtualMachineSettings> ReadInternalVirtualMachineSettingsAsync(string id, CancellationToken token)
    {
        EnsureVirtualMachineManagerProfile();
        if (!HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2)) throw UnavailableVirtualMachineManagerError();
        var data = await SecurityCallAsync(_capabilities[InternalSettingsGuestApi] with { MinVersion = 2, MaxVersion = 2 }, "get",
            new Dictionary<string, object> { ["guest_id"] = id }, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (AdvancedText(data, "guest_id") != id) throw InvalidVirtualMachineManagerResponse();
        // 原生 status 决定是否允许硬件编辑；is_online 不能区分关机与过渡状态。
        var status = ParseMachineState(AdvancedText(data, "status"));
        int? Integer(string key, int minimum, int maximum) => OptionalVirtualMachineInteger(data, key, minimum, maximum) is { } number ? (int)number : null;
        var startup = Integer("autorun", 0, 2);
        return new(id, status, new(AdvancedText(data, "name"),
            data.ContainsKey("desc") ? AdvancedText(data, "desc", allowEmpty: true, allowMultiline: true) : null,
            Integer("vcpu_num", 1, 64), data.ContainsKey("vram_size") ? InternalVirtualMachineMemoryMiB(data) : null,
            startup is null ? null : (VirtualMachineAutoStart)startup.Value) { CpuWeight = Integer("cpu_weight", 1, int.MaxValue) })
            { Source = VirtualMachineApiSource.Internal };
    }

    // 官方实测：内部 get/list/get_setting 读 KiB，内部 create/set 与公开 API 用 MiB。
    private static int InternalVirtualMachineMemoryMiB(JsonObject data)
    {
        if (data["vram_size"] is not JsonValue node || !node.TryGetValue<long>(out var kib) || kib <= 0 ||
            kib % 1024 != 0 || kib / 1024 > int.MaxValue) throw InvalidVirtualMachineManagerResponse();
        return (int)(kib / 1024);
    }

    private static Dictionary<string, object> InternalVirtualMachineChanges(IReadOnlyDictionary<string, object> changes, Guid requestId)
    {
        var parameters = changes.ToDictionary(pair => pair.Key switch { "new_guest_name" => "name", "description" => "desc", _ => pair.Key }, pair => pair.Value);
        parameters["synovmm_ui_id"] = requestId.ToString("D");
        return parameters;
    }
}
