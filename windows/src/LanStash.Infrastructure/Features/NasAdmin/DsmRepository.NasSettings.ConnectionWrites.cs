using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> DisconnectConnectionAsync(NasConnectionDisconnectRequest request, CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanConnectionDisconnect ? ExecuteConnectionDisconnectAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("disconnectConnection"));

    internal async Task<MutationResult> ExecuteConnectionDisconnectAsync(NasConnectionDisconnectRequest request, CancellationToken token = default,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        const string operation = "disconnectConnection";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id ||
            !request.RiskConfirmed || request.RequestId == Guid.Empty || string.IsNullOrWhiteSpace(_session.Sid) || !request.Baseline.CanDisconnect ||
            request.Baseline.RequiresCurrentSessionConfirmation && !request.CurrentSessionConfirmed)
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = ConnectionCapability(); if (capability is null) return UnsupportedResult(operation);
        var scope = ServiceScope(); var signature = ServiceHash(ConnectionSignature(request.Baseline)); var targetKey = ConnectionKey(request.Baseline);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (ConnectionIdentityKeys(request.Baseline).Any(key => shared.ConnectionPending.ContainsKey((scope, key)))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var snapshot = await LoadConnectionSnapshotAsync(token).ConfigureAwait(false);
                var current = snapshot.Items.Where(item => item.IsWeb == request.Baseline.IsWeb && item.TargetIdentity == request.Baseline.TargetIdentity).ToArray();
                if (!snapshot.IsComplete || current.Length != 1 || !current[0].CanDisconnect || ConnectionSignature(current[0]) != ConnectionSignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasConnectionOperation(scope, signature, targetKey, request.Baseline);
            shared.Operations.Add(request.RequestId, state); shared.ConnectionPending.Add((scope, targetKey), state);
            var target = new Dictionary<string, object> { ["who"] = request.Baseline.Account!, ["from"] = request.Baseline.Source! };
            if (request.Baseline.IsWeb) { target["did"] = request.Baseline.DeviceId!; target["descr"] = request.Baseline.Description!; }
            else { target["pid"] = request.Baseline.ProcessId!; target["type"] = request.Baseline.Type!; }
            var accepted = false;
            try
            {
                await SecurityCallAsync(capability, "kick_connection", new()
                {
                    ["http_conn"] = request.Baseline.IsWeb ? new[] { target } : Array.Empty<Dictionary<string, object>>(),
                    ["service_conn"] = request.Baseline.IsWeb ? Array.Empty<Dictionary<string, object>>() : new[] { target },
                }, token).ConfigureAwait(false);
                accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 断线或取消可能已经提交，只读核对，不能重放。 */ }
            finally { target.Clear(); }
            return await ReviewConnectionOperationAsync(state, accepted ? 4 : 1, token, delay ?? Task.Delay).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<NasConnectionRecoveryInfo>> GetConnectionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return Array.AsReadOnly(shared.ConnectionPending.Where(item => item.Key.Scope == scope)
            .Select(item => new NasConnectionRecoveryInfo(item.Key.TargetKey, item.Value.Target?.Account, item.Value.Target?.Source, item.Value.Target?.Protocol ?? item.Value.Target?.Type)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewConnectionAsync(string targetKey, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(targetKey) || _profile.Id != _session.ProfileId) return ServicePreflightFailure("disconnectConnection", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("disconnectConnection", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("disconnectConnection"); }
        try { return shared.ConnectionPending.TryGetValue((ServiceScope(), targetKey), out var state)
            ? await ReviewConnectionOperationAsync(state, 1, cancellationToken, Task.Delay).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewConnectionOperationAsync(NasConnectionOperation state, int attempts, CancellationToken token,
        Func<TimeSpan, CancellationToken, Task> delay)
    {
        const string operation = "disconnectConnection";
        MutationResult Finish(MutationResult result)
        { state.Final = result; state.Target = null; ServiceMutations.ConnectionPending.Remove((state.Scope, state.TargetKey)); return result; }
        if (state.Rejection is { } category) return Finish(new(1, category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            operation, true, false, new(0, 1, 0), category));
        for (var index = 0; index < attempts && !token.IsCancellationRequested; index++)
        {
            try
            {
                if (index > 0) await delay(TimeSpan.FromMilliseconds(500), token).ConfigureAwait(false);
                var snapshot = await LoadConnectionSnapshotAsync(token).ConfigureAwait(false);
                if (snapshot.IsComplete && !snapshot.Items.Any(item => ConnectionMayRemain(item, state.Target!)))
                    return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
            }
            catch (Exception) { /* 不把畸形或失败列表当成目标消失。 */ }
        }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), MutationErrorCategory.Network, diagnosticTag: "connection.disconnect.unverified");
    }
    private static bool ConnectionMayRemain(NasConnectionEntry current, NasConnectionEntry target)
    {
        var raw = target.IsWeb ? current.DeviceId : current.ProcessId;
        if (raw == target.TargetIdentity) return true; // 不受派生行 ID、时间或连接分类变化影响。
        if (!string.IsNullOrWhiteSpace(raw)) return false;
        static bool Compatible(string? left, string? right) => left is null || right is null || left == right;
        return Compatible(current.Account, target.Account) && Compatible(current.Source, target.Source) &&
            Compatible(current.Description, target.Description) && Compatible(current.ReportedTime, target.ReportedTime);
    }
    private sealed class NasConnectionOperation(string scope, string signature, string targetKey, NasConnectionEntry target)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Connections)
    {
        public string TargetKey { get; } = targetKey;
        public NasConnectionEntry? Target { get; set; } = target;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
