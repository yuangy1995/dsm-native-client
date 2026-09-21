using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> DeleteDirectoryEntryAsync(NasDirectoryDeleteRequest request, CancellationToken cancellationToken = default) =>
        request?.Baseline is { } entry && (entry.Kind == NasDirectoryKind.User ? NasSettingsWriteAvailability.CanAccountDelete : NasSettingsWriteAvailability.CanGroupDelete)
            ? ExecuteDirectoryDeletionAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("deleteDirectoryEntry"));

    internal async Task<MutationResult> ExecuteDirectoryDeletionAsync(NasDirectoryDeleteRequest request, CancellationToken token = default)
    {
        const string operation = "deleteDirectoryEntry";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || !Enum.IsDefined(request.Baseline.Kind) || !StableDirectoryName(request.Baseline.Name) ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || !request.RiskConfirmed || request.RequestId == Guid.Empty || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (!request.Baseline.CanDelete || NasDirectoryEntry.IsReserved(request.Baseline.Kind, request.Baseline.Name) ||
            request.Baseline.Kind == NasDirectoryKind.User && (string.IsNullOrWhiteSpace(_profile.Username) ||
                string.Equals(request.Baseline.Name.Trim(), _profile.Username.Trim(), StringComparison.OrdinalIgnoreCase)))
            return new(1, MutationResultStatus.PermissionDenied, operation, false, false, new(0, 1, 0), MutationErrorCategory.Permission);
        var capability = DirectoryCapability(request.Baseline.Kind);
        if (capability is null) return UnsupportedResult(operation);
        request = request with { Baseline = request.Baseline with
        { Groups = request.Baseline.Groups is null ? null : Array.AsReadOnly(request.Baseline.Groups.ToArray()) } };
        var scope = ServiceScope(); var signature = ServiceHash(DirectoryEntrySignature(request.Baseline));
        var shared = ServiceMutations; var key = (scope, request.Baseline.Kind, request.Baseline.Name.ToLowerInvariant());
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
            if (shared.DirectoryPending.ContainsKey(key)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = (await LoadDirectoryAsync(request.Baseline.Kind, token).ConfigureAwait(false))
                    .FirstOrDefault(item => string.Equals(item.Name, request.Baseline.Name, StringComparison.OrdinalIgnoreCase));
                if (current is null || !current.CanDelete || DirectoryEntrySignature(current) != DirectoryEntrySignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasDirectoryDeletionOperation(scope, signature, request.Baseline.Kind, request.Baseline.Name);
            shared.Operations.Add(request.RequestId, state); shared.DirectoryPending.Add(key, state);
            try
            {
                await SecurityCallAsync(capability, "delete", new() { ["name"] = new[] { state.Name } }, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 可能已经提交；下面只回读，不能重新删除。 */ }
            return await ReviewDirectoryDeletionAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<NasDirectoryRecoveryInfo>> GetDirectoryRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return Array.AsReadOnly(shared.DirectoryPending.Where(pair => pair.Key.Scope == scope)
            .Select(pair => new NasDirectoryRecoveryInfo(pair.Value.DirectoryKind, pair.Value.Name, pair.Value.Operation)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewDirectoryEntryAsync(NasDirectoryKind kind, string name, CancellationToken cancellationToken = default)
    {
        if (!Enum.IsDefined(kind) || !StableDirectoryName(name) || _profile.Id != _session.ProfileId)
            return ServicePreflightFailure("deleteDirectoryEntry", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try
        {
            if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("deleteDirectoryEntry", MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("deleteDirectoryEntry"); }
        try { return shared.DirectoryPending.TryGetValue((ServiceScope(), kind, name.ToLowerInvariant()), out var state)
            ? await ReviewNasSettingsOperationAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewDirectoryDeletionAsync(NasDirectoryDeletionOperation state, CancellationToken token)
    {
        const string operation = "deleteDirectoryEntry";
        MutationResult Finish(MutationResult result)
        { state.Final = result; ServiceMutations.DirectoryPending.Remove((state.Scope, state.DirectoryKind, state.Name.ToLowerInvariant())); return result; }
        MutationResult Unknown() => new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), MutationErrorCategory.Network);
        if (state.Rejection is { } rejection) return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            operation, true, false, new(0, 1, 0), rejection));
        if (token.IsCancellationRequested) return Unknown();
        try
        {
            var directory = await LoadDirectoryAsync(state.DirectoryKind, token).ConfigureAwait(false);
            if (!directory.Any(item => string.Equals(item.Name, state.Name, StringComparison.OrdinalIgnoreCase)))
                return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
        }
        catch (Exception) { /* 畸形或失败的目录不能证明目标消失。 */ }
        return Unknown();
    }
    private static string DirectoryEntrySignature(NasDirectoryEntry value) => JsonSerializer.Serialize(new
    { value.Kind, value.Name, value.NumericId, value.Description, value.Email, value.IsExpired, value.EditAllowed, value.DeleteAllowed,
        value.IsCurrentAccount, Groups = value.Groups?.Order(StringComparer.Ordinal) });
    private abstract class NasDirectoryOperation(string scope, string signature, NasDirectoryKind directoryKind, string name, NasDirectoryOperationKind operation)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Directory)
    {
        public NasDirectoryKind DirectoryKind { get; } = directoryKind;
        public string Name { get; } = name;
        public NasDirectoryOperationKind Operation { get; } = operation;
    }
    private sealed class NasDirectoryDeletionOperation(string scope, string signature, NasDirectoryKind directoryKind, string name)
        : NasDirectoryOperation(scope, signature, directoryKind, name, NasDirectoryOperationKind.Delete)
    {
        public MutationErrorCategory? Rejection { get; set; }
    }
}
