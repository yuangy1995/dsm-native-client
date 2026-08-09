using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<DownloadTaskCreateOutcome> CreateTaskFromFileAsync(
        DownloadTaskFileCreateRequest request,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return DownloadCreateOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                taskId: null,
                task: null,
                submitted: false,
                requiresRefresh: false,
                errorCategory: null,
                diagnosticTag: "download-station.create.cancelled-before");
        }

        if (request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id)
        {
            return DownloadCreateOutcome(
                MutationResultStatus.ConfirmedFailure,
                taskId: null,
                task: null,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "download-station.create.profile-mismatch");
        }

        if (!HasControllablePublicDownloadStationContract)
        {
            return DownloadCreateOutcome(
                MutationResultStatus.Unsupported,
                taskId: null,
                task: null,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Unsupported,
                diagnosticTag: "download-station.create.unsupported");
        }

        var key = DownloadTaskCreateReviewKey.FromFile(
            _profile.Id,
            _session,
            request.FileName,
            request.Length,
            request.Destination);
        var activeKey = new DownloadTaskCreateActiveKey(_profile.Id, key.Digest);
        var state = DownloadTaskCreateState;
        if (!state.TryClaim(activeKey))
        {
            return DownloadCreateOutcome(
                MutationResultStatus.ConfirmedFailure,
                taskId: null,
                task: null,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Conflict,
                diagnosticTag: "download-station.create.duplicate-submission");
        }

        try
        {
            if (state.TryGetReview(key, out var pendingReview))
            {
                return await FinishDownloadCreateAsync(
                    pendingReview,
                    submittedStatus: MutationResultStatus.SubmittedButUnverified,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }

            IReadOnlySet<string> previousIds;
            try
            {
                previousIds = (await LoadAllPublicDownloadTasksAsync(cancellationToken)
                    .ConfigureAwait(false))
                    .Select(task => task.Id)
                    .ToHashSet(StringComparer.Ordinal);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.CancelledBeforeSubmission,
                    taskId: null,
                    task: null,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.create.cancelled-during-preflight");
            }
            catch (DsmException error)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    taskId: null,
                    task: null,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: DownloadControlErrorCategory(error),
                    diagnosticTag: "download-station.create.preflight-failed");
            }
            catch (JsonException)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    taskId: null,
                    task: null,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: MutationErrorCategory.Server,
                    diagnosticTag: "download-station.create.preflight-invalid-response");
            }
            catch (IOException)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    taskId: null,
                    task: null,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: MutationErrorCategory.Network,
                    diagnosticTag: "download-station.create.preflight-read-failed");
            }

            if (cancellationToken.IsCancellationRequested)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.CancelledBeforeSubmission,
                    taskId: null,
                    task: null,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.create.cancelled-before-write");
            }

            var review = new DownloadTaskCreateReview(
                key,
                previousIds,
                ExpectedTaskId: null,
                request.Destination);
            DownloadTaskFileCreateTransportResult submission;
            try
            {
                submission = await _api.CreateDownloadTaskFromFileAsync(
                    _profile,
                    _session,
                    _capabilities[PublicDownloadTaskApi],
                    request,
                    progress: null,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                state.StoreReview(review);
                return await FinishDownloadCreateAsync(
                    review,
                    submittedStatus: MutationResultStatus.CancellationRequestedAfterSubmission,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception)
            {
                state.StoreReview(review);
                return await FinishDownloadCreateAsync(
                    review,
                    submittedStatus: MutationResultStatus.SubmittedButUnverified,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }
            switch (submission.Status)
            {
                case DownloadTaskFileCreateTransportStatus.CancelledBeforeSubmission:
                    return DownloadCreateOutcome(
                        MutationResultStatus.CancelledBeforeSubmission,
                        taskId: null,
                        task: null,
                        submitted: false,
                        requiresRefresh: false,
                        errorCategory: null,
                        diagnosticTag: "download-station.create.cancelled-before");
                case DownloadTaskFileCreateTransportStatus.Unsupported:
                    return DownloadCreateOutcome(
                        MutationResultStatus.Unsupported,
                        taskId: null,
                        task: null,
                        submitted: false,
                        requiresRefresh: false,
                        errorCategory: MutationErrorCategory.Unsupported,
                        diagnosticTag: submission.DiagnosticTag ?? "download-station.create.unsupported");
                case DownloadTaskFileCreateTransportStatus.ConfirmedFailure:
                    return DownloadCreateOutcome(
                        submission.ErrorCategory == MutationErrorCategory.Permission
                            ? MutationResultStatus.PermissionDenied
                            : MutationResultStatus.ConfirmedFailure,
                        taskId: null,
                        task: null,
                        submitted: true,
                        requiresRefresh: true,
                        errorCategory: submission.ErrorCategory ?? MutationErrorCategory.Server,
                        diagnosticTag: submission.DiagnosticTag ?? "download-station.create.rejected");
                case DownloadTaskFileCreateTransportStatus.CancellationRequestedAfterSubmission:
                    state.StoreReview(review);
                    return await FinishDownloadCreateAsync(
                        review,
                        submittedStatus: MutationResultStatus.CancellationRequestedAfterSubmission,
                        cancellationToken: CancellationToken.None).ConfigureAwait(false);
                case DownloadTaskFileCreateTransportStatus.SubmittedButUnverified:
                    state.StoreReview(review);
                    return await FinishDownloadCreateAsync(
                        review,
                        submittedStatus: MutationResultStatus.SubmittedButUnverified,
                        cancellationToken: CancellationToken.None).ConfigureAwait(false);
                case DownloadTaskFileCreateTransportStatus.Accepted:
                    review = review with { ExpectedTaskId = submission.TaskId };
                    state.StoreReview(review);
                    return await FinishDownloadCreateAsync(
                        review,
                        submittedStatus: MutationResultStatus.SubmittedButUnverified,
                        cancellationToken: CancellationToken.None).ConfigureAwait(false);
                default:
                    state.StoreReview(review);
                    return await FinishDownloadCreateAsync(
                        review,
                        submittedStatus: MutationResultStatus.SubmittedButUnverified,
                        cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }
        }
        finally
        {
            state.Release(activeKey);
        }
    }
}
