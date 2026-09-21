using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string ImagePullOperation = "pullContainerImage";
    private bool CanReadImagePullStatus => _profile.Id != Guid.Empty && _session.ProfileId == _profile.Id && !string.IsNullOrWhiteSpace(_session.Sid) &&
        HasInternalObservedContainerVersion(InternalObservedImageApi) && NasServiceFormatAndPathSupported(_capabilities[InternalObservedImageApi]);
    public bool CanPullImages => CanReadImagePullStatus && CanBrowseRegistry && NasServiceFormatAndPathSupported(_capabilities[InternalObservedRegistryApi]);

    public async Task<ContainerImagePullResult> PullImageAsync(ContainerImagePullRequest request, CancellationToken cancellationToken = default)
    {
        ContainerImagePullResult Reject(MutationResult outcome) => new(request?.RequestId ?? Guid.Empty, request?.Repository ?? "", request?.Tag ?? "",
            ContainerImagePullStage.Rejected, null, outcome);
        if (cancellationToken.IsCancellationRequested) return Reject(CancelledBeforeSubmissionResult(ImagePullOperation));
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed ||
            !ContainerImagePullRules.IsValidTarget(request.Repository, request.Tag)) return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Validation));
        if (!CanPullImages) return Reject(UnsupportedResult(ImagePullOperation));
        var shared = ServiceMutations; var scope = ServiceScope();
        var address = NormalizeImageName($"{request.Repository}:{request.Tag}");
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Repository, request.Tag }));
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Conflict)); }
        catch (OperationCanceledException) { return Reject(CancelledBeforeSubmissionResult(ImagePullOperation)); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous is ContainerImagePullOperation prior && prior.Scope == scope && prior.Signature == signature
                    ? prior.Final is not null ? prior.LastResult! : await ReviewContainerImagePullAsync(prior, cancellationToken).ConfigureAwait(false)
                    : Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Conflict));
            if (shared.ImagePulls.Values.Any(pending => pending.Scope == scope && pending.Address == address))
                return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Conflict, true));
            string[] baselineIds;
            try
            {
                // 先核查套件读取权限、当前标签和可能冲突的删除；不自行访问第三方仓库。
                var tags = await LoadRegistryTagsAsync(request.Repository, cancellationToken).ConfigureAwait(false);
                if (!tags.Contains(request.Tag, StringComparer.Ordinal)) return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Conflict, true));
                var images = await LoadContainerImagesAsync(cancellationToken).ConfigureAwait(false);
                if (images.Any(image => image.Image is null)) return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Unsupported));
                baselineIds = images.Where(image => ImageAddress(image.Image!) == address).Select(image => image.Image!.ImageId).ToArray();
                if (shared.ImageDeletions.Values.Any(pending => pending.Scope == scope && pending.Targets.Any(target =>
                        ImageAddress(target.Image!) == address || target.Image!.UsesIdentity && baselineIds.Contains(target.Image.ImageId, StringComparer.Ordinal))))
                    return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Conflict, true));
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return Reject(CancelledBeforeSubmissionResult(ImagePullOperation)); }
            catch (DsmException error) { return Reject(ServicePreflightFailure(ImagePullOperation, ServiceErrorCategory(error))); }
            catch (Exception) { return Reject(ServicePreflightFailure(ImagePullOperation, MutationErrorCategory.Network)); }

            var state = new ContainerImagePullOperation(scope, signature, request, address, baselineIds);
            shared.Operations.Add(request.RequestId, state); shared.ImagePulls.Add(request.RequestId, state);
            SetImagePullResult(state, ContainerImagePullStage.AwaitingReceipt);
            try
            {
                var capability = _capabilities[InternalObservedImageApi] with { MinVersion = 1, MaxVersion = 1 };
                var response = await SecurityCallAsync(capability, "pull_start", new Dictionary<string, object>
                    { ["repository"] = request.Repository, ["tag"] = request.Tag }, cancellationToken).ConfigureAwait(false);
                state.TaskId = ImagePullTaskId(response["task_id"]);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                var category = ServiceErrorCategory(error);
                return SetImagePullResult(state, ContainerImagePullStage.Rejected, outcome: new(1,
                    category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                    ImagePullOperation, true, false, new(0, 1, 0), category));
            }
            catch (Exception) { /* 启动可能已成功，无回执不得按名称猜测任务或重发。 */ }
            return await ReviewContainerImagePullAsync(state, cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<ContainerImagePullResult>> GetImagePullRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return shared.ImagePulls.Values.Where(state => state.Scope == ServiceScope()).Select(state => state.LastResult!).ToArray(); }
        finally { shared.Gate.Release(); }
    }

    public async Task<ContainerImagePullResult?> ReviewImagePullAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return null;
        try
        {
            return shared.Operations.TryGetValue(requestId, out var previous) && previous is ContainerImagePullOperation state && state.Scope == ServiceScope()
                ? state.Final is not null ? state.LastResult : await ReviewContainerImagePullAsync(state, cancellationToken).ConfigureAwait(false) : null;
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<ContainerImagePullResult> ReviewContainerImagePullAsync(ContainerImagePullOperation state, CancellationToken token)
    {
        if (state.Final is not null) return state.LastResult!;
        if (token.IsCancellationRequested) return SetImagePullResult(state,
            state.TaskId is null ? ContainerImagePullStage.AwaitingReceipt : ContainerImagePullStage.NeedsReview,
            outcome: new(1, MutationResultStatus.CancellationRequestedAfterSubmission, ImagePullOperation, true, true, new(0, 0, 1)));
        if (state.TaskId is null) return SetImagePullResult(state, ContainerImagePullStage.AwaitingReceipt);
        try
        {
            if (!CanReadImagePullStatus) return SetImagePullResult(state, ContainerImagePullStage.NeedsReview, error: MutationErrorCategory.Unsupported);
            var capability = _capabilities[InternalObservedImageApi] with { MinVersion = 1, MaxVersion = 1 };
            var data = await SecurityCallAsync(capability, "pull_status", new Dictionary<string, object> { ["task_id"] = state.TaskId }, token).ConfigureAwait(false);
            var repository = OptionalImageString(data, "repository"); var tag = OptionalImageString(data, "tag");
            if (repository is null || tag is null || NormalizeImageName($"{repository}:{tag}") != state.Address ||
                data["finished"] is not JsonValue finishedValue || !finishedValue.TryGetValue<bool>(out var finished))
                return SetImagePullResult(state, ContainerImagePullStage.NeedsReview);
            var percentage = ImagePullPercentage(data);
            if (!finished) return SetImagePullResult(state, ContainerImagePullStage.Downloading, percentage);
            // 同一任务明确结束且标签可用才完成；旧标签存在或百分比达到 100 都不足以证明结束。
            var images = await LoadContainerImagesAsync(token).ConfigureAwait(false);
            if (images.Any(image => image.Image is null) || !images.Any(image => ImageAddress(image.Image!) == state.Address))
                return SetImagePullResult(state, ContainerImagePullStage.NeedsReview);
            return SetImagePullResult(state, ContainerImagePullStage.Ready, 100,
                outcome: new(1, MutationResultStatus.ConfirmedSuccess, ImagePullOperation, true, true, new(1, 0, 0)));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        { return SetImagePullResult(state, ContainerImagePullStage.NeedsReview, outcome: new(1, MutationResultStatus.CancellationRequestedAfterSubmission, ImagePullOperation, true, true, new(0, 0, 1))); }
        catch (DsmException error) { return SetImagePullResult(state, ContainerImagePullStage.NeedsReview, error: ServiceErrorCategory(error)); }
        catch (Exception) { return SetImagePullResult(state, ContainerImagePullStage.NeedsReview, error: MutationErrorCategory.Network); }
    }

    private ContainerImagePullResult SetImagePullResult(ContainerImagePullOperation state, ContainerImagePullStage stage,
        double? percentage = null, MutationResult? outcome = null, MutationErrorCategory error = MutationErrorCategory.Unknown)
    {
        outcome ??= new(1, MutationResultStatus.SubmittedButUnverified, ImagePullOperation, true, true, new(0, 0, 1), error);
        var result = new ContainerImagePullResult(state.Request.RequestId, state.Request.Repository, state.Request.Tag, stage, percentage, outcome);
        state.LastResult = result;
        if (stage is ContainerImagePullStage.Ready or ContainerImagePullStage.Rejected)
        { state.Final = outcome; ServiceMutations.ImagePulls.Remove(state.Request.RequestId); }
        return result;
    }
    private async Task<MutationResult> ReviewContainerImagePullMutationAsync(ContainerImagePullOperation state, CancellationToken token) =>
        (await ReviewContainerImagePullAsync(state, token).ConfigureAwait(false)).Outcome;
    private static object? ImagePullTaskId(JsonNode? node)
    {
        if (node is not JsonValue value) return null;
        if (value.TryGetValue<string>(out var text) && StableImageText(text)) return text;
        if (value.TryGetValue<long>(out var number) && number >= 0) return number;
        return null;
    }
    private static double? ImagePullPercentage(JsonObject data)
    {
        if (data["current"] is JsonValue currentNode && currentNode.TryGetValue<double>(out var current) &&
            data["total"] is JsonValue totalNode && totalNode.TryGetValue<double>(out var total) &&
            double.IsFinite(current) && double.IsFinite(total) && total > 0 && current >= 0 && current <= total) return current / total * 100;
        return null;
    }
    private sealed class ContainerImagePullOperation(string scope, string signature, ContainerImagePullRequest request, string address, string[] baselineIds)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerImagePull)
    {
        public ContainerImagePullRequest Request { get; } = request;
        public string Address { get; } = address;
        public string[] BaselineIds { get; } = baselineIds;
        public object? TaskId { get; set; }
        public ContainerImagePullResult? LastResult { get; set; }
    }
}
