using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileArchiveCompressionPollLimit = 8;
    private const int FileArchiveCompressionPageSize = 100;
    private const int FileArchiveCompressionItemLimit = 5000;
    private static readonly object FileArchiveMutationStatesSync = new();
    private static readonly Dictionary<Guid, FileArchiveMutationApiState>
        FileArchiveMutationStates = [];

    public FileArchiveCompressionAvailability FileArchiveCompressionAvailability =>
        new(
            CanCompress: ArchiveCompressionCapabilityAvailable,
            CompressVersion: HasArchiveCapability("SYNO.FileStation.Compress", 3) ? 3 : null,
            ListVersion: HasArchiveCapability("SYNO.FileStation.List", 2) ? 2 : null,
            CheckPermissionVersion: HasArchiveCapability("SYNO.FileStation.CheckPermission", 3)
                ? 3
                : null);

    FileArchiveCompressionAvailability IFileArchiveCompressionRepository.Availability =>
        FileArchiveCompressionAvailability;

    public async Task<FileArchiveCompressionOutcome> CompressAsync(
        FileArchiveCompressionRequest request,
        CancellationToken cancellationToken = default)
    {
        if (!TryNormalizeRequest(request, out var normalized, out var review, out var invalidTag))
            return ArchiveOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Validation, invalidTag);

        var reservation = ReserveArchiveCompression(review!);
        if (!reservation.Acquired)
            return ArchiveOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Conflict, "file.archive-compression.target-busy");

        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewArchiveCompressionAsync(reservation.PendingReview)
                    .ConfigureAwait(false);

            if (!ArchiveCompressionCapabilityAvailable)
                return ArchiveOutcome(MutationResultStatus.Unsupported, false, false,
                    MutationErrorCategory.Unsupported, "file.archive-compression.unsupported");
            if (cancellationToken.IsCancellationRequested)
                return ArchiveOutcome(MutationResultStatus.CancelledBeforeSubmission,
                    false, false, null, "file.archive-compression.cancelled-before-submit");

            IReadOnlyList<FileArchiveListedItem> baseline;
            try
            {
                baseline = await LoadArchiveFolderAsync(review!.SourceParent,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
            {
                throw;
            }
            catch (Exception)
            {
                return ArchiveOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    MutationErrorCategory.Unknown, "file.archive-compression.preflight-invalid");
            }

            if (normalized.Sources.Any(source =>
                    baseline.SingleOrDefault(item => item.Item.Path == source.Item.Path) is not
                        { } observed || !MatchesArchiveSource(observed, source)))
            {
                return ArchiveOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    MutationErrorCategory.Validation, "file.archive-compression.source-changed");
            }

            if (baseline.Any(item => item.Item.Path == review.DestinationPath))
            {
                return ArchiveOutcome(MutationResultStatus.ConfirmedFailure, false, false,
                    MutationErrorCategory.Conflict, "file.archive-compression.target-conflict");
            }

            var permission = await _api.CheckFileMutationPermissionAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.CheckPermission"],
                review.SourceParent,
                normalized.DestinationName,
                cancellationToken).ConfigureAwait(false);
            if (permission.ErrorCategory == MutationErrorCategory.Authentication)
                throw ArchiveAuthenticationException();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return ArchivePermissionOutcome(permission);

            return await SubmitArchiveCompressionAsync(normalized, review, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return ArchiveOutcome(MutationResultStatus.CancelledBeforeSubmission,
                false, false, null, "file.archive-compression.cancelled-before-submit");
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        finally
        {
            ReleaseArchiveCompression(review!.ReservedPaths);
        }
    }

    private async Task<FileArchiveCompressionOutcome> SubmitArchiveCompressionAsync(
        FileArchiveCompressionRequest request,
        FileArchiveCompressionReview review,
        CancellationToken cancellationToken)
    {
        FileArchiveCompressionStartTransportResult start;
        try
        {
            start = await _api.StartFileArchiveCompressionAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Compress"],
                request.Sources.Select(source => source.Item.Path).ToArray(),
                review.DestinationPath,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return await FinishArchiveCompressionAsync(review, cancellationAfterSubmission: true,
                confirmedFailure: false, MutationErrorCategory.Network,
                "file.archive-compression.cancelled-after-submit").ConfigureAwait(false);
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            StoreArchiveReview(review);
            throw;
        }
        catch (Exception)
        {
            return await FinishArchiveCompressionAsync(review, cancellationAfterSubmission: false,
                confirmedFailure: false, MutationErrorCategory.Unknown,
                "file.archive-compression.transport-unverified").ConfigureAwait(false);
        }

        if (start.ErrorCategory == MutationErrorCategory.Authentication)
        {
            StoreArchiveReview(review);
            throw ArchiveAuthenticationException();
        }
        if (start.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return ArchiveOutcome(MutationResultStatus.CancelledBeforeSubmission,
                false, false, start.ErrorCategory, start.DiagnosticTag);
        if (start.Status == FileMutationTransportStatus.Unsupported)
            return ArchiveOutcome(MutationResultStatus.Unsupported,
                false, false, start.ErrorCategory, start.DiagnosticTag);

        var cancellationAfterSubmission =
            start.Status == FileMutationTransportStatus.CancellationRequestedAfterSubmission;
        var confirmedFailure = start.Status == FileMutationTransportStatus.ConfirmedFailure;
        var postSubmitFailure = start.Status != FileMutationTransportStatus.ResponseReceived;
        var taskFinished = false;

        if (start.Status == FileMutationTransportStatus.ResponseReceived &&
            ValidArchiveCompressionTaskId(start.TaskId))
        {
            try
            {
                taskFinished = await PollArchiveCompressionAsync(start.TaskId!, cancellationToken)
                    .ConfigureAwait(false);
                postSubmitFailure = !taskFinished;
            }
            catch (OperationCanceledException)
            {
                cancellationAfterSubmission = true;
                postSubmitFailure = true;
                StoreArchiveReview(review);
                await StopArchiveCompressionBestEffortAsync(start.TaskId!).ConfigureAwait(false);
            }
            catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
            {
                StoreArchiveReview(review);
                throw;
            }
            catch (Exception)
            {
                postSubmitFailure = true;
            }
        }
        else if (start.Status == FileMutationTransportStatus.ResponseReceived)
        {
            postSubmitFailure = true;
        }

        return await FinishArchiveCompressionAsync(
            review,
            cancellationAfterSubmission,
            confirmedFailure,
            start.ErrorCategory ?? (postSubmitFailure || !taskFinished
                ? MutationErrorCategory.Unknown
                : null),
            start.DiagnosticTag ?? "file.archive-compression.readback-unverified")
            .ConfigureAwait(false);
    }

    private async Task<FileArchiveCompressionOutcome> FinishArchiveCompressionAsync(
        FileArchiveCompressionReview review,
        bool cancellationAfterSubmission,
        bool confirmedFailure,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag)
    {
        FileItem? confirmed;
        try
        {
            confirmed = await TryReadBackArchiveCompressionAsync(review).ConfigureAwait(false);
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            StoreArchiveReview(review);
            throw;
        }

        if (confirmed is not null)
        {
            RemoveArchiveReview(review);
            return ArchiveOutcome(MutationResultStatus.ConfirmedSuccess,
                true, true, null, null, confirmed);
        }
        if (confirmedFailure && !cancellationAfterSubmission)
            return ArchiveOutcome(MutationResultStatus.ConfirmedFailure,
                true, true, errorCategory, diagnosticTag);

        StoreArchiveReview(review);
        return ArchiveOutcome(
            cancellationAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            true,
            true,
            errorCategory ?? MutationErrorCategory.Unknown,
            diagnosticTag);
    }

    private async Task<bool> PollArchiveCompressionAsync(
        string taskId,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < FileArchiveCompressionPollLimit; attempt++)
        {
            var status = await _api.ReadFileArchiveCompressionStatusAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Compress"],
                taskId,
                cancellationToken).ConfigureAwait(false);
            if (status.ErrorCategory == MutationErrorCategory.Authentication)
                throw ArchiveAuthenticationException();
            if (status.Status == FileArchiveCompressionTaskTransportStatus.Finished)
                return true;
            if (status.Status != FileArchiveCompressionTaskTransportStatus.Running)
                return false;
            await Task.Delay(TimeSpan.FromMilliseconds(Math.Min(2000, 500 * (1 << attempt))),
                cancellationToken).ConfigureAwait(false);
        }
        return false;
    }

    private async Task StopArchiveCompressionBestEffortAsync(string taskId)
    {
        try
        {
            var result = await _api.StopFileArchiveCompressionAsync(
                _profile,
                _session,
                _capabilities["SYNO.FileStation.Compress"],
                taskId,
                CancellationToken.None).ConfigureAwait(false);
            if (result.ErrorCategory == MutationErrorCategory.Authentication)
                throw ArchiveAuthenticationException();
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception)
        {
            // 取消后的 stop 只是尽力而为，最终状态仍由独立目录回读决定。
        }
    }

    private async Task<FileArchiveCompressionOutcome> ReviewArchiveCompressionAsync(
        FileArchiveCompressionReview review)
    {
        try
        {
            var confirmed = await TryReadBackArchiveCompressionAsync(review).ConfigureAwait(false);
            if (confirmed is not null)
            {
                RemoveArchiveReview(review);
                return ArchiveOutcome(MutationResultStatus.ConfirmedSuccess,
                    true, true, null, null, confirmed);
            }
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception)
        {
            // 保留 review，下一次相同请求仍然只能回读。
        }
        return ArchiveOutcome(MutationResultStatus.SubmittedButUnverified,
            true, true, MutationErrorCategory.Unknown,
            "file.archive-compression.review-pending");
    }

    private async Task<FileItem?> TryReadBackArchiveCompressionAsync(
        FileArchiveCompressionReview review)
    {
        try
        {
            var items = await LoadArchiveFolderAsync(review.SourceParent, CancellationToken.None)
                .ConfigureAwait(false);
            var target = items.SingleOrDefault(item =>
                item.Item.Path == review.DestinationPath &&
                !item.Item.IsDirectory && item.Item.Size > 0);
            return target?.Item;
        }
        catch (DsmException error) when (IsArchiveAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private async Task<IReadOnlyList<FileArchiveListedItem>> LoadArchiveFolderAsync(
        string folderPath,
        CancellationToken cancellationToken)
    {
        var capability = _capabilities["SYNO.FileStation.List"];
        var result = new List<FileArchiveListedItem>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var offset = 0;
        int? stableTotal = null;
        while (offset < FileArchiveCompressionItemLimit)
        {
            var requestedLimit = Math.Min(FileArchiveCompressionPageSize,
                FileArchiveCompressionItemLimit - offset);
            var data = await _api.CallReadJsonObjectAsync(
                _profile,
                _session,
                capability,
                2,
                "list",
                new Dictionary<string, string>
                {
                    ["folder_path"] = folderPath,
                    ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                    ["limit"] = requestedLimit.ToString(CultureInfo.InvariantCulture),
                    ["additional"] = "[\"size\",\"time\",\"perm\"]",
                },
                cancellationToken).ConfigureAwait(false);
            var pageOffset = ArchiveNativeInt(data, "offset");
            var total = ArchiveNativeInt(data, "total");
            if (pageOffset != offset || (stableTotal is not null && stableTotal != total) ||
                total > FileArchiveCompressionItemLimit ||
                data["files"] is not JsonArray files || files.Count > requestedLimit)
                throw new InvalidDataException("file.archive-compression.invalid-list-page");
            stableTotal ??= total;
            if (files.Count == 0)
            {
                if (offset < total)
                    throw new InvalidDataException("file.archive-compression.zero-progress");
                break;
            }
            var nextOffset = checked(offset + files.Count);
            if (nextOffset > total)
                throw new InvalidDataException("file.archive-compression.list-over-total");
            foreach (var node in files)
            {
                var item = ParseArchiveListedItem(node, folderPath);
                if (!seen.Add(item.Item.Path))
                    throw new InvalidDataException("file.archive-compression.duplicate-list-item");
                result.Add(item);
            }
            offset = nextOffset;
            if (offset >= total)
                break;
        }
        if (stableTotal is null || result.Count != stableTotal)
            throw new InvalidDataException("file.archive-compression.truncated-list");
        return result;
    }

    private static FileArchiveListedItem ParseArchiveListedItem(JsonNode? node, string folderPath)
    {
        if (node is not JsonObject item || ArchiveNativeString(item, "path") is not { } path ||
            ArchiveNativeString(item, "name") is not { } name ||
            !ArchiveNativeBool(item, "isdir", out var isDirectory) ||
            !ValidArchiveObjectPath(path) || ArchiveMutationParent(path) != folderPath ||
            !path.EndsWith("/" + name, StringComparison.Ordinal) ||
            item["additional"] is not (null or JsonObject))
            throw new InvalidDataException("file.archive-compression.invalid-list-item");

        var additional = item["additional"] as JsonObject;
        var size = isDirectory ? 0 : ReadArchiveSize(item, additional);
        if (size < 0)
            throw new InvalidDataException("file.archive-compression.invalid-size");
        var modified = ReadArchiveTime(item, additional);
        var canRead = true;
        var canWrite = false;
        var canDelete = false;
        if (additional?["perm"] is not null)
        {
            if (additional["perm"] is not JsonObject permission)
                throw new InvalidDataException("file.archive-compression.invalid-permission");
            if (permission["read"] is not null &&
                !ArchiveNativeBool(permission, "read", out canRead))
                throw new InvalidDataException("file.archive-compression.invalid-permission");
            if (permission["write"] is not null &&
                !ArchiveNativeBool(permission, "write", out canWrite))
                throw new InvalidDataException("file.archive-compression.invalid-permission");
            if (permission["delete"] is not null &&
                !ArchiveNativeBool(permission, "delete", out canDelete))
                throw new InvalidDataException("file.archive-compression.invalid-permission");
        }
        return new(new FileItem(path, name, isDirectory, size, modified, null,
            canWrite, canDelete), canRead);
    }

    private bool TryNormalizeRequest(
        FileArchiveCompressionRequest request,
        out FileArchiveCompressionRequest normalized,
        out FileArchiveCompressionReview? review,
        out string invalidTag)
    {
        normalized = request;
        review = null;
        invalidTag = "file.archive-compression.invalid-input";
        if (request is null || request.ProfileId != ProfileId ||
            request.Sources is null || request.Sources.Count is < 1 or > 20 ||
            !TryNormalizeArchiveName(request.DestinationName, out var destinationName))
            return false;

        var sources = request.Sources.ToArray();
        var firstParent = string.Empty;
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var source in sources)
        {
            var item = source?.Item;
            if (source is null || item is null ||
                source.SourceKind != FileArchiveCompressionSourceKind.Local ||
                !source.CanRead || !ValidArchiveObjectPath(item.Path) ||
                !ValidArchiveItemName(item.Name) || item.Size < 0 ||
                !item.Path.EndsWith("/" + item.Name, StringComparison.Ordinal) ||
                ArchiveContainsRecycleSegment(item.Path))
                return false;
            var parent = ArchiveMutationParent(item.Path);
            if (firstParent.Length == 0)
                firstParent = parent;
            if (!string.Equals(firstParent, parent, StringComparison.Ordinal) ||
                !paths.Add(item.Path))
                return false;
        }

        for (var i = 0; i < sources.Length; i++)
        for (var j = i + 1; j < sources.Length; j++)
        {
            var left = sources[i].Item.Path;
            var right = sources[j].Item.Path;
            if (left.StartsWith(right + "/", StringComparison.Ordinal) ||
                right.StartsWith(left + "/", StringComparison.Ordinal))
                return false;
        }

        var destinationPath = $"{firstParent}/{destinationName}";
        normalized = new FileArchiveCompressionRequest(ProfileId, sources, destinationName);
        review = new FileArchiveCompressionReview(
            normalized,
            firstParent,
            destinationPath,
            new HashSet<string>(sources.Select(source => source.Item.Path)
                .Append(destinationPath), StringComparer.Ordinal));
        return true;
    }

    private FileArchiveCompressionReservation ReserveArchiveCompression(
        FileArchiveCompressionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
        {
            state.Reviews.TryGetValue(review.Key, out var pending);
            var unresolvedPaths = state.Reviews
                .Where(item => item.Key != review.Key)
                .SelectMany(item => item.Value.ReservedPaths)
                .Concat(state.ExtractionReviews.Values
                    .SelectMany(item => item.ReservedPaths))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            if (review.Request.ProfileId != ProfileId ||
                HasArchivePathConflict(state.ActivePaths, review.ReservedPaths) ||
                HasArchivePathConflict(unresolvedPaths, review.ReservedPaths))
                return new(false, null);
            foreach (var path in review.ReservedPaths)
                state.ActivePaths.Add(path);
            return new(true, pending);
        }
    }

    private void ReleaseArchiveCompression(IReadOnlySet<string> paths)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
        foreach (var path in paths)
            state.ActivePaths.Remove(path);
    }

    private void StoreArchiveReview(FileArchiveCompressionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
            state.Reviews[review.Key] = review;
    }

    private void RemoveArchiveReview(FileArchiveCompressionReview review)
    {
        var state = ArchiveMutationStateForProfile(ProfileId);
        lock (state.Sync)
            state.Reviews.Remove(review.Key);
    }

    private bool ArchiveCompressionCapabilityAvailable =>
        HasArchiveCapability("SYNO.FileStation.Compress", 3) &&
        HasArchiveCapability("SYNO.FileStation.List", 2) &&
        HasArchiveCapability("SYNO.FileStation.CheckPermission", 3);

    private bool HasArchiveCapability(string name, int version) =>
        _capabilities.TryGetValue(name, out var capability) && capability.Name == name &&
        version >= capability.MinVersion && version <= capability.MaxVersion &&
        capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) &&
        !string.IsNullOrWhiteSpace(capability.Path);

    private static FileArchiveCompressionOutcome ArchivePermissionOutcome(
        FilePermissionTransportResult permission) => ArchiveOutcome(
            permission.Status switch
            {
                FilePermissionTransportStatus.Denied => MutationResultStatus.PermissionDenied,
                FilePermissionTransportStatus.Cancelled => MutationResultStatus.CancelledBeforeSubmission,
                FilePermissionTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                _ => MutationResultStatus.ConfirmedFailure,
            },
            false,
            false,
            permission.ErrorCategory,
            permission.DiagnosticTag);

    private static FileArchiveCompressionOutcome ArchiveOutcome(
        MutationResultStatus status,
        bool submitted,
        bool refresh,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag,
        FileItem? confirmedItem = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = success == 0 && unknown == 0 &&
            status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new(new MutationResult(1, status, "compressFile", submitted, refresh,
            new MutationResultCounts(success, failed, unknown), errorCategory,
            diagnosticTag: diagnosticTag), confirmedItem);
    }

    private static bool MatchesArchiveSource(
        FileArchiveListedItem observed,
        FileArchiveCompressionSource expected) =>
        observed.CanRead == expected.CanRead &&
        observed.Item.Path == expected.Item.Path &&
        observed.Item.Name == expected.Item.Name &&
        observed.Item.IsDirectory == expected.Item.IsDirectory &&
        observed.Item.Size == expected.Item.Size &&
        observed.Item.ModifiedAt == expected.Item.ModifiedAt;

    private static bool TryNormalizeArchiveName(string? value, out string normalized)
    {
        normalized = string.Empty;
        if (string.IsNullOrWhiteSpace(value) || value != value.Trim())
            return false;
        var name = value;
        while (name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            name = name[..^4];
        if (!ValidArchiveItemName(name))
            return false;
        normalized = name + ".zip";
        return true;
    }

    private static bool ValidArchiveItemName(string value) =>
        !string.IsNullOrWhiteSpace(value) && value == value.Trim() && value is not ("." or "..") &&
        value.IndexOfAny(['/', '\\']) < 0 && !value.Any(char.IsControl);

    private static bool ValidArchiveObjectPath(string value) =>
        !string.IsNullOrWhiteSpace(value) && value.StartsWith('/') && value != "/" &&
        !value.EndsWith('/') && !value.Contains("//") && !value.Contains('\\') &&
        value.IndexOfAny(['\r', '\n', '\0']) < 0 &&
        !value.Split('/').Any(segment => segment is "." or "..");

    private static string ArchiveMutationParent(string path) => path[..path.LastIndexOf('/')];

    private static bool ArchiveContainsRecycleSegment(string path) =>
        path.Split('/').Any(segment =>
            segment.Equals("#recycle", StringComparison.OrdinalIgnoreCase));

    private static int ArchiveNativeInt(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<int>(out var result) && result >= 0
            ? result
            : throw new InvalidDataException("file.archive-compression.invalid-integer");

    private static string? ArchiveNativeString(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<string>(out var result) &&
        !string.IsNullOrEmpty(result) ? result : null;

    private static bool ArchiveNativeBool(JsonObject item, string key, out bool result)
    {
        result = false;
        return item[key] is JsonValue value && value.TryGetValue<bool>(out result);
    }

    private static long ReadArchiveSize(JsonObject item, JsonObject? additional)
    {
        if (item["size"] is JsonValue value && value.TryGetValue<long>(out var direct))
            return direct;
        if (additional?["size"] is JsonValue nested &&
            nested.TryGetValue<long>(out var indirect))
            return indirect;
        throw new InvalidDataException("file.archive-compression.invalid-size");
    }

    private static DateTimeOffset? ReadArchiveTime(JsonObject item, JsonObject? additional)
    {
        JsonNode? node = item["mtime"];
        if (node is null && additional?["time"] is JsonObject time)
            node = time["mtime"];
        if (node is null)
            return null;
        if (node is not JsonValue value || !value.TryGetValue<long>(out var seconds) || seconds < 0)
            throw new InvalidDataException("file.archive-compression.invalid-time");
        return DateTimeOffset.FromUnixTimeSeconds(seconds);
    }

    private static bool IsArchiveAuthenticationFailure(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401;

    private static DsmException ArchiveAuthenticationException() => new(
        UserText.Key("WinSharedf91eef8a1cf7b01c"),
        UserText.Key("WinShared79c4d60046afa3ff"),
        authenticationFailure: true);

    private static FileArchiveMutationApiState ArchiveMutationStateForProfile(Guid profileId)
    {
        lock (FileArchiveMutationStatesSync)
        {
            if (!FileArchiveMutationStates.TryGetValue(profileId, out var state))
            {
                state = new FileArchiveMutationApiState();
                FileArchiveMutationStates[profileId] = state;
            }
            return state;
        }
    }

    private static bool HasArchivePathConflict(
        IReadOnlySet<string> activePaths,
        IReadOnlySet<string> requestedPaths) =>
        activePaths.Any(active => requestedPaths.Any(requested =>
            active.Equals(requested, StringComparison.OrdinalIgnoreCase) ||
            active.StartsWith(requested + "/", StringComparison.OrdinalIgnoreCase) ||
            requested.StartsWith(active + "/", StringComparison.OrdinalIgnoreCase)));

    private sealed class FileArchiveMutationApiState
    {
        public object Sync { get; } = new();
        public HashSet<string> ActivePaths { get; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, FileArchiveCompressionReview> Reviews { get; } =
            new(StringComparer.Ordinal);
        public Dictionary<string, FileArchiveExtractionReview> ExtractionReviews { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed record FileArchiveCompressionReservation(
        bool Acquired,
        FileArchiveCompressionReview? PendingReview);

    private sealed record FileArchiveListedItem(FileItem Item, bool CanRead);

    private sealed record FileArchiveCompressionReview(
        FileArchiveCompressionRequest Request,
        string SourceParent,
        string DestinationPath,
        HashSet<string> ReservedPaths)
    {
        public string Key => $"{Request.ProfileId:N}|{DestinationPath}|" +
            string.Join("|", Request.Sources.Select(source => source.Item.Path)
                .OrderBy(path => path, StringComparer.Ordinal));
    }

    private static bool ValidArchiveCompressionTaskId(string? taskId) =>
        !string.IsNullOrWhiteSpace(taskId) && taskId == taskId.Trim() && taskId.Length <= 256 &&
        taskId.All(character => character is >= 'a' and <= 'z' or
            >= 'A' and <= 'Z' or >= '0' and <= '9' or '_' or '-' or '.');
}
