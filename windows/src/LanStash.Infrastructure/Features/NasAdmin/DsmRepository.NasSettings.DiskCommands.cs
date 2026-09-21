using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> ExecuteDiskTestAsync(NasDiskTestRequest request, CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanDiskTest ? ExecuteDiskTestCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("diskTest"));

    internal async Task<MutationResult> ExecuteDiskTestCoreAsync(NasDiskTestRequest request, CancellationToken token = default,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        const string operation = "diskTest";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline?.Target is not { } target || !ValidDiskIdentifier(target.Id) || !ValidDiskIdentifier(target.DeviceId) ||
            target.SupportsSmartTest != true || request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || !Enum.IsDefined(request.Command) || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (request.Command == NasDiskTestCommand.Stop ? !request.Baseline.IsRunning || request.Baseline.RunningType is null :
            request.Baseline.IsRunning || request.Baseline.RunningType is not null || request.Baseline.IsBusyWithOtherTest != false)
            return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        var capability = SecurityCapability("SYNO.Core.Storage.Disk", 1);
        if (capability is null || SecurityCapability("SYNO.Storage.CGI.Storage", 1) is null) return UnsupportedResult(operation);
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Command, Baseline = DiskStateSignature(request.Baseline) }));
        var shared = ServiceMutations; var scope = ServiceScope();
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.DiskTestPending.Values.Any(item => item.Scope == scope && (item.Target.Id == target.Id || item.Target.DeviceId == target.DeviceId)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = await LoadDiskTestStateAsync(target, token).ConfigureAwait(false);
                if (DiskStateSignature(current) != DiskStateSignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, DiskTestErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasDiskTestOperation(scope, signature, target, request.Command);
            shared.Operations.Add(request.RequestId, state); shared.DiskTestPending.Add((scope, target.Id), state);
            try
            {
                await SecurityCallAsync(capability, "do_smart_test", new Dictionary<string, object>
                { ["device"] = target.DeviceId, ["type"] = request.Command switch { NasDiskTestCommand.Quick => "quick", NasDiskTestCommand.Extended => "extend", _ => "stop" } }, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = DiskTestErrorCategory(error); }
            catch (Exception) { /* 提交可能已生效，只能回读，不重发。 */ }
            return await ReviewDiskTestOperationAsync(state, 6, token, true, delay ?? Task.Delay).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<NasDiskTestRecovery>> GetDiskTestRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return Array.AsReadOnly(shared.DiskTestPending.Values.Where(item => item.Scope == ServiceScope()).Select(item => new NasDiskTestRecovery(item.Target, item.Command)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewDiskTestAsync(string diskId, CancellationToken cancellationToken = default)
    {
        if (!ValidDiskIdentifier(diskId) || _profile.Id != _session.ProfileId) return ServicePreflightFailure("diskTest", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("diskTest", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("diskTest"); }
        try { return shared.DiskTestPending.TryGetValue((ServiceScope(), diskId), out var state) ?
            await ReviewDiskTestOperationAsync(state, 1, cancellationToken, false, Task.Delay).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewDiskTestOperationAsync(NasDiskTestOperation state, int attempts, CancellationToken token,
        bool recoverCancellation, Func<TimeSpan, CancellationToken, Task> delay)
    {
        MutationResult Finish(MutationResult value) { state.Final = value; ServiceMutations.DiskTestPending.Remove((state.Scope, state.Target.Id)); return value; }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "diskTest", true, false, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        async Task<bool> Matches(CancellationToken readToken)
        {
            var current = await LoadDiskTestStateAsync(state.Target, readToken).ConfigureAwait(false);
            return state.Command == NasDiskTestCommand.Stop ? !current.IsRunning : current.IsRunning &&
                current.RunningType == (state.Command == NasDiskTestCommand.Quick ? NasDiskTestType.Quick : NasDiskTestType.Extended);
        }
        bool verified = false;
        for (var attempt = 0; attempt < attempts && !token.IsCancellationRequested; attempt++)
        {
            try
            {
                if (attempt > 0) await delay(TimeSpan.FromSeconds(1), token).ConfigureAwait(false);
                if (await Matches(token).ConfigureAwait(false)) { verified = true; break; }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            catch (HttpRequestException) { category = MutationErrorCategory.Network; }
            catch (IOException) { category = MutationErrorCategory.Network; }
            catch (OperationCanceledException) { category = MutationErrorCategory.Network; }
            catch (DsmException error) when (error.Kind is DsmErrorKind.NetworkUnavailable or DsmErrorKind.RequestTimeout) { category = MutationErrorCategory.Network; }
            catch (DsmException error) { category = DiskTestErrorCategory(error); break; }
            catch (Exception) { category = MutationErrorCategory.Unknown; break; }
        }
        if (!verified && token.IsCancellationRequested && recoverCancellation)
        {
            using var recovery = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            try { verified = await Matches(recovery.Token).ConfigureAwait(false); }
            catch (DsmException error) { category = DiskTestErrorCategory(error); }
            catch (Exception) { category = MutationErrorCategory.Network; }
        }
        if (verified) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "diskTest", true, false, new(1, 0, 0),
            diagnosticTag: state.Command == NasDiskTestCommand.Stop ? "disk.test.stopped" : "disk.test.running"));
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            "diskTest", true, true, new(0, 0, 1), category, diagnosticTag: "disk.test.unverified");
    }
    private static MutationErrorCategory DiskTestErrorCategory(DsmException error) => error.AuthenticationFailure ? MutationErrorCategory.Authentication :
        error.Kind is DsmErrorKind.NetworkUnavailable or DsmErrorKind.RequestTimeout ? MutationErrorCategory.Network :
        error.Code == 105 ? MutationErrorCategory.Permission : error.Code is 102 or 103 or 104 ? MutationErrorCategory.Unsupported :
        error.Code is null ? MutationErrorCategory.Validation : MutationErrorCategory.Server;
    private static string DiskStateSignature(NasDiskTestState state) => JsonSerializer.Serialize(new
    { state.Target.Id, state.Target.DeviceId, state.Target.SupportsSmartTest, state.IsRunning, state.RunningType, state.IsBusyWithOtherTest });
    private sealed class NasDiskTestOperation(string scope, string signature, NasDiskTestTarget target, NasDiskTestCommand command)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.DiskTests)
    {
        public NasDiskTestTarget Target { get; } = target;
        public NasDiskTestCommand Command { get; } = command;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
