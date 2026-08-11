using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileCopyMovePollLimit = 8;
    private static readonly ConditionalWeakTable<IDsmApiClient, FileCopyMoveApiState>
        FileCopyMoveApiStates = new();

    public FileCopyMoveAvailability FileCopyMoveAvailability => new(
        CanCopy: CopyMoveCapabilityAvailable,
        CanMove: CopyMoveCapabilityAvailable,
        ResolvedVersion: CopyMoveCapabilityAvailable ? 3 : null);

    FileCopyMoveAvailability IFileCopyMoveRepository.Availability => FileCopyMoveAvailability;

    private bool CopyMoveCapabilityAvailable =>
        MutationCapability("SYNO.FileStation.CopyMove", 3) &&
        MutationCapability("SYNO.FileStation.CheckPermission", 3) &&
        MutationListAvailable;

    public async Task<FileCopyMoveOutcome> CopyMoveAsync(
        FileCopyMoveRequest request,
        CancellationToken cancellationToken = default)
    {
        var operation = request.Operation == FileCopyMoveOperation.Copy ? "copyFile" : "moveFile";
        if (!ValidCopyMoveRequest(request) || !CopyMoveCapabilityAvailable)
            return CopyMoveOutcome(operation, MutationResultStatus.Unsupported, false, false,
                MutationErrorCategory.Unsupported, "file.copy-move.unsupported");
        if (cancellationToken.IsCancellationRequested)
            return CopyMoveOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, null, "file.copy-move.cancelled-before-submit");

        var source = request.Target;
        var sourceParent = MutationParent(source.Path);
        var destinationPath = JoinMutationPath(request.DestinationDirectoryPath, source.Name);
        if (destinationPath == source.Path ||
            request.DestinationDirectoryPath.StartsWith(source.Path + "/", StringComparison.Ordinal))
            return CopyMoveOutcome(operation, MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Conflict, "file.copy-move.same-target");

        var review = new FileCopyMoveReview(operation, source.Path, sourceParent,
            request.DestinationDirectoryPath, destinationPath, source.Name, source.Size,
            source.ModifiedAt, source.IsDirectory, request.Operation,
            new HashSet<string>([source.Path, destinationPath], StringComparer.Ordinal));
        var reservation = ReserveFileCopyMove(review);
        if (!reservation.Acquired)
            return CopyMoveOutcome(operation, MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Conflict, "file.copy-move.target-busy");

        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewFileCopyMoveAsync(reservation.PendingReview).ConfigureAwait(false);

            if (!await CopyMoveMountsAreLocalAsync(source.Path,
                    request.DestinationDirectoryPath, cancellationToken).ConfigureAwait(false))
                return CopyMoveOutcome(operation, MutationResultStatus.Unsupported, false, false,
                    MutationErrorCategory.Unsupported, "file.copy-move.remote-mount");

            var sourceItems = await LoadMutationFolderAsync(sourceParent, cancellationToken)
                .ConfigureAwait(false);
            var observedSource = sourceItems.SingleOrDefault(item => item.Path == source.Path);
            if (!MatchesFrozenSource(observedSource, source))
                return CopyMoveOutcome(operation, MutationResultStatus.ConfirmedFailure,
                    false, false, MutationErrorCategory.Validation,
                    "file.copy-move.source-changed");
            if (request.Operation == FileCopyMoveOperation.Move && !observedSource!.CanDelete)
                return CopyMoveOutcome(operation, MutationResultStatus.PermissionDenied,
                    false, false, MutationErrorCategory.Permission,
                    "file.copy-move.source-permission");

            var destinationItems = sourceParent == request.DestinationDirectoryPath
                ? sourceItems
                : await LoadMutationFolderAsync(request.DestinationDirectoryPath, cancellationToken)
                    .ConfigureAwait(false);
            if (destinationItems.Any(item => item.Path == destinationPath))
                return CopyMoveOutcome(operation, MutationResultStatus.ConfirmedFailure,
                    false, false, MutationErrorCategory.Conflict, "file.copy-move.conflict");

            var permission = await _api.CheckFileMutationPermissionAsync(
                _profile, _session, _capabilities["SYNO.FileStation.CheckPermission"],
                request.DestinationDirectoryPath, source.Name, cancellationToken)
                .ConfigureAwait(false);
            if (permission.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return CopyMovePermissionOutcome(operation, permission);

            return await SubmitFileCopyMoveAsync(request, review, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CopyMoveOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, null, "file.copy-move.cancelled-before-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsCopyMoveReadFailure(error))
        {
            return CopyMoveOutcome(operation, MutationResultStatus.ConfirmedFailure,
                false, false, MutationErrorCategory.Unknown,
                "file.copy-move.preflight-invalid");
        }
        finally
        {
            ReleaseFileCopyMove(review.Targets);
        }
    }

    private async Task<FileCopyMoveOutcome> SubmitFileCopyMoveAsync(
        FileCopyMoveRequest request,
        FileCopyMoveReview review,
        CancellationToken cancellationToken)
    {
        FileCopyMoveStartTransportResult start;
        try
        {
            // 进入专用 start transport 即越过不可安全重放的提交边界。
            start = await _api.StartFileCopyMoveAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CopyMove"], request.Target.Path,
                request.DestinationDirectoryPath,
                request.Operation == FileCopyMoveOperation.Move, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            StoreFileCopyMoveReview(review);
            return CopyMoveOutcome(review.Operation,
                MutationResultStatus.CancellationRequestedAfterSubmission,
                true, true, MutationErrorCategory.Network,
                "file.copy-move.cancelled-after-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileCopyMoveReview(review);
            throw;
        }
        catch (Exception)
        {
            StoreFileCopyMoveReview(review);
            return CopyMoveOutcome(review.Operation,
                MutationResultStatus.SubmittedButUnverified,
                true, true, MutationErrorCategory.Unknown,
                "file.copy-move.transport-unverified");
        }

        if (start.ErrorCategory == MutationErrorCategory.Authentication)
        {
            StoreFileCopyMoveReview(review);
            throw MutationAuthenticationException();
        }
        if (start.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return CopyMoveOutcome(review.Operation,
                MutationResultStatus.CancelledBeforeSubmission, false, false,
                start.ErrorCategory, start.DiagnosticTag);
        if (start.Status == FileMutationTransportStatus.Unsupported)
            return CopyMoveOutcome(review.Operation, MutationResultStatus.Unsupported,
                false, false, start.ErrorCategory, start.DiagnosticTag);

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
                StoreFileCopyMoveReview(review);
                throw;
            }
            catch (Exception)
            {
                postSubmitFailure = true;
            }
        }

        FileItem? confirmed;
        try
        {
            confirmed = await TryReadBackFileCopyMoveAsync(review).ConfigureAwait(false);
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileCopyMoveReview(review);
            throw;
        }
        if (confirmed is not null)
        {
            RemoveFileCopyMoveReview(review);
            return CopyMoveOutcome(review.Operation, MutationResultStatus.ConfirmedSuccess,
                true, false, null, null, confirmed);
        }
        if (confirmedFailure)
            return CopyMoveOutcome(review.Operation,
                start.ErrorCategory == MutationErrorCategory.Permission
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                true, false, start.ErrorCategory, start.DiagnosticTag);

        StoreFileCopyMoveReview(review);
        return CopyMoveOutcome(review.Operation,
            requestedCancellationAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            true, true,
            start.ErrorCategory ?? (postSubmitFailure || !taskFinished
                ? MutationErrorCategory.Unknown : null),
            start.DiagnosticTag ?? "file.copy-move.readback-unverified");
    }

    private async Task<bool> PollFileCopyMoveAsync(string taskId)
    {
        for (var attempt = 0; attempt < FileCopyMovePollLimit; attempt++)
        {
            var status = await _api.ReadFileCopyMoveStatusAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CopyMove"], taskId, CancellationToken.None)
                .ConfigureAwait(false);
            if (status.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (status.Status == FileCopyMoveTaskTransportStatus.Finished) return true;
            if (status.Status != FileCopyMoveTaskTransportStatus.Running) return false;
            await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(1000, 100 * (1 << attempt))))
                .ConfigureAwait(false);
        }
        return false;
    }

    private async Task<FileItem?> TryReadBackFileCopyMoveAsync(FileCopyMoveReview review)
    {
        try
        {
            var sourceItems = await LoadMutationFolderAsync(review.SourceParent,
                CancellationToken.None).ConfigureAwait(false);
            var destinationItems = review.SourceParent == review.DestinationParent
                ? sourceItems
                : await LoadMutationFolderAsync(review.DestinationParent, CancellationToken.None)
                    .ConfigureAwait(false);
            var target = destinationItems.SingleOrDefault(item =>
                item.Path == review.DestinationPath &&
                item.IsDirectory == review.IsDirectory &&
                (review.IsDirectory || item.Size == review.Size) && item.Name == review.Name);
            if (target is null) return null;
            var sourceStillMatches = sourceItems.Any(item =>
                item.Path == review.SourcePath && item.IsDirectory == review.IsDirectory &&
                (review.IsDirectory || item.Size == review.Size));
            return review.Kind switch
            {
                FileCopyMoveOperation.Copy when sourceStillMatches => target,
                FileCopyMoveOperation.Move when !sourceStillMatches => target,
                _ => null,
            };
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsCopyMoveReadFailure(error))
        {
            return null;
        }
    }

    private async Task<FileCopyMoveOutcome> ReviewFileCopyMoveAsync(FileCopyMoveReview review)
    {
        var confirmed = await TryReadBackFileCopyMoveAsync(review).ConfigureAwait(false);
        if (confirmed is not null)
        {
            RemoveFileCopyMoveReview(review);
            return CopyMoveOutcome(review.Operation, MutationResultStatus.ConfirmedSuccess,
                true, false, null, null, confirmed);
        }
        return CopyMoveOutcome(review.Operation, MutationResultStatus.SubmittedButUnverified,
            true, true, MutationErrorCategory.Unknown, "file.copy-move.review-pending");
    }

    private bool ValidCopyMoveRequest(FileCopyMoveRequest request)
    {
        var target = request.Target;
        return request.Operation is FileCopyMoveOperation.Copy or FileCopyMoveOperation.Move &&
            target.ProfileId == ProfileId && ValidMutationObjectPath(target.Path) &&
            ValidMutationItemName(target.Name) && MutationParent(target.Path).Length > 0 &&
            target.Path.EndsWith("/" + target.Name, StringComparison.Ordinal) &&
            target.Size >= 0 && target.CanRead &&
            (request.Operation == FileCopyMoveOperation.Copy || target.CanDelete) &&
            !target.IsRemote && !target.IsVirtual && !target.IsRecycle &&
            !ContainsRecycleSegment(target.Path) &&
            ValidMutationDirectory(request.DestinationDirectoryPath) &&
            request.DestinationCanWrite && !request.DestinationIsRemote &&
            !request.DestinationIsVirtual && !request.DestinationIsRecycle &&
            !ContainsRecycleSegment(request.DestinationDirectoryPath);
    }

    private static bool MatchesFrozenSource(FileItem? observed, FileCopyMoveTarget frozen) =>
        observed is not null && observed.IsDirectory == frozen.IsDirectory &&
        observed.Path == frozen.Path && observed.Name == frozen.Name &&
        (frozen.IsDirectory || observed.Size == frozen.Size) &&
        observed.ModifiedAt == frozen.ModifiedAt;

    private static bool ContainsRecycleSegment(string path) =>
        path.Split('/').Any(segment =>
            segment.Equals("#recycle", StringComparison.OrdinalIgnoreCase));

    private async Task<bool> CopyMoveMountsAreLocalAsync(string sourcePath,
        string destinationPath, CancellationToken cancellationToken)
    {
        const int maximumShares = 500;
        var requiredRoots = new HashSet<string>(StringComparer.Ordinal)
        {
            MutationShareRoot(sourcePath),
            MutationShareRoot(destinationPath),
        };
        var capability = _capabilities["SYNO.FileStation.List"];
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2,
            "list", new Dictionary<string, string>
            {
                ["folder_path"] = string.Empty,
                ["offset"] = "0",
                ["limit"] = maximumShares.ToString(CultureInfo.InvariantCulture),
                ["additional"] = "[\"mount_point_type\"]",
            }, cancellationToken).ConfigureAwait(false);
        var offset = NativeInt(data, "offset");
        var total = NativeInt(data, "total");
        if (offset != 0 || total > maximumShares || data["files"] is not JsonArray files ||
            files.Count > maximumShares || files.Count != total)
            throw new InvalidDataException("file.copy-move.invalid-mount-page");

        var seenRoots = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in files)
        {
            if (node is not JsonObject item || NativeString(item, "path") is not { } path ||
                NativeString(item, "name") is not { } name ||
                !NativeBool(item, "isdir", out var isDirectory) || !isDirectory ||
                MutationParent(path).Length != 0 || !path.EndsWith("/" + name, StringComparison.Ordinal) ||
                !ValidMutationObjectPath(path) || !ValidMutationItemName(name) ||
                !seenRoots.Add(path))
                throw new InvalidDataException("file.copy-move.invalid-mount-item");
            if (!requiredRoots.Contains(path)) continue;
            var mountType = CopyMoveMountType(item);
            if (!IsLocalCopyMoveMount(mountType)) return false;
            requiredRoots.Remove(path);
        }
        return requiredRoots.Count == 0;
    }

    private static string MutationShareRoot(string path)
    {
        var separator = path.IndexOf('/', 1);
        return separator < 0 ? path : path[..separator];
    }

    private static string? CopyMoveMountType(JsonObject item)
    {
        if (!item.ContainsKey("additional") || item["additional"] is null) return null;
        if (item["additional"] is not JsonObject additional)
            throw new InvalidDataException("file.copy-move.invalid-mount-additional");
        if (!additional.ContainsKey("mount_point_type") || additional["mount_point_type"] is null)
            return null;
        if (additional["mount_point_type"] is not JsonValue value ||
            !value.TryGetValue<string>(out var mountType))
            throw new InvalidDataException("file.copy-move.invalid-mount-type");
        return mountType;
    }

    private static bool IsLocalCopyMoveMount(string? mountType) => mountType is null or
        "" or "normal" or "shared_folder";

    private FileCopyMoveReservation ReserveFileCopyMove(FileCopyMoveReview requested)
    {
        var state = FileCopyMoveState();
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

    private void ReleaseFileCopyMove(HashSet<string> targets)
    {
        var state = FileCopyMoveState();
        lock (state.Sync) state.ActiveTargets.ExceptWith(targets);
    }

    private void StoreFileCopyMoveReview(FileCopyMoveReview review)
    {
        var state = FileCopyMoveState();
        lock (state.Sync) state.Reviews[review.Key] = review;
    }

    private void RemoveFileCopyMoveReview(FileCopyMoveReview review)
    {
        var state = FileCopyMoveState();
        lock (state.Sync) state.Reviews.Remove(review.Key);
    }

    private FileCopyMoveSessionState FileCopyMoveState()
    {
        var apiState = FileCopyMoveApiStates.GetValue(_api, _ => new());
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

    private static bool IsCopyMoveReadFailure(Exception error) =>
        error is DsmException or JsonException or InvalidDataException or OverflowException;

    private static FileCopyMoveOutcome CopyMovePermissionOutcome(string operation,
        FilePermissionTransportResult result) => CopyMoveOutcome(operation,
            result.Status switch
            {
                FilePermissionTransportStatus.Denied => MutationResultStatus.PermissionDenied,
                FilePermissionTransportStatus.Cancelled =>
                    MutationResultStatus.CancelledBeforeSubmission,
                FilePermissionTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                _ => MutationResultStatus.ConfirmedFailure,
            }, false, false, result.ErrorCategory, result.DiagnosticTag);

    private static FileCopyMoveOutcome CopyMoveOutcome(string operation,
        MutationResultStatus status, bool submitted, bool refresh,
        MutationErrorCategory? category, string? tag, FileItem? item = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = success == 0 && unknown == 0 &&
            status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new(new MutationResult(1, status, operation, submitted, refresh,
            new MutationResultCounts(success, failed, unknown), category,
            diagnosticTag: tag), item);
    }

    private sealed record FileCopyMoveReview(
        string Operation,
        string SourcePath,
        string SourceParent,
        string DestinationParent,
        string DestinationPath,
        string Name,
        long Size,
        DateTimeOffset? ModifiedAt,
        bool IsDirectory,
        FileCopyMoveOperation Kind,
        HashSet<string> Targets)
    {
        public string Key { get; } = $"{Operation}|{SourcePath}|{DestinationPath}";
    }

    private readonly record struct FileCopyMoveReservation(
        bool Acquired,
        FileCopyMoveReview? PendingReview);

    private sealed class FileCopyMoveSessionState
    {
        public object Sync { get; } = new();
        public HashSet<string> ActiveTargets { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, FileCopyMoveReview> Reviews { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed class FileCopyMoveApiState
    {
        public object Sync { get; } = new();
        public Dictionary<DsmSession, FileCopyMoveSessionState> Sessions { get; } = [];
    }
}
