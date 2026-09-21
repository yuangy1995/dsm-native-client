using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public NasDirectorySaveAvailability DirectorySaveAvailability => new(
        _nasServiceSessionVerified && _nasServiceAdministrator && DirectoryCapability(NasDirectoryKind.User) is not null,
        _nasServiceSessionVerified && _nasServiceAdministrator && DirectoryCapability(NasDirectoryKind.Group) is not null);
    public Task<MutationResult> SaveDirectoryEntryAsync(NasDirectorySaveRequest request, string? password = null, string? passwordConfirmation = null,
        CancellationToken cancellationToken = default) => request is not null &&
        (request.Kind == NasDirectoryKind.User ? DirectorySaveAvailability.CanSaveUsers : DirectorySaveAvailability.CanSaveGroups)
            ? ExecuteDirectorySaveAsync(request, password, passwordConfirmation, cancellationToken) : Task.FromResult(UnsupportedResult("saveDirectoryEntry"));

    internal async Task<MutationResult> ExecuteDirectorySaveAsync(NasDirectorySaveRequest request, string? password = null, string? confirmation = null,
        CancellationToken token = default)
    {
        const string operation = "saveDirectoryEntry";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || request.RequestId == Guid.Empty ||
            !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid) || string.IsNullOrWhiteSpace(_profile.Username) || !NasDirectorySaveRules.IsValid(request, password, confirmation))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (request.Baseline is { CanEdit: false } || request.Baseline is not null && request.Kind == NasDirectoryKind.User &&
            string.Equals(request.Desired.Name.Trim(), _profile.Username.Trim(), StringComparison.OrdinalIgnoreCase) &&
            (request.Desired.IsExpired == true || request.Desired.Groups is not null && !NasDirectorySaveRules.SameGroups(request.Desired.Groups, request.Baseline.Groups!)))
            return new(1, MutationResultStatus.PermissionDenied, operation, false, false, new(0, 1, 0), MutationErrorCategory.Permission);
        if (request.Baseline is not null && string.IsNullOrEmpty(password) && NasDirectorySaveRules.Matches(request.Baseline, request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = DirectoryCapability(request.Kind);
        if (capability is null || request.Desired.Groups is not null && DirectoryCapability(NasDirectoryKind.Group) is null) return UnsupportedResult(operation);
        request = request with
        {
            Baseline = request.Baseline is null ? null : request.Baseline with { Groups = request.Baseline.Groups is null ? null : Array.AsReadOnly(request.Baseline.Groups.ToArray()) },
            Desired = request.Desired with { Groups = request.Desired.Groups is null ? null : Array.AsReadOnly(request.Desired.Groups.ToArray()) },
        };
        var scope = ServiceScope(); var shared = ServiceMutations; var key = (scope, request.Kind, request.Desired.Name.ToLowerInvariant());
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Kind, Baseline = request.Baseline is null ? null : DirectoryEntrySignature(request.Baseline), request.Desired }));
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
                if (!_nasServiceAdministrator) return new(1, MutationResultStatus.PermissionDenied, operation, false, false, new(0, 1, 0), MutationErrorCategory.Permission);
                var current = (await LoadDirectoryAsync(request.Kind, token).ConfigureAwait(false))
                    .FirstOrDefault(item => string.Equals(item.Name, request.Desired.Name, StringComparison.OrdinalIgnoreCase));
                if (request.Baseline is null ? current is not null : current is null || !current.CanEdit || DirectoryEntrySignature(current) != DirectoryEntrySignature(request.Baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (request.Desired.Groups is not null)
                {
                    var groups = await LoadDirectoryAsync(NasDirectoryKind.Group, token).ConfigureAwait(false);
                    if (request.Desired.Groups.Any(name => !groups.Any(item => item.Name == name))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasDirectorySaveOperation(scope, signature, request, !string.IsNullOrEmpty(password));
            shared.Operations.Add(request.RequestId, state); shared.DirectoryPending.Add(key, state);
            var parameters = new Dictionary<string, object> { ["name"] = request.Desired.Name, ["description"] = request.Desired.Description };
            if (request.Kind == NasDirectoryKind.User)
            {
                parameters["email"] = request.Desired.Email!; parameters["expired"] = request.Desired.IsExpired!.Value;
                if (request.Desired.Groups is not null) parameters["groups"] = request.Desired.Groups;
                if (!string.IsNullOrEmpty(password)) { parameters["password"] = password; parameters["password_confirm"] = confirmation!; }
            }
            password = null; confirmation = null;
            try
            {
                await SecurityCallAsync(capability, request.Baseline is null ? "create" : "set", parameters, token).ConfigureAwait(false); state.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 发送开始后不自动重放，包括密码变更。 */ }
            finally { parameters.Clear(); }
            return await ReviewDirectorySaveAsync(state, token).ConfigureAwait(false);
        }
        finally { password = null; confirmation = null; shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewDirectorySaveAsync(NasDirectorySaveOperation state, CancellationToken token)
    {
        const string operation = "saveDirectoryEntry";
        MutationResult Finish(MutationResult value)
        { state.Final = value; ServiceMutations.DirectoryPending.Remove((state.Scope, state.DirectoryKind, state.Name.ToLowerInvariant())); return value; }
        MutationResult Unknown() => new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), MutationErrorCategory.Network,
            diagnosticTag: state.HasPassword && !state.Accepted ? "directory.save.credentials-unverified" : "directory.save.unverified");
        if (state.Rejection is { } rejection) return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            operation, true, false, new(0, 1, 0), rejection));
        if (token.IsCancellationRequested) return Unknown();
        try
        {
            var current = (await LoadDirectoryAsync(state.DirectoryKind, token).ConfigureAwait(false)).FirstOrDefault(item => item.Name == state.Name);
            if (current is not null && NasDirectorySaveRules.Matches(current, state.Request.Desired) &&
                (state.Request.Baseline is null || current.NumericId == state.Request.Baseline.NumericId) && (!state.HasPassword || state.Accepted))
                return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0),
                    diagnosticTag: state.HasPassword ? "directory.save.accepted-and-verified" : "directory.save.verified"));
        }
        catch (Exception) { /* 不把缺失字段或读取失败当成保存成功。 */ }
        return Unknown();
    }
    private sealed class NasDirectorySaveOperation(string scope, string signature, NasDirectorySaveRequest request, bool hasPassword)
        : NasDirectoryOperation(scope, signature, request.Kind, request.Desired.Name, request.Baseline is null ? NasDirectoryOperationKind.Create : NasDirectoryOperationKind.Update)
    {
        public NasDirectorySaveRequest Request { get; } = request;
        public bool HasPassword { get; } = hasPassword;
        public bool Accepted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
}
