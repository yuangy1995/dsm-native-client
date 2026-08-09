using System.Globalization;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Download Station 官方公开只读接口适配器。内部 DownloadStation2 API 不属于本契约。
/// </summary>
public sealed partial class DsmRepository
{
    private const string PublicDownloadTaskApi = "SYNO.DownloadStation.Task";
    private const string PublicDownloadStatisticApi = "SYNO.DownloadStation.Statistic";
    private const int PublicDownloadApiVersion = 1;
    private const int MaximumTaskPageSize = 100;
    private const int MaximumTaskReadbackItems = 5_000;
    private static readonly ConditionalWeakTable<IDsmApiClient, DownloadTaskControlApiState>
        DownloadTaskControlStates = new();
    private static readonly ConditionalWeakTable<IDsmApiClient, DownloadTaskCreateApiState>
        DownloadTaskCreateStates = new();

    private static readonly IReadOnlySet<DownloadStationReadFeature> PublicDownloadTaskFeatures =
        new HashSet<DownloadStationReadFeature>
        {
            DownloadStationReadFeature.Tasks,
        };

    private bool HasReadablePublicDownloadStationContract =>
        HasPublicDownloadVersion(PublicDownloadTaskApi);

    private DownloadStationAvailability PublicDownloadAvailability
    {
        get
        {
            if (!HasReadablePublicDownloadStationContract)
            {
                return new(
                    DownloadStationAvailabilityStatus.Unavailable,
                    new HashSet<DownloadStationReadFeature>());
            }

            var features = new HashSet<DownloadStationReadFeature>(PublicDownloadTaskFeatures);
            if (HasPublicDownloadVersion(PublicDownloadStatisticApi))
            {
                features.Add(DownloadStationReadFeature.ActivitySummary);
            }
            return new(DownloadStationAvailabilityStatus.Available, features);
        }
    }

    DownloadStationAvailability IDownloadStationRepository.Availability =>
        PublicDownloadAvailability;

    private DownloadTaskControlApiState DownloadTaskControlState =>
        DownloadTaskControlStates.GetValue(_api, _ => new DownloadTaskControlApiState());

    private DownloadTaskCreateApiState DownloadTaskCreateState =>
        DownloadTaskCreateStates.GetValue(_api, _ => new DownloadTaskCreateApiState());

    public async Task<DownloadTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default)
    {
        EnsureReadablePublicDownloadStationContract();
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var safeLimit = Math.Min(limit, MaximumTaskPageSize);
        var data = await CallPublicDownloadAsync(
            PublicDownloadTaskApi,
            "list",
            new Dictionary<string, string>
            {
                ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                ["limit"] = safeLimit.ToString(CultureInfo.InvariantCulture),
                ["additional"] = "detail,transfer",
            },
            cancellationToken).ConfigureAwait(false);

        var sourceOffset = RequiredNonNegativeInt(data, "offset");
        var sourceTotal = RequiredNonNegativeInt(data, "total");
        if (sourceOffset != offset || data["tasks"] is not JsonArray sourceTasks)
        {
            throw InvalidDownloadStationResponse();
        }

        var taskObjects = new JsonObject[sourceTasks.Count];
        for (var index = 0; index < sourceTasks.Count; index++)
        {
            taskObjects[index] = sourceTasks[index] as JsonObject
                ?? throw InvalidDownloadStationResponse();
        }
        if (sourceTotal < sourceOffset || sourceTasks.Count > safeLimit)
        {
            throw InvalidDownloadStationResponse();
        }
        if (sourceOffset > int.MaxValue - sourceTasks.Count)
        {
            throw InvalidDownloadStationResponse();
        }
        var nextOffset = sourceOffset + sourceTasks.Count;
        if (nextOffset > sourceTotal ||
            (sourceTasks.Count == 0 && sourceOffset < sourceTotal))
        {
            throw InvalidDownloadStationResponse();
        }

        var tasks = taskObjects.Select(ParsePublicDownloadTask).ToArray();
        if (tasks.Select(task => task.Id).Distinct(StringComparer.Ordinal).Count() != tasks.Length)
        {
            throw InvalidDownloadStationResponse();
        }
        var hasMore = nextOffset < sourceTotal;
        return new(
            tasks,
            sourceOffset,
            sourceTasks.Count,
            sourceTotal,
            hasMore ? nextOffset : null,
            hasMore);
    }

    public async Task<DownloadStationSnapshot> LoadSnapshotAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default)
    {
        var tasks = await ListTasksAsync(offset, limit, cancellationToken).ConfigureAwait(false);
        var activity = await LoadPublicDownloadActivityAsync(cancellationToken).ConfigureAwait(false);
        return new(
            _profile.Id,
            tasks,
            activity,
            new(DownloadStationSectionStatus.Unavailable, null));
    }

    public async Task<DownloadTaskCreateOutcome> CreateTaskAsync(
        DownloadTaskCreateRequest request,
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

        if (!TryPrepareDownloadCreateRequest(
                request,
                out var normalizedUri,
                out var normalizedDestination))
        {
            return DownloadCreateOutcome(
                MutationResultStatus.ConfirmedFailure,
                taskId: null,
                task: null,
                submitted: false,
                requiresRefresh: false,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "download-station.create.invalid-input");
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

        var key = DownloadTaskCreateReviewKey.From(
            _profile.Id,
            _session,
            normalizedUri,
            normalizedDestination);
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

            var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["uri"] = normalizedUri,
            };
            if (normalizedDestination is not null)
            {
                parameters["destination"] = normalizedDestination;
            }
            var review = new DownloadTaskCreateReview(
                key,
                previousIds,
                ExpectedTaskId: null,
                normalizedDestination);
            JsonObject response;
            try
            {
                response = await CallPublicDownloadAsync(
                    PublicDownloadTaskApi,
                    "create",
                    parameters,
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
            catch (DsmException error) when (DownloadControlErrorCategory(error) == MutationErrorCategory.Permission)
            {
                return DownloadCreateOutcome(
                    MutationResultStatus.PermissionDenied,
                    taskId: null,
                    task: null,
                    submitted: true,
                    requiresRefresh: true,
                    errorCategory: MutationErrorCategory.Permission,
                    diagnosticTag: "download-station.create.permission");
            }
            catch (Exception)
            {
                state.StoreReview(review);
                return await FinishDownloadCreateAsync(
                    review,
                    submittedStatus: MutationResultStatus.SubmittedButUnverified,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }

            review = review with { ExpectedTaskId = StableDownloadId(response["taskid"] ?? response["task_id"] ?? response["taskId"] ?? response["id"]) };
            state.StoreReview(review);
            return await FinishDownloadCreateAsync(
                review,
                submittedStatus: MutationResultStatus.SubmittedButUnverified,
                cancellationToken: CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            state.Release(activeKey);
        }
    }

    public async Task<DownloadTaskControlOutcome> ControlTaskAsync(
        DownloadTaskControlRequest request,
        CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return DownloadControlOutcome(
                request.Action,
                request.Task.Id,
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: null,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "cancelled-before-submission"));
        }

        if (request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id)
        {
            return DownloadControlOutcome(
                request.Action,
                request.Task.Id,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "profile-mismatch"));
        }

        var taskId = request.Task.Id.Trim();
        if (string.IsNullOrEmpty(taskId) || !string.Equals(taskId, request.Task.Id, StringComparison.Ordinal))
        {
            return DownloadControlOutcome(
                request.Action,
                request.Task.Id,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "invalid-task"));
        }

        if (!DownloadControlAccepts(request.Action, request.Task.State))
        {
            return DownloadControlOutcome(
                request.Action,
                taskId,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: MutationErrorCategory.Conflict,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "invalid-state"));
        }

        if (!HasControllablePublicDownloadStationContract)
        {
            return DownloadControlOutcome(
                request.Action,
                taskId,
                MutationResultStatus.Unsupported,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: MutationErrorCategory.Unsupported,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "unsupported"));
        }

        var reviewKey = DownloadTaskControlReviewKey.From(_profile.Id, _session, taskId, request.Action);
        var activeKey = new DownloadTaskControlActiveKey(_profile.Id, taskId);
        var state = DownloadTaskControlState;
        if (!state.TryClaim(activeKey))
        {
            return DownloadControlOutcome(
                request.Action,
                taskId,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                task: null,
                errorCategory: MutationErrorCategory.Conflict,
                diagnosticTag: DownloadControlDiagnostic(request.Action, "duplicate-submission"));
        }

        try
        {
            if (state.TryGetReview(reviewKey, out var pendingReview))
            {
                return await FinishDownloadControlAsync(
                    pendingReview,
                    submittedStatus: MutationResultStatus.SubmittedButUnverified,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }

            DownloadTask current;
            try
            {
                current = await LoadExactDownloadTaskAsync(taskId, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    task: null,
                    errorCategory: null,
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "cancelled-during-preflight"));
            }
            catch (DsmException error)
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    task: null,
                    errorCategory: DownloadControlErrorCategory(error),
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "preflight-failed"));
            }
            catch (JsonException)
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    task: null,
                    errorCategory: MutationErrorCategory.Server,
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "preflight-invalid-response"));
            }
            catch (IOException)
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    task: null,
                    errorCategory: MutationErrorCategory.Network,
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "preflight-read-failed"));
            }

            if (!DownloadControlBaselineMatches(request.Task, current) ||
                !DownloadControlAccepts(request.Action, current.State))
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    task: current,
                    errorCategory: MutationErrorCategory.Conflict,
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "baseline-changed"));
            }

            if (cancellationToken.IsCancellationRequested)
            {
                return DownloadControlOutcome(
                    request.Action,
                    taskId,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    task: current,
                    errorCategory: null,
                    diagnosticTag: DownloadControlDiagnostic(request.Action, "cancelled-before-write"));
            }

            var review = new DownloadTaskControlReview(reviewKey, taskId, request.Action);
            try
            {
                _ = await CallPublicDownloadAsync(
                    PublicDownloadTaskApi,
                    DownloadControlMethod(request.Action),
                    new Dictionary<string, string>
                    {
                        ["id"] = taskId,
                    },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                state.StoreReview(review);
                return await FinishDownloadControlAsync(
                    review,
                    submittedStatus: MutationResultStatus.CancellationRequestedAfterSubmission,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception)
            {
                state.StoreReview(review);
                return await FinishDownloadControlAsync(
                    review,
                    submittedStatus: MutationResultStatus.SubmittedButUnverified,
                    cancellationToken: CancellationToken.None).ConfigureAwait(false);
            }

            state.StoreReview(review);
            return await FinishDownloadControlAsync(
                review,
                submittedStatus: MutationResultStatus.SubmittedButUnverified,
                cancellationToken: CancellationToken.None).ConfigureAwait(false);
        }
        finally
        {
            state.Release(activeKey);
        }
    }

    private async Task<DownloadActivitySection> LoadPublicDownloadActivityAsync(
        CancellationToken cancellationToken)
    {
        if (!HasPublicDownloadVersion(PublicDownloadStatisticApi))
        {
            return new(DownloadStationSectionStatus.Unavailable, null);
        }
        try
        {
            var data = await CallPublicDownloadAsync(
                PublicDownloadStatisticApi,
                "getinfo",
                parameters: null,
                cancellationToken).ConfigureAwait(false);
            var value = new DownloadActivitySummary(
                RequiredNonNegativeLong(data, "speed_download"),
                RequiredNonNegativeLong(data, "speed_upload"),
                RequiredNonNegativeLong(data, "emule_speed_download"),
                RequiredNonNegativeLong(data, "emule_speed_upload"));
            return new(DownloadStationSectionStatus.Available, value);
        }
        catch (DsmException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (JsonException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (IOException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
    }

    private void EnsureReadablePublicDownloadStationContract()
    {
        if (_profile.Id != _session.ProfileId)
        {
            throw new InvalidOperationException(
                "Download Station requests require a session for the active NAS profile.");
        }
        if (!HasReadablePublicDownloadStationContract)
        {
            throw MissingPublicDownloadStationContract();
        }
    }

    private bool HasPublicDownloadVersion(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= PublicDownloadApiVersion &&
        capability.MaxVersion >= PublicDownloadApiVersion;

    private bool HasControllablePublicDownloadStationContract =>
        _capabilities.TryGetValue(PublicDownloadTaskApi, out var capability) &&
        capability.MinVersion <= PublicDownloadApiVersion &&
        capability.MaxVersion >= PublicDownloadApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private Task<JsonObject> CallPublicDownloadAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MinVersion > PublicDownloadApiVersion ||
            capability.MaxVersion < PublicDownloadApiVersion)
        {
            throw MissingPublicDownloadStationContract();
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                MinVersion = PublicDownloadApiVersion,
                MaxVersion = PublicDownloadApiVersion,
            },
            method,
            parameters,
            cancellationToken);
    }

    private static DownloadTask ParsePublicDownloadTask(JsonObject item)
    {
        var id = StableDownloadId(item["id"]);
        if (id is null)
        {
            throw InvalidDownloadStationResponse();
        }
        var rawStatus = item.String("status")?.Trim();
        if (string.IsNullOrEmpty(rawStatus))
        {
            throw InvalidDownloadStationResponse();
        }
        var transfer = item.Object("additional")?.Object("transfer");
        var detail = item.Object("additional")?.Object("detail");
        var statusExtra = item.Object("status_extra");
        return new DownloadTask(
            id,
            item.String("title")?.Trim() is { Length: > 0 } title ? title : id,
            rawStatus,
            ParsePublicDownloadTaskState(rawStatus),
            OptionalNonNegativeLong(item, "size"),
            OptionalNonNegativeLong(item, "size_downloaded")
                ?? OptionalNonNegativeLong(transfer, "size_downloaded"),
            OptionalNonNegativeLong(transfer, "size_uploaded"),
            OptionalNonNegativeLong(transfer, "speed_download"),
            OptionalNonNegativeLong(transfer, "speed_upload"),
            detail?.String("destination"),
            statusExtra?.String("error_detail"));
    }

    private static DownloadTaskState ParsePublicDownloadTaskState(string rawStatus) =>
        rawStatus.ToLowerInvariant() switch
        {
            "waiting" => DownloadTaskState.Waiting,
            "downloading" => DownloadTaskState.Downloading,
            "paused" => DownloadTaskState.Paused,
            "finished" => DownloadTaskState.Finished,
            "hash_checking" or "filehosting_waiting" or "extracting" =>
                DownloadTaskState.Checking,
            "seeding" => DownloadTaskState.Seeding,
            "error" => DownloadTaskState.Error,
            _ => DownloadTaskState.Unknown,
        };

    private async Task<DownloadTask> LoadExactDownloadTaskAsync(
        string taskId,
        CancellationToken cancellationToken)
    {
        var allTasks = await LoadAllPublicDownloadTasksAsync(cancellationToken).ConfigureAwait(false);
        return allTasks.SingleOrDefault(task => string.Equals(task.Id, taskId, StringComparison.Ordinal))
            ?? throw InvalidDownloadStationResponse();
    }

    private async Task<IReadOnlyList<DownloadTask>> LoadAllPublicDownloadTasksAsync(
        CancellationToken cancellationToken)
    {
        var offset = 0;
        var total = -1;
        var tasks = new List<DownloadTask>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (offset < MaximumTaskReadbackItems)
        {
            var page = await ListTasksAsync(offset, MaximumTaskPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (total >= 0 && page.SourceTotal != total)
            {
                throw InvalidDownloadStationResponse();
            }
            total = page.SourceTotal;
            foreach (var task in page.Tasks)
            {
                if (!seen.Add(task.Id))
                {
                    throw InvalidDownloadStationResponse();
                }
                tasks.Add(task);
            }
            if (!page.HasMore)
            {
                return tasks;
            }
            if (page.NextOffset is not int nextOffset || nextOffset <= offset)
            {
                throw InvalidDownloadStationResponse();
            }
            offset = nextOffset;
        }
        throw InvalidDownloadStationResponse();
    }

    private async Task<DownloadTaskControlOutcome> FinishDownloadControlAsync(
        DownloadTaskControlReview review,
        MutationResultStatus submittedStatus,
        CancellationToken cancellationToken)
    {
        try
        {
            var current = await LoadExactDownloadTaskAsync(review.TaskId, cancellationToken)
                .ConfigureAwait(false);
            if (DownloadControlConfirmed(review.Action, current.State))
            {
                DownloadTaskControlState.ClearReview(review.Key);
                return DownloadControlOutcome(
                    review.Action,
                    review.TaskId,
                    MutationResultStatus.ConfirmedSuccess,
                    submitted: true,
                    requiresRefresh: false,
                    task: current,
                    errorCategory: null,
                    diagnosticTag: DownloadControlDiagnostic(review.Action, "confirmed"));
            }
        }
        catch (OperationCanceledException)
        {
            submittedStatus = MutationResultStatus.CancellationRequestedAfterSubmission;
        }
        catch
        {
        }

        DownloadTaskControlState.StoreReview(review);
        return DownloadControlOutcome(
            review.Action,
            review.TaskId,
            submittedStatus,
            submitted: true,
            requiresRefresh: true,
            task: null,
            errorCategory: MutationErrorCategory.Unknown,
            diagnosticTag: DownloadControlDiagnostic(review.Action, "readback-unverified"));
    }

    private async Task<DownloadTaskCreateOutcome> FinishDownloadCreateAsync(
        DownloadTaskCreateReview review,
        MutationResultStatus submittedStatus,
        CancellationToken cancellationToken)
    {
        if (review.ExpectedTaskId is null)
        {
            DownloadTaskCreateState.StoreReview(review);
            return DownloadCreateUnknownOutcome(
                submittedStatus,
                taskId: null,
                errorCategory: MutationErrorCategory.Unknown,
                diagnosticTag: submittedStatus == MutationResultStatus.CancellationRequestedAfterSubmission
                    ? "download-station.create.cancelled-after"
                    : "download-station.create.unverified");
        }

        try
        {
            var tasks = await LoadAllPublicDownloadTasksAsync(cancellationToken).ConfigureAwait(false);
            var confirmed = tasks.SingleOrDefault(task =>
                string.Equals(task.Id, review.ExpectedTaskId, StringComparison.Ordinal) &&
                !review.PreviousTaskIds.Contains(task.Id) &&
                DownloadCreateDestinationMatches(review.Destination, task));
            if (confirmed is not null)
            {
                DownloadTaskCreateState.ClearReview(review.Key);
                return DownloadCreateOutcome(
                    MutationResultStatus.ConfirmedSuccess,
                    review.ExpectedTaskId,
                    confirmed,
                    submitted: true,
                    requiresRefresh: false,
                    errorCategory: null,
                    diagnosticTag: "download-station.create.confirmed");
            }
        }
        catch (OperationCanceledException)
        {
            submittedStatus = MutationResultStatus.CancellationRequestedAfterSubmission;
        }
        catch
        {
        }

        DownloadTaskCreateState.StoreReview(review);
        return DownloadCreateUnknownOutcome(
            submittedStatus,
            review.ExpectedTaskId,
            MutationErrorCategory.Unknown,
            diagnosticTag: submittedStatus == MutationResultStatus.CancellationRequestedAfterSubmission
                ? "download-station.create.cancelled-after"
                : "download-station.create.unverified");
    }

    private static bool TryPrepareDownloadCreateRequest(
        DownloadTaskCreateRequest request,
        out string normalizedUri,
        out string? normalizedDestination)
    {
        normalizedUri = request.Uri.Trim();
        normalizedDestination = string.IsNullOrWhiteSpace(request.Destination)
            ? null
            : request.Destination.Trim();
        if (string.IsNullOrEmpty(normalizedUri) ||
            normalizedUri.Any(char.IsControl) ||
            !Uri.TryCreate(normalizedUri, UriKind.Absolute, out var uri))
        {
            return false;
        }

        var scheme = uri.Scheme.ToLowerInvariant();
        var validUri = scheme switch
        {
            "http" or "https" or "ftp" => !string.IsNullOrWhiteSpace(uri.Host),
            "magnet" => normalizedUri.Length > "magnet:".Length,
            _ => false,
        };
        if (!validUri)
        {
            return false;
        }
        if (normalizedDestination is not null &&
            (string.IsNullOrEmpty(normalizedDestination) ||
                normalizedDestination.Any(char.IsControl)))
        {
            return false;
        }
        return true;
    }

    private static bool DownloadCreateDestinationMatches(
        string? expected,
        DownloadTask task)
    {
        if (expected is null || string.IsNullOrWhiteSpace(task.Destination))
        {
            return true;
        }
        return string.Equals(expected, task.Destination.Trim(), StringComparison.Ordinal);
    }

    private static DownloadTaskCreateOutcome DownloadCreateUnknownOutcome(
        MutationResultStatus status,
        string? taskId,
        MutationErrorCategory errorCategory,
        string diagnosticTag) =>
        DownloadCreateOutcome(
            status,
            taskId,
            task: null,
            submitted: true,
            requiresRefresh: true,
            errorCategory,
            diagnosticTag);

    private static DownloadTaskCreateOutcome DownloadCreateOutcome(
        MutationResultStatus status,
        string? taskId,
        DownloadTask? task,
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
                "downloadCreate",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                errorCategory,
                localizationKey: $"download-station.create.{status.ToString().ToLowerInvariant()}",
                diagnosticTag),
            taskId,
            task);
    }

    private static bool DownloadControlBaselineMatches(
        DownloadTask baseline,
        DownloadTask current) =>
        string.Equals(baseline.Id, current.Id, StringComparison.Ordinal) &&
        baseline.State == current.State &&
        string.Equals(baseline.RawStatus, current.RawStatus, StringComparison.Ordinal);

    private static bool DownloadControlAccepts(
        DownloadTaskControlAction action,
        DownloadTaskState state) =>
        action switch
        {
            DownloadTaskControlAction.Pause => state is DownloadTaskState.Waiting or
                DownloadTaskState.Downloading or DownloadTaskState.Checking,
            DownloadTaskControlAction.Resume => state == DownloadTaskState.Paused,
            _ => false,
        };

    private static bool DownloadControlConfirmed(
        DownloadTaskControlAction action,
        DownloadTaskState state) =>
        action switch
        {
            DownloadTaskControlAction.Pause => state == DownloadTaskState.Paused,
            DownloadTaskControlAction.Resume => state is DownloadTaskState.Waiting or
                DownloadTaskState.Downloading or DownloadTaskState.Checking or
                DownloadTaskState.Seeding,
            _ => false,
        };

    private static string DownloadControlMethod(DownloadTaskControlAction action) =>
        action switch
        {
            DownloadTaskControlAction.Pause => "pause",
            DownloadTaskControlAction.Resume => "resume",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

    private static string DownloadControlOperation(DownloadTaskControlAction action) =>
        action switch
        {
            DownloadTaskControlAction.Pause => "downloadPause",
            DownloadTaskControlAction.Resume => "downloadResume",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

    private static string DownloadControlDiagnostic(
        DownloadTaskControlAction action,
        string suffix) =>
        $"download-station.{DownloadControlMethod(action)}.{suffix}";

    private static MutationErrorCategory DownloadControlErrorCategory(DsmException error)
    {
        if (error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401)
        {
            return MutationErrorCategory.Authentication;
        }
        return error.Code switch
        {
            105 => MutationErrorCategory.Permission,
            102 or 103 => MutationErrorCategory.Unsupported,
            _ => MutationErrorCategory.Server,
        };
    }

    private static DownloadTaskControlOutcome DownloadControlOutcome(
        DownloadTaskControlAction action,
        string taskId,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        DownloadTask? task,
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
                DownloadControlOperation(action),
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                errorCategory,
                localizationKey: $"download-station.{DownloadControlMethod(action)}.{status.ToString().ToLowerInvariant()}",
                diagnosticTag),
            taskId,
            task);
    }

    private static string? StableDownloadId(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<string>(out var text))
        {
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        if (value.TryGetValue<int>(out var nativeInteger))
        {
            return nativeInteger.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<long>(out var integer))
        {
            return integer.ToString(CultureInfo.InvariantCulture);
        }
        return null;
    }

    private static int RequiredNonNegativeInt(JsonObject data, string key)
    {
        var value = data.Int(key);
        return value is >= 0 ? value.Value : throw InvalidDownloadStationResponse();
    }

    private static long RequiredNonNegativeLong(JsonObject data, string key)
    {
        var value = data.Long(key);
        return value is >= 0 ? value.Value : throw InvalidDownloadStationResponse();
    }

    private static long? OptionalNonNegativeLong(JsonObject? data, string key)
    {
        if (data is null || !data.ContainsKey(key))
        {
            return null;
        }
        var value = data.Long(key);
        return value is >= 0 ? value : throw InvalidDownloadStationResponse();
    }

    private static DsmException MissingPublicDownloadStationContract() =>
        new(
            UserText.Key("WinShared11a208e43c34b77c"),
            UserText.Key("WinShared371d84f48836296f"),
            102);

    private static DsmException InvalidDownloadStationResponse() =>
        new(
            UserText.Key("WinShared17bab1054ab28010"),
            UserText.Key("WinSharedefc81ced18eb3bb0"));

    private readonly record struct DownloadTaskCreateActiveKey(Guid ProfileId, string Digest);

    private readonly record struct DownloadTaskCreateReviewKey(
        Guid ProfileId,
        Guid SessionProfileId,
        string SessionId,
        string Digest)
    {
        public static DownloadTaskCreateReviewKey From(
            Guid profileId,
            DsmSession session,
            string uri,
            string? destination) =>
            new(
                profileId,
                session.ProfileId,
                session.Sid,
                DownloadCreateDigest("uri", uri, destination ?? string.Empty));

        public static DownloadTaskCreateReviewKey FromFile(
            Guid profileId,
            DsmSession session,
            string fileName,
            long length,
            string? destination) =>
            new(
                profileId,
                session.ProfileId,
                session.Sid,
                DownloadCreateDigest(
                    "file",
                    fileName,
                    length.ToString(CultureInfo.InvariantCulture),
                    destination ?? string.Empty));
    }

    private sealed record DownloadTaskCreateReview(
        DownloadTaskCreateReviewKey Key,
        IReadOnlySet<string> PreviousTaskIds,
        string? ExpectedTaskId,
        string? Destination);

    private sealed class DownloadTaskCreateApiState
    {
        private readonly object _gate = new();
        private readonly HashSet<DownloadTaskCreateActiveKey> _active = [];
        private readonly Dictionary<DownloadTaskCreateReviewKey, DownloadTaskCreateReview> _reviews = [];

        public bool TryClaim(DownloadTaskCreateActiveKey key)
        {
            lock (_gate)
            {
                return _active.Add(key);
            }
        }

        public void Release(DownloadTaskCreateActiveKey key)
        {
            lock (_gate)
            {
                _active.Remove(key);
            }
        }

        public bool TryGetReview(
            DownloadTaskCreateReviewKey key,
            out DownloadTaskCreateReview review)
        {
            lock (_gate)
            {
                return _reviews.TryGetValue(key, out review!);
            }
        }

        public void StoreReview(DownloadTaskCreateReview review)
        {
            lock (_gate)
            {
                _reviews[review.Key] = review;
            }
        }

        public void ClearReview(DownloadTaskCreateReviewKey key)
        {
            lock (_gate)
            {
                _reviews.Remove(key);
            }
        }
    }

    private static string DownloadCreateDigest(string kind, params string[] values)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
        writer.Write(kind);
        foreach (var value in values)
        {
            writer.Write(value.Length);
            writer.Write(value);
        }
        writer.Flush();
        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    private readonly record struct DownloadTaskControlActiveKey(Guid ProfileId, string TaskId);

    private readonly record struct DownloadTaskControlReviewKey(
        Guid ProfileId,
        Guid SessionProfileId,
        string SessionId,
        string TaskId,
        DownloadTaskControlAction Action)
    {
        public static DownloadTaskControlReviewKey From(
            Guid profileId,
            DsmSession session,
            string taskId,
            DownloadTaskControlAction action) =>
            new(profileId, session.ProfileId, session.Sid, taskId, action);
    }

    private sealed record DownloadTaskControlReview(
        DownloadTaskControlReviewKey Key,
        string TaskId,
        DownloadTaskControlAction Action);

    private sealed class DownloadTaskControlApiState
    {
        private readonly object _gate = new();
        private readonly HashSet<DownloadTaskControlActiveKey> _active = [];
        private readonly Dictionary<DownloadTaskControlReviewKey, DownloadTaskControlReview> _reviews = [];

        public bool TryClaim(DownloadTaskControlActiveKey key)
        {
            lock (_gate)
            {
                return _active.Add(key);
            }
        }

        public void Release(DownloadTaskControlActiveKey key)
        {
            lock (_gate)
            {
                _active.Remove(key);
            }
        }

        public bool TryGetReview(
            DownloadTaskControlReviewKey key,
            out DownloadTaskControlReview review)
        {
            lock (_gate)
            {
                return _reviews.TryGetValue(key, out review!);
            }
        }

        public void StoreReview(DownloadTaskControlReview review)
        {
            lock (_gate)
            {
                _reviews[review.Key] = review;
            }
        }

        public void ClearReview(DownloadTaskControlReviewKey key)
        {
            lock (_gate)
            {
                _reviews.Remove(key);
            }
        }
    }
}
