using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileMutationLimit = 5000;
    private const int FileMutationPageSize = 500;
    private static readonly ConditionalWeakTable<IDsmApiClient, FileMutationApiState>
        FileMutationApiStates = new();

    public FileMutationAvailability FileMutationAvailability => new(
        CanCreateFolder: MutationCapability("SYNO.FileStation.CreateFolder", 2) &&
            MutationCapability("SYNO.FileStation.CheckPermission", 3) && MutationListAvailable,
        CanRename: MutationCapability("SYNO.FileStation.Rename", 2) &&
            MutationCapability("SYNO.FileStation.CheckPermission", 3) && MutationListAvailable,
        CreateFolderVersion: MutationCapability("SYNO.FileStation.CreateFolder", 2) ? 2 : null,
        RenameVersion: MutationCapability("SYNO.FileStation.Rename", 2) ? 2 : null);

    private bool MutationListAvailable => MutationCapability("SYNO.FileStation.List", 2);

    public async Task<FileMutationOutcome> CreateFolderAsync(
        CreateFolderRequest request, CancellationToken cancellationToken = default)
    {
        if (request.ProfileId != ProfileId || !ValidMutationDirectory(request.ParentPath) ||
            !ValidMutationItemName(request.Name) || !FileMutationAvailability.CanCreateFolder)
            return MutationOutcome("createFolder", MutationResultStatus.Unsupported, false, false,
                MutationErrorCategory.Unsupported, "file.create-folder.unsupported");
        var targetPath = JoinMutationPath(request.ParentPath, request.Name);
        var review = new FileMutationReview("createFolder", request.ParentPath, targetPath,
            null, true, [targetPath]);
        var reservation = ReserveFileMutation(review);
        if (!reservation.Acquired)
            return MutationOutcome("createFolder", MutationResultStatus.ConfirmedFailure,
                false, false, MutationErrorCategory.Conflict, "file.create-folder.target-busy");
        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewFileMutationAsync(reservation.PendingReview).ConfigureAwait(false);
            var before = await LoadMutationFolderAsync(request.ParentPath, cancellationToken)
                .ConfigureAwait(false);
            if (before.Any(item => item.Path == targetPath))
                return MutationOutcome("createFolder", MutationResultStatus.ConfirmedFailure,
                    false, false, MutationErrorCategory.Conflict, "file.create-folder.conflict");
            var permission = await _api.CheckFileMutationPermissionAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CheckPermission"], request.ParentPath,
                request.Name, cancellationToken).ConfigureAwait(false);
            if (permission.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return PermissionOutcome("createFolder", permission);
            return await SubmitAndFinishMutationAsync("createFolder", () =>
                    _api.CreateFolderMutationAsync(_profile, _session,
                        _capabilities["SYNO.FileStation.CreateFolder"], request.ParentPath,
                        request.Name, cancellationToken), request.ParentPath, targetPath,
                    oldPath: null, expectedDirectory: true, review: review)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return MutationOutcome("createFolder", MutationResultStatus.CancelledBeforeSubmission,
                false, false, null, "file.create-folder.cancelled-before-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsMutationReadFailure(error))
        {
            return MutationOutcome("createFolder", MutationResultStatus.ConfirmedFailure,
                false, false, MutationErrorCategory.Unknown, "file.create-folder.preflight-invalid");
        }
        finally
        {
            ReleaseFileMutation(review.Targets);
        }
    }

    public async Task<FileMutationOutcome> RenameAsync(
        RenameFileItemRequest request, CancellationToken cancellationToken = default)
    {
        var target = request.Target;
        if (target.ProfileId != ProfileId || !ValidMutationObjectPath(target.Path) ||
            !ValidMutationItemName(request.NewName) || !FileMutationAvailability.CanRename)
            return MutationOutcome("rename", MutationResultStatus.Unsupported, false, false,
                MutationErrorCategory.Unsupported, "file.rename.unsupported");
        if (!target.CanWrite)
            return MutationOutcome("rename", MutationResultStatus.PermissionDenied, false, false,
                MutationErrorCategory.Permission, "file.rename.permission-denied");
        if (request.NewName == target.Name)
            return MutationOutcome("rename", MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Validation, "file.rename.unchanged");
        var parent = MutationParent(target.Path);
        if (!ValidMutationDirectory(parent))
            return MutationOutcome("rename", MutationResultStatus.Unsupported, false, false,
                MutationErrorCategory.Unsupported, "file.rename.unsupported");
        var newPath = JoinMutationPath(parent, request.NewName);
        var review = new FileMutationReview("rename", parent, newPath, target.Path,
            target.IsDirectory, [target.Path, newPath]);
        var reservation = ReserveFileMutation(review);
        if (!reservation.Acquired)
            return MutationOutcome("rename", MutationResultStatus.ConfirmedFailure,
                false, false, MutationErrorCategory.Conflict, "file.rename.target-busy");
        try
        {
            if (reservation.PendingReview is not null)
                return await ReviewFileMutationAsync(reservation.PendingReview).ConfigureAwait(false);
            var before = await LoadMutationFolderAsync(parent, cancellationToken).ConfigureAwait(false);
            var source = before.SingleOrDefault(item => item.Path == target.Path);
            if (source is null || source.Name != target.Name ||
                source.IsDirectory != target.IsDirectory || source.Size != target.Size ||
                source.ModifiedAt != target.ModifiedAt || source.CanWrite != target.CanWrite)
                return MutationOutcome("rename", MutationResultStatus.ConfirmedFailure, false, false,
                    MutationErrorCategory.Validation, "file.rename.target-changed");
            if (before.Any(item => item.Path == newPath))
                return MutationOutcome("rename", MutationResultStatus.ConfirmedFailure, false, false,
                    MutationErrorCategory.Conflict, "file.rename.conflict");
            var permission = await _api.CheckFileMutationPermissionAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CheckPermission"], parent, request.NewName,
                cancellationToken).ConfigureAwait(false);
            if (permission.ErrorCategory == MutationErrorCategory.Authentication)
                throw MutationAuthenticationException();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return PermissionOutcome("rename", permission);
            return await SubmitAndFinishMutationAsync("rename", () =>
                    _api.RenameFileMutationAsync(_profile, _session,
                        _capabilities["SYNO.FileStation.Rename"], target.Path, request.NewName,
                        cancellationToken), parent, newPath, target.Path, target.IsDirectory, review)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return MutationOutcome("rename", MutationResultStatus.CancelledBeforeSubmission,
                false, false, null, "file.rename.cancelled-before-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsMutationReadFailure(error))
        {
            return MutationOutcome("rename", MutationResultStatus.ConfirmedFailure, false, false,
                MutationErrorCategory.Unknown, "file.rename.preflight-invalid");
        }
        finally
        {
            ReleaseFileMutation(review.Targets);
        }
    }

    private async Task<FileMutationOutcome> SubmitAndFinishMutationAsync(
        string operation,
        Func<Task<FileMutationTransportResult>> submit,
        string parent,
        string newPath,
        string? oldPath,
        bool expectedDirectory,
        FileMutationReview review)
    {
        try
        {
            // 调用真实 mutation transport 是不可逆提交边界；进入后任何异常都不得降级成未提交。
            var transport = await submit().ConfigureAwait(false);
            return await FinishMutationAsync(operation, transport, parent, newPath,
                oldPath, expectedDirectory, review).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            StoreFileMutationReview(review);
            return MutationOutcome(operation,
                MutationResultStatus.CancellationRequestedAfterSubmission,
                true, true, null, "file.mutation.cancelled-after-submit");
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileMutationReview(review);
            throw;
        }
        catch (Exception)
        {
            StoreFileMutationReview(review);
            return MutationOutcome(operation, MutationResultStatus.SubmittedButUnverified,
                true, true, MutationErrorCategory.Unknown,
                "file.mutation.transport-unverified");
        }
    }

    private async Task<FileMutationOutcome> FinishMutationAsync(string operation,
        FileMutationTransportResult transport, string parent, string newPath,
        string? oldPath, bool expectedDirectory, FileMutationReview review)
    {
        if (transport.Status == FileMutationTransportStatus.CancelledBeforeSubmission)
            return MutationOutcome(operation, MutationResultStatus.CancelledBeforeSubmission,
                false, false, transport.ErrorCategory, transport.DiagnosticTag);
        if (transport.Status == FileMutationTransportStatus.Unsupported)
            return MutationOutcome(operation, MutationResultStatus.Unsupported, false, false,
                transport.ErrorCategory, transport.DiagnosticTag);
        if (transport.Status == FileMutationTransportStatus.ConfirmedFailure)
        {
            if (transport.ErrorCategory == MutationErrorCategory.Authentication)
            {
                StoreFileMutationReview(review);
                throw MutationAuthenticationException();
            }
            return MutationOutcome(operation,
                transport.ErrorCategory == MutationErrorCategory.Permission
                    ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                true, false, transport.ErrorCategory, transport.DiagnosticTag);
        }
        try
        {
            var after = await LoadMutationFolderAsync(parent, CancellationToken.None)
                .ConfigureAwait(false);
            var confirmed = after.SingleOrDefault(item => item.Path == newPath);
            if (confirmed is not null && confirmed.IsDirectory == expectedDirectory &&
                (oldPath is null || after.All(item => item.Path != oldPath)))
                return MutationOutcome(operation, MutationResultStatus.ConfirmedSuccess,
                    true, false, null, null, confirmed);
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            StoreFileMutationReview(review);
            throw;
        }
        catch (Exception error) when (IsMutationReadFailure(error)) { }
        StoreFileMutationReview(review);
        if (transport.ErrorCategory == MutationErrorCategory.Authentication)
            throw MutationAuthenticationException();
        var status = transport.Status == FileMutationTransportStatus.CancellationRequestedAfterSubmission
            ? MutationResultStatus.CancellationRequestedAfterSubmission
            : MutationResultStatus.SubmittedButUnverified;
        return MutationOutcome(operation, status, true, true,
            transport.ErrorCategory ?? MutationErrorCategory.Unknown,
            transport.DiagnosticTag ?? "file.mutation.readback-unverified");
    }

    private async Task<FileMutationOutcome> ReviewFileMutationAsync(FileMutationReview review)
    {
        try
        {
            var after = await LoadMutationFolderAsync(review.Parent, CancellationToken.None)
                .ConfigureAwait(false);
            var confirmed = after.SingleOrDefault(item => item.Path == review.NewPath);
            if (confirmed is not null && confirmed.IsDirectory == review.ExpectedDirectory &&
                (review.OldPath is null || after.All(item => item.Path != review.OldPath)))
            {
                RemoveFileMutationReview(review);
                return MutationOutcome(review.Operation, MutationResultStatus.ConfirmedSuccess,
                    true, false, null, null, confirmed);
            }
        }
        catch (DsmException error) when (IsMutationAuthenticationFailure(error))
        {
            throw;
        }
        catch (Exception error) when (IsMutationReadFailure(error)) { }
        return MutationOutcome(review.Operation, MutationResultStatus.SubmittedButUnverified,
            true, true, MutationErrorCategory.Unknown, "file.mutation.review-pending");
    }

    private MutationReservation ReserveFileMutation(FileMutationReview requested)
    {
        var state = FileMutationState();
        lock (state.Sync)
        {
            if (state.Reviews.TryGetValue(requested.Key, out var pending))
            {
                if (state.ActiveTargets.Overlaps(requested.Targets)) return default;
                state.ActiveTargets.UnionWith(requested.Targets);
                return new(true, pending);
            }
            if (state.Reviews.Values.Any(review => review.Targets.Overlaps(requested.Targets)) ||
                state.ActiveTargets.Overlaps(requested.Targets))
                return default;
            state.ActiveTargets.UnionWith(requested.Targets);
            return new(true, null);
        }
    }

    private void ReleaseFileMutation(HashSet<string> targets)
    {
        var state = FileMutationState();
        lock (state.Sync) state.ActiveTargets.ExceptWith(targets);
    }

    private void StoreFileMutationReview(FileMutationReview review)
    {
        var state = FileMutationState();
        lock (state.Sync) state.Reviews[review.Key] = review;
    }

    private void RemoveFileMutationReview(FileMutationReview review)
    {
        var state = FileMutationState();
        lock (state.Sync) state.Reviews.Remove(review.Key);
    }

    private FileMutationSessionState FileMutationState()
    {
        var apiState = FileMutationApiStates.GetValue(_api, _ => new());
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

    private static DsmException MutationAuthenticationException() => new(
        UserText.Key("WinSharedf91eef8a1cf7b01c"),
        UserText.Key("WinShared79c4d60046afa3ff"),
        authenticationFailure: true);

    private async Task<IReadOnlyList<FileItem>> LoadMutationFolderAsync(
        string path, CancellationToken cancellationToken)
    {
        var capability = _capabilities["SYNO.FileStation.List"];
        var items = new List<FileItem>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var offset = 0;
        int? stableTotal = null;
        while (offset < FileMutationLimit)
        {
            var requestedLimit = Math.Min(FileMutationPageSize, FileMutationLimit - offset);
            var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2,
                "list", new Dictionary<string, string>
                {
                    ["folder_path"] = path,
                    ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                    ["limit"] = requestedLimit.ToString(CultureInfo.InvariantCulture),
                    ["additional"] = "[\"size\",\"time\",\"perm\"]",
                }, cancellationToken).ConfigureAwait(false);
            var pageOffset = NativeInt(data, "offset");
            var total = NativeInt(data, "total");
            if (pageOffset != offset || total < 0 || (stableTotal is not null && stableTotal != total))
                throw new InvalidDataException("file.mutation.invalid-pagination");
            stableTotal ??= total;
            if (data["files"] is not JsonArray files)
                throw new InvalidDataException("file.mutation.invalid-page");
            if (files.Count > requestedLimit)
                throw new InvalidDataException("file.mutation.page-over-limit");
            if (files.Count == 0)
            {
                if (offset < total)
                    throw new InvalidDataException("file.mutation.zero-progress");
                break;
            }
            var nextOffset = checked(offset + files.Count);
            if (nextOffset > total)
                throw new InvalidDataException("file.mutation.page-over-total");
            foreach (var node in files)
            {
                if (node is not JsonObject item || NativeString(item, "path") is not { } itemPath ||
                    NativeString(item, "name") is not { } name || !NativeBool(item, "isdir", out var isDir) ||
                    !ValidMutationObjectPath(itemPath) || !ValidMutationItemName(name) ||
                    MutationParent(itemPath) != path ||
                    !itemPath.EndsWith($"/{name}", StringComparison.Ordinal) ||
                    (item["additional"] is not null && item["additional"] is not JsonObject) ||
                    !seen.Add(itemPath))
                    throw new InvalidDataException("file.mutation.invalid-item");
                var additional = item["additional"] as JsonObject;
                long size;
                if (isDir) size = 0;
                else if (!NativeLong(item, "size", out size) &&
                    (additional is null || !NativeLong(additional, "size", out size)))
                    throw new InvalidDataException("file.mutation.invalid-size");
                if (size < 0) throw new InvalidDataException("file.mutation.invalid-size");
                var modified = OptionalMutationTime(item, additional);
                var canWrite = false;
                var canDelete = false;
                if (additional?["perm"] is not null)
                {
                    if (additional["perm"] is not JsonObject permission ||
                        !NativeBool(permission, "write", out canWrite) ||
                        permission["delete"] is not null &&
                        !NativeBool(permission, "delete", out canDelete))
                        throw new InvalidDataException("file.mutation.invalid-permission");
                }
                items.Add(new FileItem(itemPath, name, isDir, size, modified, null, canWrite, canDelete));
            }
            offset = nextOffset;
            if (offset >= total) break;
        }
        if (stableTotal is > FileMutationLimit ||
            (stableTotal is not null && items.Count != stableTotal))
            throw new InvalidDataException("file.mutation.truncated");
        return items;
    }

    private bool MutationCapability(string name, int version) =>
        _capabilities.TryGetValue(name, out var capability) && capability.Name == name &&
        version >= capability.MinVersion && version <= capability.MaxVersion &&
        capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) &&
        SafeMutationCapabilityPath(capability.Path);

    private static bool SafeMutationCapabilityPath(string path) =>
        !string.IsNullOrWhiteSpace(path) && !Uri.TryCreate(path, UriKind.Absolute, out _) &&
        !path.StartsWith("//") && !path.StartsWith('\\') && !path.Contains('\\') &&
        !path.Contains('%') && !path.Contains("//") && !path.Contains('?') && !path.Contains('#') &&
        !path.TrimStart('/').Split('/').Any(segment => segment is "." or "..");

    private static bool ValidMutationItemName(string value) =>
        !string.IsNullOrWhiteSpace(value) && value == value.Trim() && value is not ("." or "..") &&
        value.IndexOfAny(['/', '\\', '\r', '\n', '\0']) < 0;
    private static bool ValidMutationDirectory(string value) => ValidMutationObjectPath(value) && value != "/";
    private static bool ValidMutationObjectPath(string value) =>
        !string.IsNullOrWhiteSpace(value) && value.StartsWith('/') && value != "/" &&
        !value.EndsWith('/') && !value.Contains("//") && !value.Contains('\\') &&
        value.IndexOfAny(['\r', '\n', '\0']) < 0 && !value.Split('/').Any(x => x is "." or "..");
    private static string MutationParent(string path) => path[..path.LastIndexOf('/')];
    private static string JoinMutationPath(string parent, string name) => $"{parent}/{name}";
    private static int NativeInt(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<int>(out var result) && result >= 0
            ? result : throw new InvalidDataException("file.mutation.invalid-integer");
    private static string? NativeString(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<string>(out var result) &&
        !string.IsNullOrEmpty(result) ? result : null;
    private static bool NativeBool(JsonObject item, string key, out bool result)
    { result = false; return item[key] is JsonValue value && value.TryGetValue<bool>(out result); }
    private static bool NativeLong(JsonObject item, string key, out long result)
    { result = 0; return item[key] is JsonValue value && value.TryGetValue<long>(out result); }
    private static DateTimeOffset? OptionalMutationTime(JsonObject item, JsonObject? additional)
    {
        JsonNode? node = item["mtime"];
        if (node is null && additional?["time"] is JsonObject time) node = time["mtime"];
        if (node is null) return null;
        if (node is not JsonValue value || !value.TryGetValue<long>(out var seconds) || seconds < 0)
            throw new InvalidDataException("file.mutation.invalid-time");
        return DateTimeOffset.FromUnixTimeSeconds(seconds);
    }
    private static bool IsMutationReadFailure(Exception error) =>
        error is DsmException or JsonException or InvalidDataException or OverflowException or
            InvalidOperationException or ArgumentException;
    private static bool IsMutationAuthenticationFailure(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401;

    private static FileMutationOutcome PermissionOutcome(string operation,
        FilePermissionTransportResult permission) => MutationOutcome(operation,
            permission.Status switch
            {
                FilePermissionTransportStatus.Denied => MutationResultStatus.PermissionDenied,
                FilePermissionTransportStatus.Cancelled => MutationResultStatus.CancelledBeforeSubmission,
                FilePermissionTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                _ => MutationResultStatus.ConfirmedFailure,
            }, false, false, permission.ErrorCategory, permission.DiagnosticTag);

    private static FileMutationOutcome MutationOutcome(string operation,
        MutationResultStatus status, bool submitted, bool refresh,
        MutationErrorCategory? category, string? tag, FileItem? item = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = success == 0 && unknown == 0 &&
            status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new(new MutationResult(1, status, operation, submitted, refresh,
            new MutationResultCounts(success, failed, unknown), category, diagnosticTag: tag), item);
    }

    private sealed record FileMutationReview(
        string Operation,
        string Parent,
        string NewPath,
        string? OldPath,
        bool ExpectedDirectory,
        HashSet<string> Targets)
    {
        public string Key { get; } = $"{Operation}|{OldPath}|{NewPath}";
    }

    private readonly record struct MutationReservation(
        bool Acquired,
        FileMutationReview? PendingReview);

    private sealed class FileMutationSessionState
    {
        public object Sync { get; } = new();
        public HashSet<string> ActiveTargets { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, FileMutationReview> Reviews { get; } =
            new(StringComparer.Ordinal);
    }

    private sealed class FileMutationApiState
    {
        public object Sync { get; } = new();
        public Dictionary<DsmSession, FileMutationSessionState> Sessions { get; } = [];
    }
}
