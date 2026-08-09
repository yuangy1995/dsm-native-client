using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileRecyclePollLimit = 8;
    private static readonly ConditionalWeakTable<IDsmApiClient, FileRecycleApiState>
        FileRecycleApiStates = new();

    public FileRecycleAvailability FileRecycleAvailability => new(
        CanMoveToRecycle: RecycleMoveCapabilityAvailable,
        CanRestore: CopyMoveCapabilityAvailable,
        DeleteVersion: RecycleMoveCapabilityAvailable ? 2 : null,
        CopyMoveVersion: CopyMoveCapabilityAvailable ? 3 : null);

    FileRecycleAvailability IFileRecycleRepository.Availability => FileRecycleAvailability;

    private bool RecycleMoveCapabilityAvailable =>
        MutationCapability("SYNO.FileStation.Delete", 2) && MutationListAvailable;

    public async Task<FileRecycleOutcome> MoveToRecycleAsync(
        MoveToRecycleRequest request,
        CancellationToken cancellationToken = default)
    {
        const string operation = "moveToRecycle";
        if (!ValidMoveToRecycleRequest(request) || !RecycleMoveCapabilityAvailable)
            return RecycleOutcome(operation, MutationResultStatus.Unsupported, false, false,
                request.Target.Path, FallbackRecycleDestination(request),
                MutationErrorCategory.Unsupported, "file.recycle.move.unsupported");
        if (cancellationToken.IsCancellationRequested)
            return RecycleOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, request.Target.Path, RecycleDestinationPath(request),
                null, "file.recycle.move.cancelled-before-submit");

        var source = request.Target;
        var destinationPath = RecycleDestinationPath(request);
        var review = new FileRecycleReview(operation, source.Path, destinationPath, source.Name,
            source.Size, source.ModifiedAt,
            new HashSet<string>([source.Path, destinationPath], StringComparer.Ordinal));
        var reservation = ReserveFileRecycle(review);
        if (!reservation.Acquired)
            return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                false, false, source.Path, destinationPath, MutationErrorCategory.Conflict,
                "file.recycle.move.target-busy");

        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewFileRecycleAsync(reservation.PendingReview)
                    .ConfigureAwait(false);

            var baseline = await LoadMutationItemsByPathAsync(
                [source.Path, destinationPath], cancellationToken).ConfigureAwait(false);
            var observedSource = baseline.SingleOrDefault(item => item.Path == source.Path);
            if (!MatchesFrozenRecycleSource(observedSource, source) ||
                baseline.Any(item => item.Path == destinationPath))
                return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                    false, false, source.Path, destinationPath, MutationErrorCategory.Conflict,
                    "file.recycle.move.preflight-rejected");

            return await SubmitMoveToRecycleAsync(review, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return RecycleOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, source.Path, destinationPath, null,
                "file.recycle.move.cancelled-before-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsRecycleReadFailure(error))
        {
            return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                false, false, source.Path, destinationPath, MutationErrorCategory.Unknown,
                "file.recycle.move.preflight-invalid");
        }
        finally
        {
            ReleaseFileRecycle(review.Targets);
        }
    }

    public async Task<FileRecycleOutcome> RestoreFromRecycleAsync(
        RestoreFromRecycleRequest request,
        CancellationToken cancellationToken = default)
    {
        const string operation = "restoreFromRecycle";
        var destinationPath = TryRecycleOriginalPath(request.Target.Path) ?? request.Target.Path;
        if (!ValidRestoreFromRecycleRequest(request, out var destinationParent) ||
            !CopyMoveCapabilityAvailable)
            return RecycleOutcome(operation, MutationResultStatus.Unsupported, false, false,
                request.Target.Path, destinationPath, MutationErrorCategory.Unsupported,
                "file.recycle.restore.unsupported");
        if (cancellationToken.IsCancellationRequested)
            return RecycleOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, request.Target.Path, destinationPath, null,
                "file.recycle.restore.cancelled-before-submit");

        var source = request.Target;
        var review = new FileRecycleReview(operation, source.Path, destinationPath, source.Name,
            source.Size, source.ModifiedAt,
            new HashSet<string>([source.Path, destinationPath], StringComparer.Ordinal));
        var reservation = ReserveFileRecycle(review);
        if (!reservation.Acquired)
            return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                false, false, source.Path, destinationPath, MutationErrorCategory.Conflict,
                "file.recycle.restore.target-busy");

        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewFileRecycleAsync(reservation.PendingReview)
                    .ConfigureAwait(false);

            var baseline = await LoadMutationItemsByPathAsync(
                [source.Path, destinationParent, destinationPath], cancellationToken)
                .ConfigureAwait(false);
            var observedSource = baseline.SingleOrDefault(item => item.Path == source.Path);
            var observedParent = baseline.SingleOrDefault(item => item.Path == destinationParent);
            if (!MatchesFrozenRecycleSource(observedSource, source) ||
                observedParent is null || !observedParent.IsDirectory ||
                baseline.Any(item => item.Path == destinationPath))
                return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                    false, false, source.Path, destinationPath, MutationErrorCategory.Conflict,
                    "file.recycle.restore.preflight-rejected");

            var permission = await _api.CheckFileMutationPermissionAsync(
                _profile, _session, _capabilities["SYNO.FileStation.CheckPermission"],
                destinationParent, source.Name, cancellationToken).ConfigureAwait(false);
            if (permission.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return RecyclePermissionOutcome(operation, source.Path, destinationPath, permission);

            return await SubmitRestoreFromRecycleAsync(
                review, destinationParent, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return RecycleOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, source.Path, destinationPath, null,
                "file.recycle.restore.cancelled-before-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsRecycleReadFailure(error))
        {
            return RecycleOutcome(operation, MutationResultStatus.ConfirmedFailure,
                false, false, source.Path, destinationPath, MutationErrorCategory.Unknown,
                "file.recycle.restore.preflight-invalid");
        }
        finally
        {
            ReleaseFileRecycle(review.Targets);
        }
    }

    private async Task<FileRecycleOutcome> SubmitMoveToRecycleAsync(
        FileRecycleReview review,
        CancellationToken cancellationToken)
    {
        FileRecycleStartTransportResult start;
        try
        {
            start = await _api.StartMoveToRecycleAsync(_profile, _session,
                _capabilities["SYNO.FileStation.Delete"], review.SourcePath, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            StoreFileRecycleReview(review);
            return RecycleOutcome(review.Operation,
                MutationResultStatus.CancellationRequestedAfterSubmission,
                true, true, review.SourcePath, review.DestinationPath,
                MutationErrorCategory.Network, "file.recycle.move.cancelled-after-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileRecycleReview(review);
            throw;
        }
        catch (Exception)
        {
            StoreFileRecycleReview(review);
            return RecycleOutcome(review.Operation,
                MutationResultStatus.SubmittedButUnverified, true, true,
                review.SourcePath, review.DestinationPath, MutationErrorCategory.Unknown,
                "file.recycle.move.transport-unverified");
        }

        if (start.ErrorCategory == MutationErrorCategory.Authentication)
        {
            StoreFileRecycleReview(review);
            throw MutationAuthenticationException();
        }
        if (start.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return RecycleOutcome(review.Operation,
                MutationResultStatus.CancelledBeforeSubmission, false, false,
                review.SourcePath, review.DestinationPath, start.ErrorCategory,
                start.DiagnosticTag);
        if (start.Status == FileMutationTransportStatus.Unsupported)
            return RecycleOutcome(review.Operation, MutationResultStatus.Unsupported,
                false, false, review.SourcePath, review.DestinationPath,
                start.ErrorCategory, start.DiagnosticTag);

        var requestedCancellationAfterSubmission =
            start.Status == FileMutationTransportStatus.CancellationRequestedAfterSubmission;
        var confirmedFailure = start.Status == FileMutationTransportStatus.ConfirmedFailure;
        var taskFinished = false;
        var postSubmitFailure = start.Status != FileMutationTransportStatus.ResponseReceived;

        if (start.Status == FileMutationTransportStatus.ResponseReceived && start.TaskId is not null)
        {
            try
            {
                taskFinished = await PollFileRecycleAsync(start.TaskId).ConfigureAwait(false);
                postSubmitFailure = !taskFinished;
            }
            catch (DsmException error) when (IsMutationAuthenticationFailure(error))
            {
                StoreFileRecycleReview(review);
                throw;
            }
            catch (Exception)
            {
                postSubmitFailure = true;
            }
        }

        return await FinishFileRecycleSubmissionAsync(
            review, requestedCancellationAfterSubmission, confirmedFailure,
            postSubmitFailure || !taskFinished, start.ErrorCategory, start.DiagnosticTag)
            .ConfigureAwait(false);
    }

    private async Task<FileRecycleOutcome> SubmitRestoreFromRecycleAsync(
        FileRecycleReview review,
        string destinationParent,
        CancellationToken cancellationToken)
    {
        FileCopyMoveStartTransportResult start;
        try
        {
            start = await _api.StartFileCopyMoveAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CopyMove"], review.SourcePath,
                destinationParent, removeSource: true, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            StoreFileRecycleReview(review);
            return RecycleOutcome(review.Operation,
                MutationResultStatus.CancellationRequestedAfterSubmission,
                true, true, review.SourcePath, review.DestinationPath,
                MutationErrorCategory.Network, "file.recycle.restore.cancelled-after-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileRecycleReview(review);
            throw;
        }
        catch (Exception)
        {
            StoreFileRecycleReview(review);
            return RecycleOutcome(review.Operation,
                MutationResultStatus.SubmittedButUnverified, true, true,
                review.SourcePath, review.DestinationPath, MutationErrorCategory.Unknown,
                "file.recycle.restore.transport-unverified");
        }

        if (start.ErrorCategory == MutationErrorCategory.Authentication)
        {
            StoreFileRecycleReview(review);
            throw MutationAuthenticationException();
        }
        if (start.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return RecycleOutcome(review.Operation,
                MutationResultStatus.CancelledBeforeSubmission, false, false,
                review.SourcePath, review.DestinationPath, start.ErrorCategory,
                start.DiagnosticTag);
        if (start.Status == FileMutationTransportStatus.Unsupported)
            return RecycleOutcome(review.Operation, MutationResultStatus.Unsupported,
                false, false, review.SourcePath, review.DestinationPath,
                start.ErrorCategory, start.DiagnosticTag);

        var requestedCancellationAfterSubmission =
            start.Status == FileMutationTransportStatus.CancellationRequestedAfterSubmission;
        var confirmedFailure = start.Status == FileMutationTransportStatus.ConfirmedFailure;
        var taskFinished = false;
        var postSubmitFailure = start.Status != FileMutationTransportStatus.ResponseReceived;

        if (start.Status == FileMutationTransportStatus.ResponseReceived && start.TaskId is not null)
        {
            try
            {
                taskFinished = await PollFileCopyMoveAsync(start.TaskId).ConfigureAwait(false);
                postSubmitFailure = !taskFinished;
            }
            catch (DsmException error) when (IsMutationAuthenticationFailure(error))
            {
                StoreFileRecycleReview(review);
                throw;
            }
            catch (Exception)
            {
                postSubmitFailure = true;
            }
        }

        return await FinishFileRecycleSubmissionAsync(
            review, requestedCancellationAfterSubmission, confirmedFailure,
            postSubmitFailure || !taskFinished, start.ErrorCategory, start.DiagnosticTag)
            .ConfigureAwait(false);
    }

    private async Task<FileRecycleOutcome> FinishFileRecycleSubmissionAsync(
        FileRecycleReview review,
        bool requestedCancellationAfterSubmission,
        bool confirmedFailure,
        bool postSubmitFailure,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag)
    {
        FileItem? confirmed;
        try
        {
            confirmed = await TryReadBackFileRecycleAsync(review).ConfigureAwait(false);
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileRecycleReview(review);
            throw;
        }
        if (confirmed is not null)
        {
            RemoveFileRecycleReview(review);
            return RecycleOutcome(review.Operation, MutationResultStatus.ConfirmedSuccess,
                true, false, review.SourcePath, review.DestinationPath, null, null, confirmed);
        }
        if (confirmedFailure)
            return RecycleOutcome(review.Operation,
                errorCategory == MutationErrorCategory.Permission
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                true, false, review.SourcePath, review.DestinationPath,
                errorCategory, diagnosticTag);

        StoreFileRecycleReview(review);
        return RecycleOutcome(review.Operation,
            requestedCancellationAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            true, true, review.SourcePath, review.DestinationPath,
            errorCategory ?? (postSubmitFailure ? MutationErrorCategory.Unknown : null),
            diagnosticTag ?? "file.recycle.readback-unverified");
    }

    private async Task<bool> PollFileRecycleAsync(string taskId)
    {
        for (var attempt = 0; attempt < FileRecyclePollLimit; attempt++)
        {
            var status = await _api.ReadFileRecycleStatusAsync(_profile, _session,
                _capabilities["SYNO.FileStation.Delete"], taskId, CancellationToken.None)
                .ConfigureAwait(false);
            if (status.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (status.Status == FileRecycleTaskTransportStatus.Finished) return true;
            if (status.Status != FileRecycleTaskTransportStatus.Running) return false;
            await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(1000, 100 * (1 << attempt))))
                .ConfigureAwait(false);
        }
        return false;
    }

    private async Task<FileItem?> TryReadBackFileRecycleAsync(FileRecycleReview review)
    {
        try
        {
            var items = await LoadMutationItemsByPathAsync(
                [review.SourcePath, review.DestinationPath], CancellationToken.None)
                .ConfigureAwait(false);
            var target = items.SingleOrDefault(item =>
                item.Path == review.DestinationPath && !item.IsDirectory &&
                item.Size == review.Size && item.Name == review.Name);
            if (target is null) return null;
            var sourceStillMatches = items.Any(item =>
                item.Path == review.SourcePath && !item.IsDirectory && item.Size == review.Size);
            return sourceStillMatches ? null : target;
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsRecycleReadFailure(error))
        {
            return null;
        }
    }

    private async Task<FileRecycleOutcome> ReviewFileRecycleAsync(FileRecycleReview review)
    {
        var confirmed = await TryReadBackFileRecycleAsync(review).ConfigureAwait(false);
        if (confirmed is not null)
        {
            RemoveFileRecycleReview(review);
            return RecycleOutcome(review.Operation, MutationResultStatus.ConfirmedSuccess,
                true, false, review.SourcePath, review.DestinationPath, null, null, confirmed);
        }
        return RecycleOutcome(review.Operation, MutationResultStatus.SubmittedButUnverified,
            true, true, review.SourcePath, review.DestinationPath, MutationErrorCategory.Unknown,
            "file.recycle.review-pending");
    }

    private async Task<IReadOnlyList<FileItem>> LoadMutationItemsByPathAsync(
        IReadOnlyList<string> paths,
        CancellationToken cancellationToken)
    {
        if (paths.Count == 0 || paths.Any(path => !ValidMutationObjectPath(path)))
            throw new InvalidDataException("file.recycle.invalid-paths");
        var capability = _capabilities["SYNO.FileStation.List"];
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2,
            "getinfo", new Dictionary<string, string>
            {
                ["path"] = JsonSerializer.Serialize(paths),
                ["additional"] = "[\"size\",\"time\",\"perm\"]",
            }, cancellationToken).ConfigureAwait(false);
        if (data["files"] is not JsonArray files)
            throw new InvalidDataException("file.recycle.invalid-getinfo");
        var requested = paths.ToHashSet(StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var items = new List<FileItem>();
        foreach (var node in files)
        {
            if (node is not JsonObject item || NativeString(item, "path") is not { } itemPath ||
                NativeString(item, "name") is not { } name || !NativeBool(item, "isdir", out var isDir) ||
                !requested.Contains(itemPath) || !ValidMutationObjectPath(itemPath) ||
                !ValidMutationItemName(name) || !itemPath.EndsWith($"/{name}", StringComparison.Ordinal) ||
                (item["additional"] is not null && item["additional"] is not JsonObject) ||
                !seen.Add(itemPath))
                throw new InvalidDataException("file.recycle.invalid-item");
            var additional = item["additional"] as JsonObject;
            long size;
            if (isDir) size = 0;
            else if (!NativeLong(item, "size", out size) &&
                (additional is null || !NativeLong(additional, "size", out size)))
                throw new InvalidDataException("file.recycle.invalid-size");
            if (size < 0) throw new InvalidDataException("file.recycle.invalid-size");
            var modified = OptionalMutationTime(item, additional);
            var canWrite = false;
            var canDelete = false;
            if (additional?["perm"] is not null)
            {
                if (additional["perm"] is not JsonObject permission)
                    throw new InvalidDataException("file.recycle.invalid-permission");
                if (!NativeBool(permission, "write", out canWrite))
                    canWrite = false;
                if (!NativeBool(permission, "delete", out canDelete))
                    canDelete = false;
            }
            items.Add(new FileItem(itemPath, name, isDir, size, modified, null, canWrite, canDelete));
        }
        return items;
    }

    private bool ValidMoveToRecycleRequest(MoveToRecycleRequest request)
    {
        var target = request.Target;
        return ValidRecycleFileTarget(target, expectedRecycle: false) &&
            target.CanRead && target.CanDelete &&
            ValidMutationDirectory(request.RecycleLocation.SharePath) &&
            ValidMutationDirectory(request.RecycleLocation.RecyclePath) &&
            request.RecycleLocation.RecyclePath.Equals(
                JoinMutationPath(request.RecycleLocation.SharePath, "#recycle"),
                StringComparison.Ordinal) &&
            target.Path.StartsWith(request.RecycleLocation.SharePath + "/",
                StringComparison.Ordinal);
    }

    private bool ValidRestoreFromRecycleRequest(
        RestoreFromRecycleRequest request,
        out string destinationParent)
    {
        destinationParent = string.Empty;
        var target = request.Target;
        if (!ValidRecycleFileTarget(target, expectedRecycle: true) ||
            TryRecycleOriginalPath(target.Path) is not { } destinationPath ||
            !ValidMutationObjectPath(destinationPath) ||
            ContainsRecycleSegment(destinationPath))
            return false;
        destinationParent = MutationParent(destinationPath);
        return ValidMutationDirectory(destinationParent);
    }

    private bool ValidRecycleFileTarget(FileRecycleTarget target, bool expectedRecycle) =>
        target.ProfileId == ProfileId && !target.IsDirectory && target.Size >= 0 &&
        ValidMutationObjectPath(target.Path) && ValidMutationItemName(target.Name) &&
        MutationParent(target.Path).Length > 0 &&
        target.Path.EndsWith("/" + target.Name, StringComparison.Ordinal) &&
        !target.IsRemote && !target.IsVirtual &&
        target.IsRecycle == expectedRecycle &&
        ContainsRecycleSegment(target.Path) == expectedRecycle;

    private static bool MatchesFrozenRecycleSource(FileItem? observed, FileRecycleTarget frozen) =>
        observed is not null && !observed.IsDirectory && observed.Path == frozen.Path &&
        observed.Name == frozen.Name && observed.Size == frozen.Size &&
        observed.ModifiedAt == frozen.ModifiedAt;

    private static string RecycleDestinationPath(MoveToRecycleRequest request) =>
        request.RecycleLocation.RecyclePath +
        request.Target.Path[request.RecycleLocation.SharePath.Length..];

    private static string FallbackRecycleDestination(MoveToRecycleRequest request) =>
        $"{request.RecycleLocation.RecyclePath}/{request.Target.Name}";

    private static string? TryRecycleOriginalPath(string recyclePath)
    {
        if (!ValidMutationObjectPath(recyclePath)) return null;
        var parts = recyclePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3 || !parts[1].Equals("#recycle", StringComparison.Ordinal))
            return null;
        return "/" + parts[0] + "/" + string.Join('/', parts.Skip(2));
    }

    private FileRecycleReservation ReserveFileRecycle(FileRecycleReview requested)
    {
        var state = FileRecycleState();
        lock (state.Sync)
        {
            if (state.Reviews.TryGetValue(requested.Key, out var pending))
            {
                if (state.ActiveTargets.Overlaps(requested.Targets)) return default;
                state.ActiveTargets.UnionWith(requested.Targets);
                return new(true, pending);
            }
            if (state.Reviews.Values.Any(review => review.Targets.Overlaps(requested.Targets)) ||
                state.ActiveTargets.Overlaps(requested.Targets)) return default;
            state.ActiveTargets.UnionWith(requested.Targets);
            return new(true, null);
        }
    }

    private void ReleaseFileRecycle(HashSet<string> targets)
    {
        var state = FileRecycleState();
        lock (state.Sync) state.ActiveTargets.ExceptWith(targets);
    }

    private void StoreFileRecycleReview(FileRecycleReview review)
    {
        var state = FileRecycleState();
        lock (state.Sync) state.Reviews[review.Key] = review;
    }

    private void RemoveFileRecycleReview(FileRecycleReview review)
    {
        var state = FileRecycleState();
        lock (state.Sync) state.Reviews.Remove(review.Key);
    }

    private FileRecycleSessionState FileRecycleState()
    {
        var apiState = FileRecycleApiStates.GetValue(_api, _ => new());
        lock (apiState.Sync)
        {
            if (!apiState.Sessions.TryGetValue(_session, out var state))
            {
                state = new();
                apiState.Sessions.Add(_session, state);
            }
            return state;
        }
    }

    private static bool IsRecycleReadFailure(Exception error) =>
        error is DsmException or JsonException or InvalidDataException or OverflowException or
            InvalidOperationException or ArgumentException;

    private static FileRecycleOutcome RecyclePermissionOutcome(string operation,
        string sourcePath, string destinationPath, FilePermissionTransportResult result) =>
        RecycleOutcome(operation,
            result.Status switch
            {
                FilePermissionTransportStatus.Denied => MutationResultStatus.PermissionDenied,
                FilePermissionTransportStatus.Cancelled =>
                    MutationResultStatus.CancelledBeforeSubmission,
                FilePermissionTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                _ => MutationResultStatus.ConfirmedFailure,
            }, false, false, sourcePath, destinationPath,
            result.ErrorCategory, result.DiagnosticTag);

    private static FileRecycleOutcome RecycleOutcome(string operation,
        MutationResultStatus status, bool submitted, bool refresh,
        string sourcePath, string destinationPath,
        MutationErrorCategory? category, string? tag, FileItem? item = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = success == 0 && unknown == 0 &&
            status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new(new MutationResult(1, status, operation, submitted, refresh,
            new MutationResultCounts(success, failed, unknown), category,
            diagnosticTag: tag), sourcePath, destinationPath, item);
    }

    private sealed record FileRecycleReview(
        string Operation,
        string SourcePath,
        string DestinationPath,
        string Name,
        long Size,
        DateTimeOffset? ModifiedAt,
        HashSet<string> Targets)
    {
        public string Key { get; } = $"{Operation}|{SourcePath}|{DestinationPath}";
    }

    private readonly record struct FileRecycleReservation(
        bool Acquired,
        FileRecycleReview? PendingReview);

    private sealed class FileRecycleSessionState
    {
        public object Sync { get; } = new();
        public HashSet<string> ActiveTargets { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, FileRecycleReview> Reviews { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed class FileRecycleApiState
    {
        public object Sync { get; } = new();
        public Dictionary<DsmSession, FileRecycleSessionState> Sessions { get; } = [];
    }
}
