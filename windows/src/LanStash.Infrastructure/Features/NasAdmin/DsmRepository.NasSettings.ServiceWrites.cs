using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 已授权用户验证专用写流程；准备结果只证明当前身份/权限，不代表行为验收。
    private long _nasServicePreparationGeneration;
    private bool _nasServiceSessionVerified;
    private bool _nasServiceAdministrator;
    private static readonly ConditionalWeakTable<IDsmApiClient, NasServiceMutationState> NasServiceMutations = new();
    private NasServiceMutationState ServiceMutations => NasServiceMutations.GetValue(_api, _ => new());

    public async Task<NasSettingsWriteAvailability> PrepareServiceSettingsAsync(CancellationToken cancellationToken = default)
    {
        var generation = Interlocked.Increment(ref _nasServicePreparationGeneration);
        _nasServiceSessionVerified = false;
        _nasServiceAdministrator = false;
        cancellationToken.ThrowIfCancellationRequested();
        if (_profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) ||
            !_capabilities.TryGetValue("SYNO.Core.Desktop.Initdata", out var capability) ||
            capability.Name != "SYNO.Core.Desktop.Initdata" || capability.MinVersion < 1 || capability.MinVersion > 1 || capability.MaxVersion < 1 ||
            !NasServiceFormatAndPathSupported(capability)) return NasSettingsWriteAvailability;
        try
        {
            var data = await _api.CallAsync(_profile, _session,
                capability with { Path = "entry.cgi", MinVersion = 1, MaxVersion = 1 },
                "get_user_service", cancellationToken: cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (generation != Volatile.Read(ref _nasServicePreparationGeneration)) return NasSettingsWriteAvailability;
            var session = data["Session"] as JsonObject;
            if (session?["is_admin"] is JsonValue admin && admin.TryGetValue<bool>(out var administrator))
            {
                _nasServiceAdministrator = administrator;
                _nasServiceSessionVerified = true;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception)
        {
            // 只关闭这些设置的写能力，不阻断用户读取或其他模块。
        }
        return NasSettingsWriteAvailability;
    }

    public Task<MutationResult> SaveTerminalSettingsAsync(NasServiceSettingsSaveRequest<NasTerminalSettings> request,
        CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanSaveTerminal ? ExecuteTerminalSettingsWriteAsync(request, cancellationToken) :
            Task.FromResult(UnsupportedResult("saveTerminal"));

    public Task<MutationResult> SaveProxySettingsAsync(NasServiceSettingsSaveRequest<NasProxySettings> request,
        CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanSaveProxy ? ExecuteProxySettingsWriteAsync(request, cancellationToken) :
            Task.FromResult(UnsupportedResult("saveProxy"));

    // 内部核心供上述生产门调用；正式合成 HTTP 测试也验证同一核心，不修改生产门。
    internal Task<MutationResult> ExecuteTerminalSettingsWriteAsync(NasServiceSettingsSaveRequest<NasTerminalSettings> request,
        CancellationToken cancellationToken = default) => ExecuteServiceSettingsWriteAsync(request, NasServiceSettingsKind.Terminal, cancellationToken);
    internal Task<MutationResult> ExecuteProxySettingsWriteAsync(NasServiceSettingsSaveRequest<NasProxySettings> request,
        CancellationToken cancellationToken = default) => ExecuteServiceSettingsWriteAsync(request, NasServiceSettingsKind.Proxy, cancellationToken);

    private async Task<MutationResult> ExecuteServiceSettingsWriteAsync<T>(NasServiceSettingsSaveRequest<T> request,
        NasServiceSettingsKind kind, CancellationToken token) where T : class
    {
        var operation = ServiceOperationName(kind);
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid) ||
            !ValidServiceSettings(request.Baseline, request.Desired, kind))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = NasServiceCapability(kind);
        if (capability is null) return UnsupportedResult(operation);
        var baseline = ServiceFields(request.Baseline, kind, request.Desired);
        var desired = ServiceFields(request.Desired, kind, request.Desired);
        var fields = desired.Keys.Where(key => !Equals(baseline.GetValueOrDefault(key), desired[key])).ToArray();
        if (fields.Length == 0) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind, baseline, desired }));
        var shared = ServiceMutations;
        try
        {
            if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
            {
                if (previous.Scope != scope || previous.Signature != signature)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false);
            }
            if (shared.Pending.ContainsKey((scope, kind)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                // 固定同一 capability/版本读取，原值变化、权限拒绝或不完整快照都不允许覆盖。
                var current = await ReadServiceFieldsAsync(capability, kind, request.Desired, token).ConfigureAwait(false);
                if (baseline.Any(pair => !Equals(pair.Value, current.GetValueOrDefault(pair.Key))))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error)
            {
                return ServicePreflightFailure(operation, ServiceErrorCategory(error));
            }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasServiceOperation(scope, signature, kind, capability, desired, fields);
            shared.Operations.Add(request.RequestId, state);
            shared.Pending.Add((scope, kind), state);
            var json = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
            var parameters = desired.Where(pair => pair.Value is not null).ToDictionary(pair => pair.Key,
                pair => pair.Value is string text && !json ? text : JsonSerializer.Serialize(pair.Value), StringComparer.Ordinal);
            try
            {
                await _api.CallAsync(_profile, _session, capability, "set", parameters, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                state.Rejection = ServiceErrorCategory(error);
            }
            catch (Exception)
            {
                // 请求开始后断线/取消不能证明未生效；不得自动重放。
            }
            return await ReviewServiceOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewServiceSettingsAsync(NasServiceSettingsKind kind,
        CancellationToken cancellationToken = default)
    {
        if (kind == NasServiceSettingsKind.Ethernet)
            return await ReviewEthernetSettingsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!Enum.IsDefined(kind) || _profile.Id != _session.ProfileId)
            return ServicePreflightFailure(ServiceOperationName(kind), MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        var operation = ServiceOperationName(kind);
        try
        {
            if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            return shared.Pending.TryGetValue((ServiceScope(), kind), out var state)
                ? await ReviewNasSettingsOperationAsync(state, cancellationToken).ConfigureAwait(false) : null;
        }
        finally { shared.Gate.Release(); }
    }

    private Task<MutationResult> ReviewNasSettingsOperationAsync(NasSettingsOperation state, CancellationToken token) =>
        state is ContainerImagePullOperation imagePull ? ReviewContainerImagePullMutationAsync(imagePull, token) :
        state is ContainerImageDeleteOperation imageDelete ? ReviewContainerImageDeletionAsync(imageDelete, token) :
        state is ContainerMutationOperation container ? ReviewContainerOperationAsync(container, token) :
        state is ContainerNetworkDeleteOperation networkDelete ? ReviewContainerNetworkDeletionAsync(networkDelete, token) :
        state is ContainerNetworkCreateOperation networkCreate ? ReviewContainerNetworkCreationAsync(networkCreate, token) :
        state is NasRemoteAccessOperation remoteAccess ? ReviewRemoteAccessOperationAsync(remoteAccess, token) :
        state is NasDiskTestOperation disk ? ReviewDiskTestOperationAsync(disk, 1, token, false, Task.Delay) :
        state is NasTaskSaveOperation taskSave ? ReviewTaskSaveOperationAsync(taskSave, token) :
        state is NasTaskCommandOperation task ? ReviewTaskOperationAsync(task, token) :
        state is NasConnectionOperation connection ? ReviewConnectionOperationAsync(connection, 1, token, Task.Delay) :
        state is NasPowerOperation power ? Task.FromResult(power.Final!) :
        state is NasDirectorySaveOperation savedDirectory ? ReviewDirectorySaveAsync(savedDirectory, token) :
        state is NasDirectoryDeletionOperation directory ? ReviewDirectoryDeletionAsync(directory, token) :
        state is NasPackageOperation package ? ReconcilePackageAsync(package, 1, token, false, Task.Delay) :
        state is NasDdnsOperation ddns ? ReviewDdnsOperationAsync(ddns, token) :
        state is NasHardwareOperation hardware ? ReviewHardwareOperationAsync(hardware, token) :
        state is NasSecurityOperation security ? ReviewSecurityOperationAsync(security, token) :
        state is NasEthernetOperation ethernet ? ReviewEthernetOperationAsync(ethernet, false, token) :
        state is NasRegionOperation region ? ReviewRegionOperationAsync(region, token) :
        state is NasFileServiceOperation file ? ReviewFileServiceOperationAsync(file, token) :
            ReviewServiceOperationAsync((NasServiceOperation)state, token);

    private async Task<MutationResult> ReviewServiceOperationAsync(NasServiceOperation state, CancellationToken token)
    {
        var operation = ServiceOperationName(state.Kind);
        if (token.IsCancellationRequested)
            return new(1, MutationResultStatus.CancellationRequestedAfterSubmission, operation, true, true,
                new(0, 0, state.Fields.Length), MutationErrorCategory.Network);
        Dictionary<string, object?> current;
        try
        {
            var data = await _api.CallReadJsonObjectAsync(_profile, _session, state.Capability,
                state.Capability.MaxVersion, "get", cancellationToken: token).ConfigureAwait(false);
            current = state.Kind == NasServiceSettingsKind.Terminal
                ? ServiceFields(ParseNasTerminalSettings(data), state.Kind, null)
                : ProxyFields(ParseNasProxySettings(data), state.Desired.ContainsKey("http_host"));
        }
        catch (Exception)
        {
            return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
                MutationResultStatus.SubmittedButUnverified, operation, true, true,
                new(0, 0, state.Fields.Length), MutationErrorCategory.Network);
        }
        var succeeded = state.Fields.Count(field => Equals(state.Desired.GetValueOrDefault(field), current.GetValueOrDefault(field)));
        var unknown = state.Fields.Count(field => !current.ContainsKey(field) || current[field] is null);
        // 明确拒绝不能因其他客户端同时改变设置而被归为本次成功。
        var result = state.Rejection is { } rejection
            ? new MutationResult(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
                MutationResultStatus.ConfirmedFailure, operation, true, false, new(0, state.Fields.Length, 0), rejection)
            : new MutationResult(1, succeeded == state.Fields.Length ? MutationResultStatus.ConfirmedSuccess :
                succeeded > 0 ? MutationResultStatus.PartialSuccess : unknown > 0 ? MutationResultStatus.SubmittedButUnverified :
                MutationResultStatus.ConfirmedFailure,
                operation, true, succeeded != state.Fields.Length, new(succeeded, state.Fields.Length - succeeded - unknown, unknown),
                succeeded == state.Fields.Length ? null : MutationErrorCategory.Server);
        if (result.Counts.Unknown == 0)
        {
            state.Final = result;
            ServiceMutations.Pending.Remove((state.Scope, state.Kind));
        }
        return result;
    }

    private async Task<Dictionary<string, object?>> ReadServiceFieldsAsync(ApiCapability capability,
        NasServiceSettingsKind kind, object desired, CancellationToken token)
    {
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability,
            capability.MaxVersion, "get", cancellationToken: token).ConfigureAwait(false);
        return kind == NasServiceSettingsKind.Terminal ? ServiceFields(ParseNasTerminalSettings(data), kind, desired) :
            ServiceFields(ParseNasProxySettings(data), kind, desired);
    }

    private ApiCapability? NasServiceCapability(NasServiceSettingsKind kind)
    {
        var name = kind == NasServiceSettingsKind.Terminal ? "SYNO.Core.Terminal" : "SYNO.Core.Network.Proxy";
        var maximum = kind == NasServiceSettingsKind.Terminal ? 3 : 1;
        if (!_capabilities.TryGetValue(name, out var capability) || capability.Name != name ||
            capability.MinVersion < 1 || capability.MinVersion > maximum ||
            capability.MaxVersion < capability.MinVersion || !NasServiceFormatAndPathSupported(capability)) return null;
        var version = Math.Min(maximum, capability.MaxVersion);
        return capability with { Path = "entry.cgi", MinVersion = version, MaxVersion = version };
    }

    private static bool NasServiceFormatAndPathSupported(ApiCapability capability) =>
        capability.Path is "entry.cgi" or "/webapi/entry.cgi" or "webapi/entry.cgi" &&
        (capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
         capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

    private static bool ValidServiceSettings(object? baseline, object? desired, NasServiceSettingsKind kind) =>
        kind switch
        {
            NasServiceSettingsKind.Terminal => baseline is NasTerminalSettings b && desired is NasTerminalSettings d &&
                b.TelnetPort is null && d.TelnetPort is null &&
                (b.SshPort is null ? d.SshPort is null : b.SshPort is > 0 and <= 65535 && d.SshPort is > 0 and <= 65535),
            NasServiceSettingsKind.Proxy => baseline is NasProxySettings && desired is NasProxySettings p &&
                (!p.Enabled || (p.Port is > 0 and <= 65535 && !string.IsNullOrWhiteSpace(p.Host) &&
                    !p.Host.Trim().Any(char.IsWhiteSpace) && p.Host.IndexOfAny(['/', '\\', '?', '#', '@']) < 0 &&
                    Uri.CheckHostName(p.Host.Trim()) != UriHostNameType.Unknown)),
            _ => false,
        };

    private static Dictionary<string, object?> ServiceFields(object value, NasServiceSettingsKind kind, object? desired)
    {
        if (value is NasTerminalSettings terminal)
        {
            var fields = new Dictionary<string, object?> { ["enable_ssh"] = terminal.SshEnabled, ["enable_telnet"] = terminal.TelnetEnabled };
            if (terminal.SshPort is not null) fields["ssh_port"] = terminal.SshPort;
            return fields;
        }
        return ProxyFields((NasProxySettings)value, desired is NasProxySettings { Enabled: true });
    }

    private static Dictionary<string, object?> ProxyFields(NasProxySettings proxy, bool address)
    {
        var fields = new Dictionary<string, object?> { ["enable"] = proxy.Enabled };
        if (address) { fields["http_host"] = proxy.Host?.Trim(); fields["http_port"] = proxy.Port; }
        return fields;
    }

    private string ServiceScope() => ServiceHash(JsonSerializer.Serialize(new { _profile.Id, _profile.Username, Address = _api.GetBaseUri(_profile).AbsoluteUri }));
    private static string ServiceHash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    private static string ServiceOperationName(NasServiceSettingsKind kind) => kind switch
    {
        NasServiceSettingsKind.Terminal => "saveTerminal",
        NasServiceSettingsKind.FileServices => "saveFileService",
        NasServiceSettingsKind.Region => "saveRegion",
        NasServiceSettingsKind.Ethernet => "saveNetwork",
        NasServiceSettingsKind.Security => "saveSecurity",
        NasServiceSettingsKind.Hardware => "saveHardware",
        NasServiceSettingsKind.Ddns => "ddnsMutation",
        NasServiceSettingsKind.Packages => "controlPackage",
        NasServiceSettingsKind.Directory => "deleteDirectoryEntry",
        NasServiceSettingsKind.Power => "powerAction",
        NasServiceSettingsKind.Connections => "disconnectConnection",
        NasServiceSettingsKind.Tasks => "taskCommand",
        NasServiceSettingsKind.DiskTests => "diskTest",
        NasServiceSettingsKind.RemoteAccess => "saveRemoteAccess",
        NasServiceSettingsKind.ContainerNetworks => "createContainerNetwork",
        NasServiceSettingsKind.ContainerLifecycle => "containerMutation",
        NasServiceSettingsKind.ContainerImages => "deleteContainerImages",
        NasServiceSettingsKind.ContainerImagePull => "pullContainerImage",
        _ => "saveProxy",
    };
    private static MutationErrorCategory ServiceErrorCategory(DsmException error) => error.AuthenticationFailure ?
        MutationErrorCategory.Authentication : error.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server;
    private static MutationResult ServicePreflightFailure(string operation, MutationErrorCategory category, bool refresh = false) =>
        new(1, MutationResultStatus.ConfirmedFailure, operation, false, refresh, new(0, 1, 0), category);

    private sealed class NasServiceMutationState
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Dictionary<Guid, NasSettingsOperation> Operations { get; } = [];
        public Dictionary<(string Scope, NasServiceSettingsKind Kind), NasSettingsOperation> Pending { get; } = [];
        public Dictionary<(string Scope, string PackageId), NasPackageOperation> PackagePending { get; } = [];
        public Dictionary<(string Scope, NasDirectoryKind Kind, string Name), NasDirectoryOperation> DirectoryPending { get; } = [];
        public Dictionary<(string Scope, string TargetKey), NasConnectionOperation> ConnectionPending { get; } = [];
        public Dictionary<(string Scope, int Id), NasTaskCommandOperation> TaskPending { get; } = [];
        public Dictionary<Guid, NasTaskSaveOperation> TaskSavePending { get; } = [];
        public Dictionary<(string Scope, string Id), NasDiskTestOperation> DiskTestPending { get; } = [];
        public Dictionary<(string Scope, string Name), ContainerNetworkCreateOperation> NetworkCreations { get; } = [];
        public Dictionary<(string Scope, string Id), ContainerNetworkDeleteOperation> NetworkDeletions { get; } = [];
        public Dictionary<(string Scope, string Id), ContainerMutationOperation> ContainerPending { get; } = [];
        public Dictionary<Guid, ContainerImageDeleteOperation> ImageDeletions { get; } = [];
        public Dictionary<Guid, ContainerImagePullOperation> ImagePulls { get; } = [];
        public Dictionary<(string Scope, string Path), FavoriteMutationOperation> FavoritePending { get; } = [];
        public Dictionary<Guid, RemoteMountOperation> RemoteMountOperations { get; } = [];
    }
    private abstract class NasSettingsOperation(string scope, string signature, NasServiceSettingsKind kind)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public NasServiceSettingsKind Kind { get; } = kind;
        public MutationResult? Final { get; set; }
    }
    private sealed class NasServiceOperation(string scope, string signature, NasServiceSettingsKind kind,
        ApiCapability capability, Dictionary<string, object?> desired, string[] fields) : NasSettingsOperation(scope, signature, kind)
    {
        public ApiCapability Capability { get; } = capability;
        public Dictionary<string, object?> Desired { get; } = desired;
        public string[] Fields { get; } = fields;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
