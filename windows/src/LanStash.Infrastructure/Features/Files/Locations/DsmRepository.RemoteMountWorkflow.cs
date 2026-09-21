using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanManageRemoteMountWorkflow => _profile.Id != Guid.Empty && _profile.Id == _session.ProfileId &&
        !string.IsNullOrWhiteSpace(_session.Sid) && _api is IFileLocationMutationTransport &&
        RemoteWorkflowCapability("SYNO.FileStation.Mount", 1) && RemoteWorkflowCapability("SYNO.FileStation.Mount.List", 1) &&
        RemoteWorkflowCapability("SYNO.FileStation.List", 2);

    public Task<RemoteMountProgress> StartRemoteMountOperationAsync(RemoteMountMutationRequest request, CancellationToken cancellationToken = default) =>
        ExecuteRemoteMountWorkflowAsync(request, continueConfirmed: false, cancellationToken);
    public Task<RemoteMountProgress> ContinueRemoteMountOperationAsync(RemoteMountMutationRequest request, CancellationToken cancellationToken = default) =>
        ExecuteRemoteMountWorkflowAsync(request, continueConfirmed: true, cancellationToken);

    private async Task<RemoteMountProgress> ExecuteRemoteMountWorkflowAsync(RemoteMountMutationRequest request, bool continueConfirmed, CancellationToken token)
    {
        RemoteMountProgress Reject(MutationErrorCategory category, MutationResultStatus status = MutationResultStatus.ConfirmedFailure) =>
            new(request?.RequestId ?? Guid.Empty, request?.Action ?? RemoteMountAction.Create, request?.Desired?.MountPoint ?? request?.Baseline?.MountPoint ?? "",
                request?.Baseline?.MountPoint, RemoteMountStage.Rejected,
                new(1, status, "remoteMount", false, false, new(0, status == MutationResultStatus.CancelledBeforeSubmission ? 0 : 1, 0), category));
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !Enum.IsDefined(request.Action) || !request.RiskConfirmed)
            return Reject(MutationErrorCategory.Validation);
        if (!CanManageRemoteMountWorkflow) return Reject(MutationErrorCategory.Unsupported, MutationResultStatus.Unsupported);
        if (request.Action != RemoteMountAction.Create && (request.Baseline is null || request.Baseline.ProfileId != _profile.Id ||
            !RemoteMountProtocol.IsMountPoint(request.Baseline.MountPoint))) return Reject(MutationErrorCategory.Validation);
        if (request.Action == RemoteMountAction.Create && request.Baseline is not null || request.Action == RemoteMountAction.Disconnect && request.Desired is not null)
            return Reject(MutationErrorCategory.Validation);
        IReadOnlyDictionary<string, string>? connectParameters = null;
        if (request.Action != RemoteMountAction.Disconnect)
        {
            if (request.Desired is null || !RemoteMountProtocol.TryBuildConnect(request.Desired, out connectParameters, out _)) return Reject(MutationErrorCategory.Validation);
            if (request.Desired.Server.Trim('[', ']').Equals(_api.GetBaseUri(_profile).Host.Trim('[', ']'), StringComparison.OrdinalIgnoreCase)) return Reject(MutationErrorCategory.Validation);
            if (request.Action == RemoteMountAction.Update && request.Baseline!.MountPoint != request.Desired.MountPoint &&
                RemoteMountPathsOverlap(request.Baseline.MountPoint, request.Desired.MountPoint)) return Reject(MutationErrorCategory.Conflict);
        }
        var setup = request.Desired is null ? null : RemoteMountSetup.FromDraft(request.Desired);
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Action, request.Baseline, Setup = setup }));
        var scope = ServiceScope(); var shared = ServiceMutations;
        // 即使本次调用已取消，也先读取同编号的既有进度，不能把之前已生效的步骤说成未提交。
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict);
        try
        {
            if (shared.RemoteMountOperations.TryGetValue(request.RequestId, out var existing))
            {
                if (existing.Scope != scope || existing.Signature != signature) return Reject(MutationErrorCategory.Conflict);
                if (existing.IsTerminal) return existing.Progress!;
                if (token.IsCancellationRequested) return RemoteMountProgressFor(existing, cancelled: true);
                if (!continueConfirmed || existing.Stage is not (RemoteMountStage.ReadyToConnect or RemoteMountStage.ReadyToDisconnectPrevious))
                    return await ReviewRemoteMountCoreAsync(existing, token).ConfigureAwait(false);
                return await ContinueRemoteMountCoreAsync(existing, connectParameters, token).ConfigureAwait(false);
            }
            if (token.IsCancellationRequested) return Reject(MutationErrorCategory.Unknown, MutationResultStatus.CancelledBeforeSubmission);
            if (continueConfirmed) return Reject(MutationErrorCategory.Validation);
            var paths = new[] { request.Baseline?.MountPoint, request.Desired?.MountPoint }.OfType<string>().ToArray();
            if (shared.RemoteMountOperations.Values.Any(state => state.Scope == scope && !state.IsTerminal &&
                state.Paths.Any(active => paths.Any(path => RemoteMountPathsOverlap(active, path))))) return Reject(MutationErrorCategory.Conflict);
            RemoteMountConnection? desired = null;
            if (request.Desired is { } draft)
            {
                RemoteMountProtocol.TryNormalizeSource(connectParameters!["server_ip"], draft.Protocol, out var source);
                desired = new(_profile.Id, draft.MountPoint, source, draft.Protocol, false);
            }
            try
            {
                var inventory = await LoadRemoteMountInventoryAsync(token).ConfigureAwait(false);
                if (request.Action != RemoteMountAction.Disconnect && !inventory.RemoteMountingEnabled) return Reject(MutationErrorCategory.Permission);
                if (request.Baseline is { } baseline && !inventory.Items.Contains(baseline)) return Reject(MutationErrorCategory.Conflict);
                if (request.Baseline is { } nested && HasOtherRemoteMountOverlap(inventory, nested)) return Reject(MutationErrorCategory.Conflict);
                if (request.Baseline is { } old && !RemoteKindMatches(await ReadRemoteMountTargetKindAsync(old.MountPoint, token).ConfigureAwait(false), old.Protocol))
                    return Reject(MutationErrorCategory.Conflict);
                if (desired is not null && (request.Baseline is null || desired.MountPoint != request.Baseline.MountPoint))
                {
                    if (inventory.Items.Any(item => RemoteMountPathsOverlap(item.MountPoint, desired.MountPoint)) ||
                        !IsLocalRemoteTarget(await ReadRemoteMountTargetKindAsync(desired.MountPoint, token).ConfigureAwait(false))) return Reject(MutationErrorCategory.Conflict);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return Reject(MutationErrorCategory.Unknown, MutationResultStatus.CancelledBeforeSubmission); }
            catch (DsmException error) { return Reject(FavoriteErrorCategory(error)); }
            catch (Exception) { return Reject(MutationErrorCategory.Server); }

            var firstIsConnect = request.Action == RemoteMountAction.Create || request.Action == RemoteMountAction.Update && request.Baseline!.MountPoint != desired!.MountPoint;
            // 只保存目标身份和配置摘要，不在恢复记录持有密码或可再次发送的凭据字典。
            var state = new RemoteMountOperation(scope, signature, request.RequestId, request.Action, request.Baseline, desired, paths, setup);
            shared.RemoteMountOperations.Add(request.RequestId, state);
            return await SubmitRemoteMountStepAsync(state, firstIsConnect, connectParameters, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<RemoteMountProgress>> GetRemoteMountOperationsAsync(CancellationToken cancellationToken = default)
    {
        if (!CanManageRemoteMountWorkflow) return [];
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.RemoteMountOperations.Values.Where(state => state.Scope == scope && !state.IsTerminal)
            .Select(state => state.Progress!).ToArray(); }
        finally { shared.Gate.Release(); }
    }

    public async Task<RemoteMountProgress?> ReviewRemoteMountOperationAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        if (!CanManageRemoteMountWorkflow) return null;
        var shared = ServiceMutations; if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return null;
        try { return shared.RemoteMountOperations.TryGetValue(requestId, out var state) && state.Scope == ServiceScope()
            ? state.IsTerminal ? state.Progress : await ReviewRemoteMountCoreAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }

    private async Task<RemoteMountProgress> ContinueRemoteMountCoreAsync(RemoteMountOperation state, IReadOnlyDictionary<string, string>? parameters, CancellationToken token)
    {
        var connecting = state.Stage == RemoteMountStage.ReadyToConnect;
        try
        {
            var inventory = await LoadRemoteMountInventoryAsync(token).ConfigureAwait(false);
            if (connecting)
            {
                if (!inventory.RemoteMountingEnabled || inventory.Items.Any(item => RemoteMountPathsOverlap(item.MountPoint, state.Desired!.MountPoint)) ||
                    !IsLocalRemoteTarget(await ReadRemoteMountTargetKindAsync(state.Desired!.MountPoint, token).ConfigureAwait(false)))
                    return RemoteMountProgressFor(state, error: MutationErrorCategory.Conflict);
            }
            else
            {
                if (!await RemoteConnectionVerifiedAsync(state.Desired!, inventory, token).ConfigureAwait(false)) return RemoteMountProgressFor(state, error: MutationErrorCategory.Conflict);
                var previous = inventory.Items.SingleOrDefault(item => item.MountPoint == state.Baseline!.MountPoint);
                if (previous is null)
                {
                    if (IsUnmountedRemoteTarget(await ReadRemoteMountTargetKindAsync(state.Baseline!.MountPoint, token).ConfigureAwait(false)))
                    { state.CompletedSteps++; state.Stage = RemoteMountStage.Complete; return RemoteMountProgressFor(state); }
                    return RemoteMountProgressFor(state, error: MutationErrorCategory.Conflict);
                }
                if (previous != state.Baseline || HasOtherRemoteMountOverlap(inventory, previous) ||
                    !RemoteKindMatches(await ReadRemoteMountTargetKindAsync(previous.MountPoint, token).ConfigureAwait(false), previous.Protocol))
                    return RemoteMountProgressFor(state, error: MutationErrorCategory.Conflict);
            }
            token.ThrowIfCancellationRequested();
        }
        catch (OperationCanceledException) { return RemoteMountProgressFor(state, cancelled: true); }
        catch (DsmException error) { return RemoteMountProgressFor(state, error: FavoriteErrorCategory(error)); }
        catch (Exception) { return RemoteMountProgressFor(state, error: MutationErrorCategory.Network); }
        return await SubmitRemoteMountStepAsync(state, connecting, parameters, token).ConfigureAwait(false);
    }

    private async Task<RemoteMountProgress> SubmitRemoteMountStepAsync(RemoteMountOperation state, bool connect, IReadOnlyDictionary<string, string>? parameters, CancellationToken token)
    {
        if (token.IsCancellationRequested) return RemoteMountStepNotSubmitted(state);
        var previousStage = state.Stage;
        var previouslySubmitted = state.Submitted;
        state.Stage = connect ? RemoteMountStage.VerifyingConnection : RemoteMountStage.VerifyingDisconnection;
        state.Submitted = true; RemoteMountProgressFor(state);
        var api = connect ? "SYNO.FileStation.Mount" : "SYNO.FileStation.Mount.List";
        try
        {
            var result = await ((IFileLocationMutationTransport)_api).SendFileLocationMutationAsync(_profile, _session, _capabilities[api],
                new(connect ? FileLocationMutationKind.CreateRemoteMount : FileLocationMutationKind.DeleteRemoteMount, connect ? "mount_remote" : "unmount",
                    connect ? parameters! : new Dictionary<string, string> { ["mount_point"] = JsonSerializer.Serialize(new[] { state.Baseline!.MountPoint }) }), token).ConfigureAwait(false);
            if (result.Status == FileLocationMutationTransportStatus.CancelledBeforeSubmission)
            {
                state.Stage = previousStage; state.Submitted = previouslySubmitted;
                return RemoteMountStepNotSubmitted(state);
            }
            if (result.Status is FileLocationMutationTransportStatus.ConfirmedFailure or FileLocationMutationTransportStatus.Unsupported)
            {
                if (result.Status == FileLocationMutationTransportStatus.Unsupported) state.Submitted = previouslySubmitted;
                state.Stage = RemoteMountStage.Rejected;
                return RemoteMountProgressFor(state, error: result.ErrorCategory ?? MutationErrorCategory.Unknown,
                    rejected: result.Status == FileLocationMutationTransportStatus.Unsupported ? MutationResultStatus.Unsupported :
                        result.ErrorCategory == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure);
            }
            // HTTP 层拒绝无法证明 NAS 未执行；保留未知状态，但认证/权限错误后不继续访问。
            if (result.ErrorCategory is MutationErrorCategory.Authentication or MutationErrorCategory.Permission)
                return RemoteMountProgressFor(state, error: result.ErrorCategory);
        }
        catch (Exception) { /* 提交可能已经生效，后续只读核查，不猜测回滚。 */ }
        return await ReviewRemoteMountCoreAsync(state, token).ConfigureAwait(false);
    }

    private static RemoteMountProgress RemoteMountStepNotSubmitted(RemoteMountOperation state)
    {
        // 第一步未发送可直接结束；修改已完成第一步时保留明确继续入口，不伪装全程取消。
        if (state.CompletedSteps > 0) return RemoteMountProgressFor(state, cancelled: true);
        state.Stage = RemoteMountStage.Rejected;
        return RemoteMountProgressFor(state, rejected: MutationResultStatus.CancelledBeforeSubmission);
    }

    private async Task<RemoteMountProgress> ReviewRemoteMountCoreAsync(RemoteMountOperation state, CancellationToken token)
    {
        if (state.IsTerminal || state.Stage is RemoteMountStage.ReadyToConnect or RemoteMountStage.ReadyToDisconnectPrevious) return state.Progress!;
        if (token.IsCancellationRequested) return RemoteMountProgressFor(state, cancelled: true);
        try
        {
            var inventory = await LoadRemoteMountInventoryAsync(token).ConfigureAwait(false);
            if (state.Stage == RemoteMountStage.VerifyingConnection)
            {
                if (!await RemoteConnectionVerifiedAsync(state.Desired!, inventory, token).ConfigureAwait(false)) return RemoteMountProgressFor(state);
                state.CompletedSteps++;
                state.Stage = state.Action == RemoteMountAction.Update && state.Baseline!.MountPoint != state.Desired!.MountPoint
                    ? RemoteMountStage.ReadyToDisconnectPrevious : RemoteMountStage.Complete;
            }
            else
            {
                if (inventory.Items.Any(item => item.MountPoint == state.Baseline!.MountPoint) ||
                    !IsUnmountedRemoteTarget(await ReadRemoteMountTargetKindAsync(state.Baseline!.MountPoint, token).ConfigureAwait(false))) return RemoteMountProgressFor(state);
                if (state.Action == RemoteMountAction.Update && state.Desired!.MountPoint != state.Baseline!.MountPoint &&
                    !await RemoteConnectionVerifiedAsync(state.Desired, inventory, token).ConfigureAwait(false)) return RemoteMountProgressFor(state);
                state.CompletedSteps++;
                state.Stage = state.Action == RemoteMountAction.Update && state.Desired!.MountPoint == state.Baseline!.MountPoint
                    ? RemoteMountStage.ReadyToConnect : RemoteMountStage.Complete;
            }
            return RemoteMountProgressFor(state);
        }
        catch (OperationCanceledException) { return RemoteMountProgressFor(state, cancelled: true); }
        catch (DsmException error) { return RemoteMountProgressFor(state, error: FavoriteErrorCategory(error)); }
        catch (Exception) { return RemoteMountProgressFor(state, error: MutationErrorCategory.Network); }
    }

    private async Task<bool> RemoteConnectionVerifiedAsync(RemoteMountConnection desired, RemoteMountInventory inventory, CancellationToken token) =>
        inventory.Items.Contains(desired) && RemoteKindMatches(await ReadRemoteMountTargetKindAsync(desired.MountPoint, token).ConfigureAwait(false), desired.Protocol);

    private async Task<string> ReadRemoteMountTargetKindAsync(string path, CancellationToken token)
    {
        var capability = _capabilities["SYNO.FileStation.List"] with { MinVersion = 2, MaxVersion = 2 };
        var data = await _api.CallAsync(_profile, _session, capability, "getinfo", new Dictionary<string, string>
            { ["path"] = JsonSerializer.Serialize(new[] { path }), ["additional"] = "[\"mount_point_type\"]" }, token).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } items || items[0] is not JsonObject row || LocationRequiredString(row, "path") != path)
            throw new InvalidDataException("remote-mount.target.invalid");
        if (row.ContainsKey("code"))
        {
            var code = LocationRequiredNonNegativeInt(row, "code");
            if (code == 408) return "absent";
            if (code != 0) throw new DsmException(UserText.Key("FileLocationsRemoteOperationFailed"), UserText.Key("FileLocationsRemoteOperationFailed"), code,
                authenticationFailure: code is 106 or 107 or 119);
        }
        if (!RequiredNativeBool(row, "isdir") || row["additional"] is not JsonObject additional) throw new InvalidDataException("remote-mount.target.invalid");
        return LocationRequiredString(additional, "mount_point_type").ToLowerInvariant();
    }

    private bool RemoteWorkflowCapability(string name, int version) => _capabilities.TryGetValue(name, out var capability) && capability.Name == name &&
        capability.MinVersion <= version && capability.MaxVersion >= version && NasServiceFormatAndPathSupported(capability);
    private static bool IsLocalRemoteTarget(string kind) => kind is "normal" or "shared_folder";
    private static bool IsUnmountedRemoteTarget(string kind) => kind == "absent" || IsLocalRemoteTarget(kind);
    private static bool RemoteKindMatches(string kind, FileRemoteProtocol protocol) => kind == "remote" || protocol == FileRemoteProtocol.Cifs && kind == "cifs" || protocol == FileRemoteProtocol.Nfs && kind == "nfs";
    private static bool RemoteMountPathsOverlap(string left, string right) => left == right || left.StartsWith(right + "/", StringComparison.Ordinal) || right.StartsWith(left + "/", StringComparison.Ordinal);
    private static bool HasOtherRemoteMountOverlap(RemoteMountInventory inventory, RemoteMountConnection target) =>
        inventory.Items.Any(item => item.MountPoint != target.MountPoint && RemoteMountPathsOverlap(item.MountPoint, target.MountPoint));

    private static RemoteMountProgress RemoteMountProgressFor(RemoteMountOperation state, MutationErrorCategory? error = null, bool cancelled = false, MutationResultStatus? rejected = null)
    {
        var complete = state.Stage == RemoteMountStage.Complete; var failed = state.Stage == RemoteMountStage.Rejected;
        var status = complete ? MutationResultStatus.ConfirmedSuccess : failed ? state.CompletedSteps > 0 ? MutationResultStatus.PartialSuccess : rejected ?? MutationResultStatus.ConfirmedFailure :
            cancelled ? MutationResultStatus.CancellationRequestedAfterSubmission : state.CompletedSteps > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified;
        var neverSubmitted = status == MutationResultStatus.CancelledBeforeSubmission;
        state.Progress = new(state.Id, state.Action, state.Desired?.MountPoint ?? state.Baseline!.MountPoint, state.Baseline?.MountPoint, state.Stage,
            new(1, status, "remoteMount", state.Submitted, !neverSubmitted,
                new(state.CompletedSteps, failed && !neverSubmitted ? 1 : 0, complete || failed ? 0 : 1), error), new(state.Baseline, state.Setup));
        return state.Progress;
    }
    private sealed class RemoteMountOperation(string scope, string signature, Guid id, RemoteMountAction action, RemoteMountConnection? baseline,
        RemoteMountConnection? desired, string[] paths, RemoteMountSetup? setup)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public Guid Id { get; } = id;
        public RemoteMountAction Action { get; } = action;
        public RemoteMountConnection? Baseline { get; } = baseline;
        public RemoteMountConnection? Desired { get; } = desired;
        public RemoteMountSetup? Setup { get; } = setup;
        public string[] Paths { get; } = paths;
        public RemoteMountStage Stage { get; set; }
        public int CompletedSteps { get; set; }
        public bool Submitted { get; set; }
        public RemoteMountProgress? Progress { get; set; }
        public bool IsTerminal => Stage is RemoteMountStage.Complete or RemoteMountStage.Rejected;
    }
}
