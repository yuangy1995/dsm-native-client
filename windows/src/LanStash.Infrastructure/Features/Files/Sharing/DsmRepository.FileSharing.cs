using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string SharingApi = "SYNO.FileStation.Sharing";
    private const string FileListApi = "SYNO.FileStation.List";
    private const int SharingVersion = 3;
    private const int FileListVersion = 2;
    private const int FileShareLinkPageSize = 500;
    private const int ShareMaximumItems = 5_000;
    private static readonly ConditionalWeakTable<IDsmApiClient, FileShareReviewRegistry>
        FileShareDeleteReviewStates = new();
    public FileShareLinkAvailability ShareLinkAvailability =>
        HasFileShareContract
            ? new(FileShareLinkAvailabilityStatus.Available, SharingVersion)
            : new(FileShareLinkAvailabilityStatus.Unavailable);

    public Task<IReadOnlyList<FileShareLink>> ListFileShareLinksAsync(
        CancellationToken cancellationToken = default) =>
        HasFileShareContract
            ? LoadAllShareLinksAsync(cancellationToken)
            : Task.FromException<IReadOnlyList<FileShareLink>>(
                new NotSupportedException("file.share.list.unsupported"));

    public async Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
        CreateFileShareLinkRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var target = request.Target;
        var password = request.Password is { Length: 0 } ? null : request.Password;
        if (!ValidTarget(target) ||
            password is not null && new StringInfo(password).LengthInTextElements > 16 ||
            request.AvailableOn > request.ExpiresOn ||
            request.FileRequest is { } configuration &&
                (!target.IsDirectory || !target.CanWrite || !configuration.UploadConfirmed ||
                    string.IsNullOrWhiteSpace(configuration.Name)))
        {
            return Outcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Validation,
                diagnosticTag: "file.share.create.invalid-input");
        }
        if (!HasFileShareContract || target.ProfileId != _profile.Id || _session.ProfileId != _profile.Id)
        {
            return Outcome(
                MutationResultStatus.Unsupported,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Unsupported,
                diagnosticTag: "file.share.create.unsupported");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return Outcome(
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "file.share.create.cancelled-before-submit");
        }
        if (!TryClaimSharePath(target.Path))
        {
            return Outcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Conflict,
                diagnosticTag: "file.share.create.duplicate-submission");
        }

        try
        {
            try
            {
                var observed = await LoadShareTargetAsync(target.Path, cancellationToken)
                    .ConfigureAwait(false);
                if (!MatchesTarget(observed, target))
                {
                    return Outcome(
                        MutationResultStatus.ConfirmedFailure,
                        submitted: false,
                        failed: 1,
                        category: MutationErrorCategory.Conflict,
                        diagnosticTag: "file.share.create.baseline-changed");
                }
                if (request.FileRequest is not null)
                {
                    await RequireFileShareAdvancedWriteAsync(cancellationToken).ConfigureAwait(false);
                    if (!observed.IsDirectory || !observed.CanWrite)
                        return Outcome(MutationResultStatus.PermissionDenied, false, failed: 1,
                            category: MutationErrorCategory.Permission);
                }
                var existing = await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();

                var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["path"] = JsonSerializer.Serialize(new[] { target.Path }),
                };
                if (password is not null)
                {
                    parameters["password"] = password;
                }
                if (request.ExpiresOn is { } expiry)
                {
                    parameters["date_expired"] = expiry.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                }

                if (request.AvailableOn is { } available)
                    parameters["date_available"] = available.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                if (request.FileRequest is { } collection)
                {
                    parameters["file_request"] = "true";
                    parameters["request_name"] = collection.Name;
                    parameters["request_info"] = collection.Message;
                }

                FileShareLinkTransportResult transport;
                try
                {
                    transport = await _api.CreateFileShareLinkAsync(
                        _profile,
                        _session,
                        FixedCapability(SharingApi, SharingVersion),
                        parameters,
                        cancellationToken).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    transport = new FileShareLinkTransportResult(
                        FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                        ErrorCategory: MutationErrorCategory.Network,
                        DiagnosticTag: "file.share.create.cancelled-after-submit");
                }
                catch
                {
                    transport = new FileShareLinkTransportResult(
                        FileShareLinkTransportStatus.SubmittedButUnverified,
                        ErrorCategory: MutationErrorCategory.Unknown,
                        DiagnosticTag: "file.share.create.transport-unverified");
                }
                if (transport.Status is FileShareLinkTransportStatus.ConfirmedFailure)
                {
                    return Outcome(
                        transport.ErrorCategory == MutationErrorCategory.Permission
                            ? MutationResultStatus.PermissionDenied
                            : MutationResultStatus.ConfirmedFailure,
                        submitted: true,
                        failed: 1,
                        category: transport.ErrorCategory,
                        diagnosticTag: transport.DiagnosticTag ?? "file.share.create.confirmed-failure");
                }
                if (transport.Status is FileShareLinkTransportStatus.CancelledBeforeSubmission or
                    FileShareLinkTransportStatus.Unsupported)
                {
                    return Outcome(
                        transport.Status == FileShareLinkTransportStatus.CancelledBeforeSubmission
                            ? MutationResultStatus.CancelledBeforeSubmission
                            : MutationResultStatus.Unsupported,
                        submitted: false,
                        failed: transport.Status == FileShareLinkTransportStatus.Unsupported ? 1 : 0,
                        category: transport.ErrorCategory,
                        diagnosticTag: transport.DiagnosticTag ?? "file.share.create.unsupported");
                }

                var submittedId = SubmittedShareIdentity(transport);
                var pending = new PendingShareCreation(target.Path, submittedId,
                    transport.Status == FileShareLinkTransportStatus.ResponseReceived,
                    existing.Select(link => link.Id).ToHashSet(StringComparer.Ordinal),
                    password is not null, request.AvailableOn, request.ExpiresOn, request.FileRequest);
                StoreShareCreationReview(pending);
                using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                var reviewed = await ReviewFileShareLinkCreationAsync(target.Path, verification.Token).ConfigureAwait(false);
                if (reviewed.Result.Status == MutationResultStatus.ConfirmedSuccess) return reviewed;

                return Outcome(
                    transport.Status == FileShareLinkTransportStatus.CancellationRequestedAfterSubmission
                        ? MutationResultStatus.CancellationRequestedAfterSubmission
                        : MutationResultStatus.SubmittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    unknown: 1,
                    category: transport.ErrorCategory ?? MutationErrorCategory.Server,
                    diagnosticTag: transport.Status == FileShareLinkTransportStatus.CancellationRequestedAfterSubmission
                        ? "file.share.create.cancelled-unverified"
                        : "file.share.create.readback-unverified");
            }
            catch (OperationCanceledException)
            {
                return Outcome(
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    diagnosticTag: "file.share.create.cancelled-before-submit");
            }
            catch (DsmException error)
            {
                return Outcome(
                    error.Code == 105
                        ? MutationResultStatus.PermissionDenied
                        : MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: error.Code == 105
                        ? MutationErrorCategory.Permission
                        : MutationErrorCategory.Server,
                    diagnosticTag: "file.share.create.preflight-failed");
            }
            catch (NotSupportedException)
            {
                return Outcome(MutationResultStatus.Unsupported, false, failed: 1,
                    category: MutationErrorCategory.Unsupported);
            }
            catch (InvalidDataException)
            {
                return Outcome(
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: MutationErrorCategory.Server,
                    diagnosticTag: "file.share.create.preflight-invalid");
            }
        }
        finally
        {
            ReleaseSharePath(target.Path);
        }
    }

    public async Task<FileShareLinkDeletionOutcome> DeleteFileShareLinkAsync(
        DeleteFileShareLinkRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var link = request.Link;
        if (!ValidShareLink(link))
        {
            return DeleteOutcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Validation,
                diagnosticTag: "file.share.delete.invalid-input",
                link: link);
        }
        if (!HasFileShareContract)
        {
            return DeleteOutcome(
                MutationResultStatus.Unsupported,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Unsupported,
                diagnosticTag: "file.share.delete.unsupported",
                link: link);
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return DeleteOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                diagnosticTag: "file.share.delete.cancelled-before-submit",
                link: link);
        }
        if (!TryClaimShareDeletion(link, out var pendingReview))
        {
            return DeleteOutcome(
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                failed: 1,
                category: MutationErrorCategory.Conflict,
                diagnosticTag: "file.share.delete.duplicate-submission",
                link: link);
        }

        try
        {
            if (pendingReview is not null)
            {
                return await ReviewShareDeletionAsync(pendingReview).ConfigureAwait(false);
            }

            IReadOnlyList<FileShareLink> baseline;
            try
            {
                baseline = await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return DeleteOutcome(
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    diagnosticTag: "file.share.delete.cancelled-before-submit",
                    link: link);
            }
            catch (DsmException error)
            {
                return DeleteOutcome(
                    error.Code == 105
                        ? MutationResultStatus.PermissionDenied
                        : MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: error.Code == 105
                        ? MutationErrorCategory.Permission
                        : MutationErrorCategory.Server,
                    diagnosticTag: "file.share.delete.preflight-failed",
                    link: link);
            }
            catch (Exception error) when (
                error is InvalidDataException or InvalidOperationException or OverflowException)
            {
                return DeleteOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: MutationErrorCategory.Server,
                    diagnosticTag: "file.share.delete.preflight-invalid",
                    link: link);
            }

            var observed = baseline.SingleOrDefault(item =>
                string.Equals(item.Id, link.Id, StringComparison.Ordinal));
            if (observed is null)
            {
                RemoveShareDeleteReview(link.Id);
                return DeleteOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: MutationErrorCategory.Conflict,
                    diagnosticTag: "file.share.delete.already-absent",
                    link: link);
            }
            if (!ExactShareLink(observed, link))
            {
                return DeleteOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    failed: 1,
                    category: MutationErrorCategory.Conflict,
                    diagnosticTag: "file.share.delete.baseline-changed",
                    link: link);
            }

            FileShareLinkTransportResult transport;
            try
            {
                transport = await _api.DeleteFileShareLinkAsync(
                    _profile,
                    _session,
                    FixedCapability(SharingApi, SharingVersion),
                    link.Id,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                transport = new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "file.share.delete.cancelled-after-submit");
            }
            catch
            {
                transport = new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Unknown,
                    DiagnosticTag: "file.share.delete.transport-unverified");
            }

            if (transport.Status is FileShareLinkTransportStatus.CancelledBeforeSubmission or
                FileShareLinkTransportStatus.Unsupported)
            {
                return DeleteOutcome(
                    transport.Status == FileShareLinkTransportStatus.CancelledBeforeSubmission
                        ? MutationResultStatus.CancelledBeforeSubmission
                        : MutationResultStatus.Unsupported,
                    submitted: false,
                    failed: transport.Status == FileShareLinkTransportStatus.Unsupported ? 1 : 0,
                    category: transport.ErrorCategory,
                    diagnosticTag: transport.DiagnosticTag,
                    link: link);
            }
            return await FinishShareDeletionAsync(link, transport).ConfigureAwait(false);
        }
        finally
        {
            ReleaseShareDeletion(link);
        }
    }

    private async Task<FileShareLinkDeletionOutcome> FinishShareDeletionAsync(
        FileShareLink link,
        FileShareLinkTransportResult transport)
    {
        try
        {
            var current = await LoadAllShareLinksAsync(CancellationToken.None).ConfigureAwait(false);
            if (transport.Status == FileShareLinkTransportStatus.ResponseReceived &&
                !current.Any(item => string.Equals(item.Id, link.Id, StringComparison.Ordinal)))
            {
                RemoveShareDeleteReview(link.Id);
                return DeleteOutcome(
                    MutationResultStatus.ConfirmedSuccess,
                    submitted: true,
                    succeeded: 1,
                    diagnosticTag: transport.Status ==
                        FileShareLinkTransportStatus.CancellationRequestedAfterSubmission
                            ? "file.share.delete.confirmed-after-cancel"
                            : "file.share.delete.confirmed",
                    link: link);
            }
        }
        catch (Exception error) when (
            error is DsmException or InvalidDataException or InvalidOperationException or
                OverflowException)
        {
        }

        if (transport.Status == FileShareLinkTransportStatus.ConfirmedFailure)
        {
            RemoveShareDeleteReview(link.Id);
            return DeleteOutcome(
                transport.ErrorCategory == MutationErrorCategory.Permission
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                submitted: true,
                failed: 1,
                category: transport.ErrorCategory,
                diagnosticTag: transport.DiagnosticTag,
                link: link);
        }

        StoreShareDeleteReview(link, transport.Status == FileShareLinkTransportStatus.ResponseReceived);
        return DeleteOutcome(
            transport.Status == FileShareLinkTransportStatus.CancellationRequestedAfterSubmission
                ? MutationResultStatus.CancellationRequestedAfterSubmission
                : MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            category: transport.ErrorCategory ?? MutationErrorCategory.Server,
            diagnosticTag: transport.DiagnosticTag ?? "file.share.delete.readback-unverified",
            link: link);
    }

    private async Task<FileShareLinkDeletionOutcome> ReviewShareDeletionAsync(PendingShareDeletion pending)
    {
        var link = pending.Link;
        try
        {
            var current = await LoadAllShareLinksAsync(CancellationToken.None).ConfigureAwait(false);
            if (pending.Accepted && !current.Any(item => string.Equals(item.Id, link.Id, StringComparison.Ordinal)))
            {
                RemoveShareDeleteReview(link.Id);
                return DeleteOutcome(
                    MutationResultStatus.ConfirmedSuccess,
                    submitted: true,
                    succeeded: 1,
                    diagnosticTag: "file.share.delete.review-confirmed",
                    link: link);
            }
        }
        catch (Exception error) when (
            error is DsmException or InvalidDataException or InvalidOperationException or
                OverflowException)
        {
        }
        return DeleteOutcome(
            MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            unknown: 1,
            category: MutationErrorCategory.Unknown,
            diagnosticTag: "file.share.delete.review-pending",
            link: link);
    }

    private bool HasFileShareContract =>
        HasFixedCapability(SharingApi, SharingVersion) &&
        HasFixedCapability(FileListApi, FileListVersion) &&
        _session.ProfileId == _profile.Id;

    private bool HasFixedCapability(string name, int version) =>
        _capabilities.TryGetValue(name, out var capability) &&
        string.Equals(capability.Name, name, StringComparison.Ordinal) &&
        capability.MinVersion <= version &&
        capability.MaxVersion >= version &&
        (string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(capability.RequestFormat, "JSON", StringComparison.OrdinalIgnoreCase)) &&
        SafeCapabilityPath(capability.Path);

    private ApiCapability FixedCapability(string name, int version) =>
        _capabilities[name] with { MinVersion = version, MaxVersion = version };

    private Task<JsonObject> CallShareReadAsync(
        string api,
        int version,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken) =>
        _api.CallAsync(
            _profile,
            _session,
            FixedCapability(api, version),
            method,
            parameters,
            cancellationToken);

    private async Task<ObservedShareTarget> LoadShareTargetAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var data = await CallShareReadAsync(
            FileListApi,
            FileListVersion,
            "getinfo",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["path"] = JsonSerializer.Serialize(new[] { path }),
                ["additional"] = "[\"size\",\"owner\",\"time\",\"perm\"]",
            },
            cancellationToken).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } files || files[0] is not JsonObject item)
        {
            throw new InvalidDataException("file.share.invalid-target-response");
        }
        var additional = item["additional"] as JsonObject
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var permissions = additional["perm"] as JsonObject
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var isDirectory = StrictBool(item, "isdir")
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var observedPath = ShareLinkRequiredString(item, "path");
        var name = ShareLinkRequiredString(item, "name");
        var owner = additional["owner"] switch
        {
            JsonObject ownerObject => ownerObject.String("user"),
            JsonValue => additional.String("owner"),
            _ => null,
        };
        var decodedPermissions = FileStationPermissions.Parse(permissions);
        var canRead = decodedPermissions.Read
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var canWrite = decodedPermissions.Write
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var canDelete = decodedPermissions.Delete
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var size = isDirectory
            ? 0
            : StrictLong(item.ContainsKey("size") ? item["size"] : additional["size"])
                ?? throw new InvalidDataException("file.share.invalid-target-response");
        DateTimeOffset? modified = isDirectory
            ? null
            : StrictEpoch(
                additional["time"] is JsonObject time && time.ContainsKey("mtime")
                    ? time["mtime"]
                    : item["mtime"])
                ?? throw new InvalidDataException("file.share.invalid-target-response");
        return new ObservedShareTarget(
            observedPath,
            name,
            isDirectory,
            size,
            modified,
            owner,
            canRead,
            canWrite,
            canDelete);
    }

    private async Task<IReadOnlyList<FileShareLink>> LoadAllShareLinksAsync(
        CancellationToken cancellationToken)
    {
        var links = new List<FileShareLink>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        int? expectedTotal = null;
        for (var offset = 0; ;)
        {
            var data = await CallShareReadAsync(
                SharingApi,
                SharingVersion,
                "list",
                new Dictionary<string, string>(StringComparer.Ordinal)
                {
                    ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                    ["limit"] = FileShareLinkPageSize.ToString(CultureInfo.InvariantCulture),
                },
                cancellationToken).ConfigureAwait(false);
            var total = StrictInt(data, "total")
                ?? throw new InvalidDataException("file.share.invalid-list-response");
            var responseOffset = StrictInt(data, "offset")
                ?? throw new InvalidDataException("file.share.invalid-list-response");
            if (responseOffset < 0 || responseOffset != offset ||
                total < 0 || total > ShareMaximumItems ||
                expectedTotal is { } priorTotal && priorTotal != total ||
                data["links"] is not JsonArray page)
            {
                throw new InvalidDataException("file.share.invalid-list-response");
            }
            expectedTotal ??= total;
            if (page.Count > FileShareLinkPageSize || page.Count > total - offset ||
                page.Count == 0 && offset < total)
            {
                throw new InvalidDataException("file.share.list-did-not-advance");
            }
            foreach (var node in page)
            {
                if (node is not JsonObject item)
                {
                    throw new InvalidDataException("file.share.invalid-list-response");
                }
                var link = ParseShareLink(item);
                if (!ids.Add(link.Id))
                {
                    throw new InvalidDataException("file.share.duplicate-link-id");
                }
                links.Add(link);
            }
            offset = checked(offset + page.Count);
            if (offset >= total)
            {
                if (offset != total)
                {
                    throw new InvalidDataException("file.share.invalid-list-total");
                }
                return links;
            }
        }
    }

    private static FileShareLink ParseShareLink(JsonObject item)
    {
        var id = ShareLinkRequiredString(item, "id");
        var path = ShareLinkRequiredString(item, "path");
        if (!StrictDsmAbsolutePath(path))
        {
            throw new InvalidDataException("file.share.invalid-link-path");
        }
        var urlText = ShareLinkRequiredString(item, "url");
        if (!Uri.TryCreate(urlText, UriKind.Absolute, out var url) ||
            !string.Equals(url.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(url.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrEmpty(url.Host) ||
            !string.IsNullOrEmpty(url.UserInfo))
        {
            throw new InvalidDataException("file.share.invalid-link-url");
        }
        var hasPassword = StrictBool(item, "has_password")
            ?? throw new InvalidDataException("file.share.invalid-link-password-state");
        var expiry = ParseShareDate(item, "date_expired", required: true);
        var available = ParseShareDate(item, "date_available", required: false);
        return new FileShareLink(id, path, url, hasPassword, expiry.Date)
        {
            AvailableOn = available.Date,
            AvailabilityDateKnown = item.ContainsKey("date_available"),
            RawAvailableDate = available.Raw,
            RawExpiryDate = expiry.Raw,
            Advanced = ParseAdvancedShareDetails(item),
        };
    }

    private static string? SubmittedShareIdentity(FileShareLinkTransportResult transport)
    {
        if (transport.Status != FileShareLinkTransportStatus.ResponseReceived ||
            transport.Data is not JsonObject data || !AllowsSubmittedItem(data)) return null;
        if (data.ContainsKey("links"))
        {
            if (data.ContainsKey("id") || data["links"] is not JsonArray { Count: 1 } links ||
                links[0] is not JsonObject item || !AllowsSubmittedItem(item)) return null;
            return ShareReceiptId(item);
        }
        return ShareReceiptId(data);
    }

    private static string? ShareReceiptId(JsonObject data) =>
        data["id"] is JsonValue value && value.TryGetValue<string>(out var id) &&
            !string.IsNullOrWhiteSpace(id) && id == id.Trim() ? id : null;

    private static bool AllowsSubmittedItem(JsonObject item) =>
        !item.ContainsKey("error") || StrictInt(item, "error") == 0;

    private static int? StrictInt(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<int>(out var result)
            ? result
            : null;

    private static bool? StrictBool(JsonObject item, string key) =>
        item[key] is JsonValue value && value.TryGetValue<bool>(out var result)
            ? result
            : null;

    private static long? StrictLong(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<long>(out var longValue))
        {
            return longValue;
        }
        return value.TryGetValue<int>(out var intValue) ? intValue : null;
    }

    private static DateTimeOffset? StrictEpoch(JsonNode? node)
    {
        var seconds = StrictLong(node);
        if (seconds is null)
        {
            return null;
        }
        try
        {
            return DateTimeOffset.FromUnixTimeSeconds(seconds.Value);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static bool StrictDsmAbsolutePath(string path) =>
        path.Length > 1 &&
        path.StartsWith('/') &&
        !path.EndsWith('/') &&
        !path.Contains("//", StringComparison.Ordinal) &&
        !path.Contains('\\') &&
        !path.Split('/').Any(component => component is "." or "..");

    private static bool MatchesTarget(ObservedShareTarget observed, FileShareLinkTarget target) =>
        observed.CanRead &&
        string.Equals(observed.Path, target.Path, StringComparison.Ordinal) &&
        string.Equals(observed.Name, target.Name, StringComparison.Ordinal) &&
        observed.IsDirectory == target.IsDirectory &&
        (target.Baseline == FileShareLinkTargetBaseline.PhotoMedia ||
            string.Equals(observed.Owner, target.Owner, StringComparison.Ordinal) &&
            observed.CanWrite == target.CanWrite &&
            observed.CanDelete == target.CanDelete) &&
        (target.IsDirectory ||
            observed.Size == target.Size && observed.ModifiedAt == target.ModifiedAt);

    private static bool ExactShareLink(FileShareLink observed, FileShareLink frozen) =>
        string.Equals(observed.Id, frozen.Id, StringComparison.Ordinal) &&
        string.Equals(observed.Path, frozen.Path, StringComparison.Ordinal) &&
        observed.Url == frozen.Url && observed.HasPassword == frozen.HasPassword &&
        observed.ExpiresOn == frozen.ExpiresOn && observed.AvailableOn == frozen.AvailableOn &&
        observed.AvailabilityDateKnown == frozen.AvailabilityDateKnown &&
        observed.RawAvailableDate == frozen.RawAvailableDate && observed.RawExpiryDate == frozen.RawExpiryDate &&
        ExactAdvancedShareDetails(observed.Advanced, frozen.Advanced);

    private static bool ValidShareLink(FileShareLink link) =>
        !string.IsNullOrWhiteSpace(link.Id) && link.Id.Length <= 512 &&
        string.Equals(link.Id, link.Id.Trim(), StringComparison.Ordinal) &&
        StrictDsmAbsolutePath(link.Path) &&
        link.Url.IsAbsoluteUri &&
        (link.Url.Scheme == Uri.UriSchemeHttp || link.Url.Scheme == Uri.UriSchemeHttps) &&
        !string.IsNullOrEmpty(link.Url.Host) && string.IsNullOrEmpty(link.Url.UserInfo);

    private static bool ValidTarget(FileShareLinkTarget target) =>
        target.ProfileId != Guid.Empty &&
        StrictDsmAbsolutePath(target.Path) &&
        !string.IsNullOrWhiteSpace(target.Name) &&
        (target.IsDirectory || target.Size >= 0) &&
        (target.Baseline == FileShareLinkTargetBaseline.FileBrowser ||
            target is
            {
                Baseline: FileShareLinkTargetBaseline.PhotoMedia,
                IsDirectory: false,
                Owner: null,
                CanWrite: false,
                CanDelete: false,
            });

    private bool TryClaimSharePath(string path)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            var key = (_profile.Id, path);
            return !state.ActiveDeletePaths.Contains(key) &&
                !state.Reviews.Any(item =>
                    item.Key.ProfileId == _profile.Id &&
                    string.Equals(item.Value.Link.Path, path, StringComparison.Ordinal)) &&
                !state.Creations.ContainsKey(key) &&
                !state.Edits.Any(item => item.Key.ProfileId == _profile.Id && item.Value.Request.Link.Path == path) &&
                state.ActiveSharePaths.Add(key);
        }
    }

    private bool TryClaimShareDeletion(FileShareLink link, out PendingShareDeletion? pendingReview)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            pendingReview = null;
            var idKey = (_profile.Id, link.Id);
            var pathKey = (_profile.Id, link.Path);
            if (state.Creations.ContainsKey(pathKey) ||
                state.Edits.Any(item => item.Key.ProfileId == _profile.Id && item.Value.Request.Link.Path == link.Path) ||
                state.ActiveSharePaths.Contains(pathKey) ||
                state.ActiveDeleteIds.Contains(idKey) ||
                state.ActiveDeletePaths.Contains(pathKey))
            {
                return false;
            }
            if (state.Reviews.TryGetValue(idKey, out var pending))
            {
                if (!ExactShareLink(pending.Link, link))
                {
                    return false;
                }
                pendingReview = pending;
            }
            else if (state.Reviews.Any(item =>
                item.Key.ProfileId == _profile.Id &&
                string.Equals(item.Value.Link.Path, link.Path, StringComparison.Ordinal)))
            {
                return false;
            }
            state.ActiveDeleteIds.Add(idKey);
            state.ActiveDeletePaths.Add(pathKey);
            return true;
        }
    }

    private void StoreShareDeleteReview(FileShareLink link, bool accepted)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            state.Reviews[(_profile.Id, link.Id)] = new(link, accepted);
        }
    }

    private void RemoveShareDeleteReview(string id)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            state.Reviews.Remove((_profile.Id, id));
        }
    }

    private FileShareDeleteReviewState ShareDeleteReviewState()
    {
        var registry = FileShareDeleteReviewStates.GetValue(_api, static _ => new());
        // 配置编号不单独代表账号或 NAS；改账号/地址后不能读取或推进旧目标的结果。
        var owner = (_profile.Id, _profile.Username, _profile.Host, _profile.Port);
        lock (registry.Sync)
        {
            if (!registry.Workspaces.TryGetValue(owner, out var state))
                registry.Workspaces.Add(owner, state = new());
            return state;
        }
    }

    private void ReleaseShareDeletion(FileShareLink link)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            state.ActiveDeleteIds.Remove((_profile.Id, link.Id));
            state.ActiveDeletePaths.Remove((_profile.Id, link.Path));
        }
    }

    private void ReleaseSharePath(string path)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync)
        {
            state.ActiveSharePaths.Remove((_profile.Id, path));
        }
    }

    private static bool SafeCapabilityPath(string path) =>
        !string.IsNullOrWhiteSpace(path) &&
        !Uri.TryCreate(path, UriKind.Absolute, out _) &&
        !path.StartsWith("//", StringComparison.Ordinal) &&
        !path.StartsWith('\\') &&
        !path.Contains('\\') &&
        !path.Contains("..", StringComparison.Ordinal) &&
        !path.Contains('?') &&
        !path.Contains('#');

    private static string ShareLinkRequiredString(JsonObject item, string key)
    {
        var value = item.String(key);
        if (string.IsNullOrEmpty(value) || value.Contains('\0') ||
            key is not ("path" or "name") && !string.Equals(value, value.Trim(), StringComparison.Ordinal))
        {
            throw new InvalidDataException("file.share.invalid-string-field");
        }
        return value;
    }

    private static FileShareLinkCreationOutcome Outcome(
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh = false,
        int succeeded = 0,
        int failed = 0,
        int unknown = 0,
        MutationErrorCategory? category = null,
        string? diagnosticTag = null,
        FileShareLink? link = null) =>
        new(
            new MutationResult(
                1,
                status,
                "shareLinkCreate",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                category,
                diagnosticTag: diagnosticTag),
            link);

    private static FileShareLinkDeletionOutcome DeleteOutcome(
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh = false,
        int succeeded = 0,
        int failed = 0,
        int unknown = 0,
        MutationErrorCategory? category = null,
        string? diagnosticTag = null,
        FileShareLink? link = null) =>
        new(
            new MutationResult(
                1,
                status,
                "shareLinkDelete",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                category,
                diagnosticTag: diagnosticTag),
            link);

    private sealed record ObservedShareTarget(
        string Path,
        string Name,
        bool IsDirectory,
        long Size,
        DateTimeOffset? ModifiedAt,
        string? Owner,
        bool CanRead,
        bool CanWrite,
        bool CanDelete);

    private sealed record PendingShareDeletion(FileShareLink Link, bool Accepted);

    private sealed class FileShareReviewRegistry
    {
        public object Sync { get; } = new();
        public Dictionary<(Guid ProfileId, string Username, string Host, int? Port), FileShareDeleteReviewState> Workspaces { get; } = [];
    }

    private sealed class FileShareDeleteReviewState
    {
        public object Sync { get; } = new();
        public Dictionary<(Guid ProfileId, string Id), PendingShareDeletion> Reviews { get; } = [];
        public Dictionary<(Guid ProfileId, string Path), PendingShareCreation> Creations { get; } = [];
        public Dictionary<(Guid ProfileId, string Id), PendingShareEdit> Edits { get; } = [];
        public HashSet<(Guid ProfileId, string Path)> ActiveSharePaths { get; } = [];
        public HashSet<(Guid ProfileId, string Id)> ActiveDeleteIds { get; } = [];
        public HashSet<(Guid ProfileId, string Path)> ActiveDeletePaths { get; } = [];
    }
}
