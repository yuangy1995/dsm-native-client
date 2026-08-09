using System.Runtime.CompilerServices;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IDsmApiClient, DownloadTaskDeleteApiState>
        DownloadTaskDeleteStates = new();

    private DownloadTaskDeleteApiState DownloadTaskDeleteState =>
        DownloadTaskDeleteStates.GetValue(_api, _ => new DownloadTaskDeleteApiState());

    public async Task<DownloadTaskDeleteOutcome> DeleteTaskAsync(
        DownloadTaskDeleteRequest request,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return DownloadDeleteOutcome(
                request.Task.Id,
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                errorCategory: null,
                diagnosticTag: "download-station.delete.cancelled-before-submission");
        }

        if (request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id)
        {
            return DownloadDeleteOutcome(
                request.Task.Id,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "download-station.delete.profile-mismatch");
        }

        var taskId = request.Task.Id.Trim();
        if (string.IsNullOrEmpty(taskId) ||
            !string.Equals(taskId, request.Task.Id, StringComparison.Ordinal))
        {
            return DownloadDeleteOutcome(
                request.Task.Id,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "download-station.delete.invalid-task");
        }

        if (!HasControllablePublicDownloadStationContract)
        {
            return DownloadDeleteOutcome(
                taskId,
                MutationResultStatus.Unsupported,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Unsupported,
                diagnosticTag: "download-station.delete.unsupported");
        }

        var reviewKey = DownloadTaskDeleteReviewKey.From(_profile.Id, _session, taskId);
        var activeKey = new DownloadTaskDeleteActiveKey(_profile.Id, taskId);
        var state = DownloadTaskDeleteState;
        if (!state.TryClaim(activeKey))
        {
            return DownloadDeleteOutcome(
                taskId,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Conflict,
                diagnosticTag: "download-station.delete.duplicate-submission");
        }

        try
        {
            if (state.TryGetReview(reviewKey, out var pendingReview))
            {
                return await FinishDownloadDeleteAsync(
                    pendingReview,
                    MutationResultStatus.SubmittedButUnverified,
                    CancellationToken.None).ConfigureAwait(false);
            }

            IReadOnlyList<DownloadTask> tasks;
            try
            {
                tasks = await LoadAllPublicDownloadTasksAsync(cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.delete.cancelled-during-preflight");
            }
            catch (DsmException error)
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: DownloadControlErrorCategory(error),
                    diagnosticTag: "download-station.delete.preflight-failed");
            }
            catch (System.Text.Json.JsonException)
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: MutationErrorCategory.Server,
                    diagnosticTag: "download-station.delete.preflight-invalid-response");
            }
            catch (IOException)
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: MutationErrorCategory.Network,
                    diagnosticTag: "download-station.delete.preflight-read-failed");
            }

            var current = tasks.SingleOrDefault(task =>
                string.Equals(task.Id, taskId, StringComparison.Ordinal));
            if (current is null || !DownloadDeleteBaselineMatches(request.Task, current))
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: MutationErrorCategory.Conflict,
                    diagnosticTag: "download-station.delete.baseline-changed");
            }

            if (cancellationToken.IsCancellationRequested)
            {
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.delete.cancelled-before-write");
            }

            var review = new DownloadTaskDeleteReview(reviewKey, taskId);
            try
            {
                _ = await CallPublicDownloadAsync(
                    PublicDownloadTaskApi,
                    "delete",
                    new Dictionary<string, string>(StringComparer.Ordinal)
                    {
                        ["id"] = taskId,
                        ["force_complete"] = "false",
                    },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                state.StoreReview(review);
                return await FinishDownloadDeleteAsync(
                    review,
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch (DsmException error)
            {
                var category = DownloadControlErrorCategory(error);
                if (category == MutationErrorCategory.Permission)
                {
                    return DownloadDeleteOutcome(
                        taskId,
                        MutationResultStatus.PermissionDenied,
                        submitted: true,
                        requiresRefresh: true,
                        errorCategory: MutationErrorCategory.Permission,
                        diagnosticTag: "download-station.delete.permission");
                }
                if (category == MutationErrorCategory.Unsupported)
                {
                    return DownloadDeleteOutcome(
                        taskId,
                        MutationResultStatus.Unsupported,
                        submitted: false,
                        requiresRefresh: false,
                        errorCategory: MutationErrorCategory.Unsupported,
                        diagnosticTag: "download-station.delete.unsupported-response");
                }
                return DownloadDeleteOutcome(
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: true,
                    requiresRefresh: true,
                    errorCategory: category,
                    diagnosticTag: "download-station.delete.rejected");
            }
            catch (Exception)
            {
                state.StoreReview(review);
                return await FinishDownloadDeleteAsync(
                    review,
                    MutationResultStatus.SubmittedButUnverified,
                    CancellationToken.None).ConfigureAwait(false);
            }

            state.StoreReview(review);
            return await FinishDownloadDeleteAsync(
                review,
                MutationResultStatus.SubmittedButUnverified,
                CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            state.Release(activeKey);
        }
    }

    private async Task<DownloadTaskDeleteOutcome> FinishDownloadDeleteAsync(
        DownloadTaskDeleteReview review,
        MutationResultStatus submittedStatus,
        CancellationToken cancellationToken)
    {
        try
        {
            var tasks = await LoadAllPublicDownloadTasksAsync(cancellationToken).ConfigureAwait(false);
            var stillExists = tasks.Any(task =>
                string.Equals(task.Id, review.TaskId, StringComparison.Ordinal));
            if (!stillExists)
            {
                DownloadTaskDeleteState.ClearReview(review.Key);
                return DownloadDeleteOutcome(
                    review.TaskId,
                    MutationResultStatus.ConfirmedSuccess,
                    submitted: true,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.delete.confirmed");
            }
        }
        catch (OperationCanceledException)
        {
            submittedStatus = MutationResultStatus.CancellationRequestedAfterSubmission;
        }
        catch
        {
        }

        DownloadTaskDeleteState.StoreReview(review);
        return DownloadDeleteOutcome(
            review.TaskId,
            submittedStatus,
            submitted: true,
            requiresRefresh: true,
            errorCategory: MutationErrorCategory.Unknown,
            diagnosticTag: submittedStatus == MutationResultStatus.CancellationRequestedAfterSubmission
                ? "download-station.delete.cancelled-after"
                : "download-station.delete.unverified");
    }

    private static bool DownloadDeleteBaselineMatches(
        DownloadTask baseline,
        DownloadTask current) =>
        string.Equals(baseline.Id, current.Id, StringComparison.Ordinal) &&
        baseline.State == current.State &&
        string.Equals(baseline.RawStatus, current.RawStatus, StringComparison.Ordinal);

    private static DownloadTaskDeleteOutcome DownloadDeleteOutcome(
        string taskId,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        MutationErrorCategory? errorCategory,
        string diagnosticTag)
    {
        var succeeded = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var failed = status is MutationResultStatus.ConfirmedFailure or
            MutationResultStatus.PermissionDenied or
            MutationResultStatus.Unsupported ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        return new(
            new MutationResult(
                1,
                status,
                "downloadTaskDelete",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                errorCategory,
                localizationKey: $"download-station.delete.{status.ToString().ToLowerInvariant()}",
                diagnosticTag),
            taskId);
    }

    private readonly record struct DownloadTaskDeleteActiveKey(Guid ProfileId, string TaskId);

    private readonly record struct DownloadTaskDeleteReviewKey(
        Guid ProfileId,
        Guid SessionProfileId,
        string SessionId,
        string TaskId)
    {
        public static DownloadTaskDeleteReviewKey From(
            Guid profileId,
            DsmSession session,
            string taskId) =>
            new(profileId, session.ProfileId, session.Sid, taskId);
    }

    private sealed record DownloadTaskDeleteReview(
        DownloadTaskDeleteReviewKey Key,
        string TaskId);

    private sealed class DownloadTaskDeleteApiState
    {
        private readonly object _gate = new();
        private readonly HashSet<DownloadTaskDeleteActiveKey> _active = [];
        private readonly Dictionary<DownloadTaskDeleteReviewKey, DownloadTaskDeleteReview> _reviews = [];

        public bool TryClaim(DownloadTaskDeleteActiveKey key)
        {
            lock (_gate)
            {
                return _active.Add(key);
            }
        }

        public void Release(DownloadTaskDeleteActiveKey key)
        {
            lock (_gate)
            {
                _active.Remove(key);
            }
        }

        public bool TryGetReview(
            DownloadTaskDeleteReviewKey key,
            out DownloadTaskDeleteReview review)
        {
            lock (_gate)
            {
                return _reviews.TryGetValue(key, out review!);
            }
        }

        public void StoreReview(DownloadTaskDeleteReview review)
        {
            lock (_gate)
            {
                _reviews[review.Key] = review;
            }
        }

        public void ClearReview(DownloadTaskDeleteReviewKey key)
        {
            lock (_gate)
            {
                _reviews.Remove(key);
            }
        }
    }
}
