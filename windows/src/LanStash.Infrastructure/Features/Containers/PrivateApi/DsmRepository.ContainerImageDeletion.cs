using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteImages => CanMutateContainers && HasInternalObservedContainerVersion(InternalObservedImageApi) &&
        NasServiceFormatAndPathSupported(_capabilities[InternalObservedImageApi]);

    public async Task<MutationResult> DeleteImagesAsync(ContainerImageDeleteRequest request, CancellationToken cancellationToken = default)
    {
        const string operation = "deleteContainerImages";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baselines is null || request.Baselines.Count == 0 || request.ProfileId != _profile.Id ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var targets = request.Baselines.ToArray();
        if (targets.Any(target => !ContainerImageDeletionRules.CanDelete(target)) || targets.Select(item => item.Id).Distinct().Count() != targets.Length)
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (!CanDeleteImages) return UnsupportedResult(operation);
        var scope = ServiceScope(); var shared = ServiceMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(targets.OrderBy(item => item.Id, StringComparer.Ordinal)));
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous is ContainerImageDeleteOperation prior && prior.Scope == scope && prior.Signature == signature
                    ? prior.Final ?? await ReviewContainerImageDeletionAsync(prior, cancellationToken).ConfigureAwait(false)
                    : ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.ImageDeletions.Values.Any(state => state.Scope == scope && state.Targets.Any(pending =>
                    targets.Any(target => ImageTargetsOverlap(pending.Image!, target.Image!)))))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                var current = await LoadContainerImagesAsync(cancellationToken).ConfigureAwait(false);
                if (current.Any(item => item.Image is null) || targets.Any(target => !current.Contains(target)))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (shared.ImagePulls.Values.Any(pull => pull.Scope == scope && targets.Any(target =>
                        ImageAddress(target.Image!) == pull.Address || target.Image!.UsesIdentity && pull.BaselineIds.Contains(target.Image.ImageId, StringComparer.Ordinal))))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                // identity 删除影响整个底层镜像；不能把同 ID 的其他有效标签也隐含删除。
                if (targets.Any(target => target.Image!.UsesIdentity && current.Any(item =>
                        item.Image!.ImageId == target.Image.ImageId && !item.Image.UsesIdentity)))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (!await ContainerImagesAreUnusedAsync(targets, current, cancellationToken).ConfigureAwait(false))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new ContainerImageDeleteOperation(scope, signature, request.RequestId, targets);
            shared.Operations.Add(request.RequestId, state); shared.ImageDeletions.Add(request.RequestId, state);
            try
            {
                var objects = targets.Where(item => !item.Image!.UsesIdentity).GroupBy(item => item.Image!.Repository, StringComparer.Ordinal)
                    .Select(group => new Dictionary<string, object> { ["repository"] = group.Key, ["tags"] = group.Select(item => item.Image!.Tag).ToArray() }).ToList();
                objects.AddRange(targets.Where(item => item.Image!.UsesIdentity).Select(item => item.Image!.ImageId).Distinct(StringComparer.Ordinal)
                    .Select(id => new Dictionary<string, object> { ["identity"] = id }));
                var capability = _capabilities[InternalObservedImageApi] with { MinVersion = 1, MaxVersion = 1 };
                await SecurityCallAsync(capability, "delete", new Dictionary<string, object> { ["images"] = objects.ToArray() }, cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 已提交可能成功：保留锁，只回读，不重放。 */ }
            return await ReviewContainerImageDeletionAsync(state, cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<ContainerImageDeletionRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return shared.ImageDeletions.Values.Where(state => state.Scope == ServiceScope()).Select(state =>
            new ContainerImageDeletionRecovery(state.RequestId, Array.AsReadOnly(state.Targets.ToArray()))).ToArray(); }
        finally { shared.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewImageDeletionAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        if (!CanDeleteImages) return UnsupportedResult("deleteContainerImages");
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("deleteContainerImages", MutationErrorCategory.Conflict); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("deleteContainerImages"); }
        try { return shared.Operations.TryGetValue(requestId, out var previous) && previous is ContainerImageDeleteOperation state && state.Scope == ServiceScope()
            ? state.Final ?? await ReviewContainerImageDeletionAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewContainerImageDeletionAsync(ContainerImageDeleteOperation state, CancellationToken token)
    {
        if (state.Final is not null) return state.Final;
        const string operation = "deleteContainerImages";
        MutationResult Finish(MutationResult result)
        { state.Final = result; ServiceMutations.ImageDeletions.Remove(state.RequestId); return result; }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                operation, true, true, new(0, state.Targets.Count, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var current = await LoadContainerImagesAsync(token).ConfigureAwait(false);
            if (current.Any(item => item.Image is null)) throw InvalidContainerManagerResponse();
            foreach (var target in state.Targets)
            {
                var reference = target.Image!;
                var exists = current.Any(item => reference.UsesIdentity ? item.Image!.ImageId == reference.ImageId :
                    ImageAddress(item.Image!) == ImageAddress(reference));
                if (!exists) state.VerifiedIds.Add(target.Id);
            }
        }
        catch (DsmException error) { category = ServiceErrorCategory(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        var succeeded = state.VerifiedIds.Count; var unknown = state.Targets.Count - succeeded;
        if (unknown == 0) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(succeeded, 0, 0)));
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
            succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(succeeded, 0, unknown), category);
    }

    private static bool ImageTargetsOverlap(ContainerImageReference left, ContainerImageReference right) =>
        (left.UsesIdentity || right.UsesIdentity) && left.ImageId == right.ImageId || ImageAddress(left) == ImageAddress(right);

    private sealed class ContainerImageDeleteOperation(string scope, string signature, Guid requestId, IReadOnlyList<ContainerResourceSummary> targets)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerImages)
    {
        public Guid RequestId { get; } = requestId;
        public IReadOnlyList<ContainerResourceSummary> Targets { get; } = targets;
        public HashSet<string> VerifiedIds { get; } = new(StringComparer.Ordinal);
        public MutationErrorCategory? Rejection { get; set; }
    }
}
