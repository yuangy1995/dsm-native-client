using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public NasPackageControlAvailability PackageControlAvailability => new(
        NasSettingsWriteAvailability.CanPackageControl && SecurityCapability("SYNO.Core.Package.Control", 1) is not null,
        NasSettingsWriteAvailability.CanPackageControl && SecurityCapability("SYNO.Core.Package.Uninstallation", 1) is not null);

    public async Task<IReadOnlyList<NasPackageRecoveryInfo>> GetPackageRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations;
        await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var scope = ServiceScope();
            return Array.AsReadOnly(shared.PackagePending.Where(pair => pair.Key.Scope == scope)
                .Select(pair => new NasPackageRecoveryInfo(pair.Value.PackageId, pair.Value.DisplayName, pair.Value.Action)).ToArray());
        }
        finally { shared.Gate.Release(); }
    }
    public Task<MutationResult> ControlPackageAsync(NasPackageMutationRequest request, CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanPackageControl ? ExecutePackageMutationAsync(request, cancellationToken) :
            Task.FromResult(UnsupportedResult("controlPackage"));

    internal async Task<MutationResult> ExecutePackageMutationAsync(NasPackageMutationRequest request, CancellationToken token = default,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        var operation = PackageOperationName(request?.Action ?? NasPackageAction.Start);
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || !StablePackageId(request.Baseline.Id) || !Enum.IsDefined(request.Action) ||
            !request.RiskConfirmed || request.RequestId == Guid.Empty || request.ProfileId != _profile.Id ||
            _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) || !PackageActionAllowed(request.Baseline, request.Action))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var list = SecurityCapability("SYNO.Core.Package", 2);
        var control = SecurityCapability(request.Action == NasPackageAction.Uninstall ? "SYNO.Core.Package.Uninstallation" : "SYNO.Core.Package.Control", 1);
        if (list is null || control is null) return UnsupportedResult(operation);
        request = request with { Baseline = request.Baseline with
        {
            AvailableOperations = request.Baseline.AvailableOperations is null ? null : Array.AsReadOnly(request.Baseline.AvailableOperations.ToArray()),
            DesktopApps = request.Baseline.DesktopApps is null ? null : Array.AsReadOnly(request.Baseline.DesktopApps.ToArray()),
        } };
        var scope = ServiceScope(); var shared = ServiceMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Action, Baseline = PackageSnapshotSignature(request.Baseline) }));
        try
        {
            if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
            {
                if (previous.Scope != scope || previous.Signature != signature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false);
            }
            if (shared.PackagePending.ContainsKey((scope, request.Baseline.Id))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = (await LoadPackagesAsync(token).ConfigureAwait(false)).FirstOrDefault(item => item.Id == request.Baseline.Id);
                if (current is null || !PackageActionAllowed(current, request.Action) || PackageSnapshotSignature(current) != PackageSnapshotSignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                await SecurityCallAsync(list, "feasibility_check", new()
                {
                    ["type"] = request.Action switch { NasPackageAction.Start => "start_check", NasPackageAction.Stop => "stop_check", _ => "uninstall_check" },
                    ["packages"] = new[] { current.Id },
                }, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasPackageOperation(scope, signature, request.Baseline.Id, request.Baseline.Name, request.Action);
            shared.Operations.Add(request.RequestId, state); shared.PackagePending.Add((scope, state.PackageId), state);
            var parameters = new Dictionary<string, object> { ["id"] = state.PackageId };
            if (request.Action != NasPackageAction.Stop) parameters["dsm_apps"] = request.Baseline.DesktopApps!;
            try
            {
                await SecurityCallAsync(control, request.Action.ToString().ToLowerInvariant(), parameters, token).ConfigureAwait(false);
                state.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            {
                state.Rejection = ServiceErrorCategory(error);
            }
            catch (Exception) { /* 可能已提交，只允许回读，禁止再次发起启动/停止/卸载。 */ }
            return await ReconcilePackageAsync(state, state.Accepted ? 10 : 3, token, true, delay ?? Task.Delay).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewPackageAsync(string packageId, CancellationToken cancellationToken = default)
    {
        if (!StablePackageId(packageId) || _profile.Id != _session.ProfileId) return ServicePreflightFailure("controlPackage", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try
        {
            if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("controlPackage", MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("controlPackage"); }
        try
        {
            return shared.PackagePending.TryGetValue((ServiceScope(), packageId), out var state)
                ? await ReconcilePackageAsync(state, 1, cancellationToken, false, Task.Delay).ConfigureAwait(false) : null;
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReconcilePackageAsync(NasPackageOperation state, int attempts, CancellationToken token,
        bool recoverCancellation, Func<TimeSpan, CancellationToken, Task> delay)
    {
        var operation = PackageOperationName(state.Action);
        MutationResult Finish(MutationResult value)
        { state.Final = value; ServiceMutations.PackagePending.Remove((state.Scope, state.PackageId)); return value; }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                operation, true, false, new(0, 1, 0), rejection));
        async Task<bool> Matches(CancellationToken readToken)
        {
            var items = await LoadPackagesAsync(readToken).ConfigureAwait(false);
            var current = items.FirstOrDefault(item => item.Id == state.PackageId);
            return state.Action == NasPackageAction.Uninstall ? current is null : current is not null &&
                (state.Action == NasPackageAction.Start ? current.IsRunning : current.IsStopped);
        }
        bool verified = false;
        for (var index = 0; index < attempts && !token.IsCancellationRequested; index++)
        {
            try
            {
                if (index > 0) await delay(TimeSpan.FromSeconds(1), token).ConfigureAwait(false);
                verified = await Matches(token).ConfigureAwait(false);
                if (verified) break;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            catch (Exception) { /* 有界只读恢复不记录原始响应。 */ }
        }
        if (!verified && token.IsCancellationRequested && recoverCancellation)
        {
            // 已提交取消后按契约只做一次独立、有超时的回读，绝不重放写请求。
            using var recovery = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            try { verified = await Matches(recovery.Token).ConfigureAwait(false); }
            catch (Exception) { }
        }
        if (verified) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), MutationErrorCategory.Network, diagnosticTag: "package.result-unverified");
    }
    private static bool PackageActionAllowed(NasPackageSummary value, NasPackageAction action) => action switch
    { NasPackageAction.Start => value.CanStart, NasPackageAction.Stop => value.CanStop, NasPackageAction.Uninstall => value.CanUninstall, _ => false };
    private static string PackageOperationName(NasPackageAction action) => action switch
    { NasPackageAction.Start => "startPackage", NasPackageAction.Stop => "stopPackage", NasPackageAction.Uninstall => "uninstallPackage", _ => "controlPackage" };
    private static string PackageSnapshotSignature(NasPackageSummary value) => JsonSerializer.Serialize(new
    {
        value.Id, value.Name, value.Version, value.Status, value.State, value.Startable, value.InstallType, value.UninstallAllowed,
        Operations = value.AvailableOperations?.Order(StringComparer.Ordinal), Apps = value.DesktopApps?.Order(StringComparer.Ordinal),
    });
    private sealed class NasPackageOperation(string scope, string signature, string packageId, string displayName, NasPackageAction action)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Packages)
    {
        public string PackageId { get; } = packageId;
        public string DisplayName { get; } = displayName;
        public NasPackageAction Action { get; } = action;
        public bool Accepted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
}
