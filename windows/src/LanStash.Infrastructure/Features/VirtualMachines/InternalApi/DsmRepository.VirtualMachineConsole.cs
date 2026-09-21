using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 由实际建立连接的组合根提供；旧调用者默认不能向网页组件释放会话凭据。
    public bool ConsoleUsesSystemTrust { private get; init; }
    private const string InternalConsoleGeneralApi = "SYNO.Virtualization.Setting.General";
    private bool CanUseManagedConsole
    {
        get
        {
            if (!_api.CanReadConsoleAssets || !_api.CanConnectConsoleSocket) return false;
            var origin = _api.GetBaseUri(_profile);
            return VirtualMachineConsolePolicy.IsSupportedOrigin(origin);
        }
    }
    public bool CanOpenConsole => (ConsoleUsesSystemTrust || CanUseManagedConsole) && _profile.Id != Guid.Empty && HasAuthenticatedVirtualMachineSession && VirtualMachineConsoleSession.ValidCookie(_session.Sid) &&
        (string.IsNullOrWhiteSpace(_session.SynoToken) || VirtualMachineConsoleSession.ValidCookie(_session.SynoToken)) && _api.CanReadConsoleDocument &&
        HasPublicVirtualMachineVersion(PublicGuestApi) && HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2);

    public async Task<VirtualMachineConsoleSession> OpenConsoleAsync(VirtualMachineSummary baseline, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!CanOpenConsole) throw new DsmException(UserText.Key("VmConsoleUnavailable"), UserText.Key("VmConsoleReconnect"));
        if (!VirtualMachinePowerRules.CanRequest(baseline, VirtualMachinePowerAction.Shutdown))
            throw new DsmException(UserText.Key("VmConsoleNeedsRunning"), UserText.Key("VmConsoleRefresh"));
        var state = VmMutations;
        if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            throw new DsmException(UserText.Key("VmConsoleBusy"), UserText.Key("VmConsoleRefresh"));
        try
        {
            var scope = ServiceScope();
            if (state.DeletionPending.ContainsKey((scope, baseline.Id)) || state.PowerPending.ContainsKey((scope, baseline.Id)) ||
                state.SettingsPending.ContainsKey((scope, baseline.Id)) || HasPendingVirtualMachineCreation(scope, baseline.Id, baseline.Name))
                throw new DsmException(UserText.Key("VmConsoleBusy"), UserText.Key("VmConsoleRefresh"));
            var current = await ReadVirtualMachinePowerTargetAsync(baseline.Id, cancellationToken).ConfigureAwait(false);
            if (current.Status != "running" || current.Name != baseline.Name)
                throw new DsmException(UserText.Key("VmConsoleTargetChanged"), UserText.Key("VmConsoleRefresh"));
            var detail = await SecurityCallAsync(_capabilities[InternalSettingsGuestApi] with { MinVersion = 2, MaxVersion = 2 }, "get",
                new() { ["guest_id"] = baseline.Id }, cancellationToken).ConfigureAwait(false);
            static string Text(JsonObject data, string key) => data[key] is JsonValue node && node.TryGetValue<string>(out var value) &&
                !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl) ? value : throw InvalidVirtualMachineManagerResponse();
            if (Text(detail, "guest_id") != baseline.Id || Text(detail, "name") != baseline.Name ||
                detail["is_online"] is not JsonValue onlineValue || !onlineValue.TryGetValue<bool>(out var online) || !online)
                throw InvalidVirtualMachineManagerResponse();
            var keyboard = Text(detail, "kb_layout");
            if (keyboard == "Default")
            {
                if (!HasInternalVirtualMachineVersion(InternalConsoleGeneralApi, 1, 1)) throw UnavailableVirtualMachineManagerError();
                var general = await SecurityCallAsync(_capabilities[InternalConsoleGeneralApi] with { MinVersion = 1, MaxVersion = 1 }, "get", new(), cancellationToken).ConfigureAwait(false);
                keyboard = Text(general, "kb_layout");
                if (keyboard == "Default") throw InvalidVirtualMachineManagerResponse();
            }
            var policy = VirtualMachineConsolePolicy.Create(_api.GetBaseUri(_profile), baseline.Id, baseline.Name, keyboard, Guid.NewGuid());
            cancellationToken.ThrowIfCancellationRequested();
            return new(_profile.Id, baseline.Id, baseline.Name, policy, _session.Sid,
                token => _api.ReadConsoleDocumentAsync(_profile, _session, policy, token),
                ConsoleUsesSystemTrust ? null : (uri, token) => _api.ReadConsoleAssetAsync(_profile, _session, policy, uri, token),
                ConsoleUsesSystemTrust ? null : token => _api.ConnectConsoleSocketAsync(_profile, _session, policy, token));
        }
        finally { state.Gate.Release(); }
    }
}
