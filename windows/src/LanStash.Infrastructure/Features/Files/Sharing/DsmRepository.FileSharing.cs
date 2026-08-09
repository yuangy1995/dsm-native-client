using System.Globalization;
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
    private readonly object _shareClaimSync = new();
    private readonly HashSet<string> _activeSharePaths = new(StringComparer.Ordinal);

    public FileShareLinkAvailability ShareLinkAvailability =>
        HasFileShareContract
            ? new(FileShareLinkAvailabilityStatus.Available, SharingVersion)
            : new(FileShareLinkAvailabilityStatus.Unavailable);

    public async Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
        CreateFileShareLinkRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var target = request.Target;
        var password = request.Password is { Length: 0 } ? null : request.Password;
        if (!ValidTarget(target) ||
            password is not null && new StringInfo(password).LengthInTextElements > 16)
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

                var submitted = SubmittedShareIdentity(transport);
                using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                try
                {
                    var readback = await LoadAllShareLinksAsync(verification.Token).ConfigureAwait(false);
                    var oldIds = existing.Select(link => link.Id).ToHashSet(StringComparer.Ordinal);
                    var newLinks = readback.Where(link => !oldIds.Contains(link.Id)).ToArray();
                    var candidate = submitted.Id is { } id
                        ? newLinks.SingleOrDefault(link => string.Equals(link.Id, id, StringComparison.Ordinal))
                        : submitted.AllowsMissingIdFallback
                            ? newLinks.SingleOrDefault(link =>
                                string.Equals(link.Path, target.Path, StringComparison.Ordinal))
                            : null;
                    if (candidate is not null &&
                        string.Equals(candidate.Path, target.Path, StringComparison.Ordinal) &&
                        candidate.HasPassword == (password is not null) &&
                        candidate.ExpiresOn == request.ExpiresOn)
                    {
                        return Outcome(
                            MutationResultStatus.ConfirmedSuccess,
                            submitted: true,
                            succeeded: 1,
                            diagnosticTag: transport.Status ==
                                FileShareLinkTransportStatus.CancellationRequestedAfterSubmission
                                    ? "file.share.create.confirmed-after-cancel"
                                    : "file.share.create.confirmed",
                            link: candidate);
                    }
                }
                catch (Exception error) when (
                    error is DsmException or InvalidDataException or InvalidOperationException or
                        OperationCanceledException)
                {
                }

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

    private bool HasFileShareContract =>
        HasFixedCapability(SharingApi, SharingVersion) &&
        HasFixedCapability(FileListApi, FileListVersion) &&
        _session.ProfileId == _profile.Id;

    private bool HasFixedCapability(string name, int version) =>
        _capabilities.TryGetValue(name, out var capability) &&
        string.Equals(capability.Name, name, StringComparison.Ordinal) &&
        capability.MinVersion <= version &&
        capability.MaxVersion >= version &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) &&
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
        var canRead = StrictBool(permissions, "read")
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var canWrite = StrictBool(permissions, "write")
            ?? throw new InvalidDataException("file.share.invalid-target-response");
        var canDelete = StrictBool(permissions, "delete")
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
        var expiresOn = StrictExpiry(item);
        return new FileShareLink(id, path, url, hasPassword, expiresOn);
    }

    private static SubmittedShare SubmittedShareIdentity(FileShareLinkTransportResult transport)
    {
        if (transport.Status != FileShareLinkTransportStatus.ResponseReceived)
        {
            return new(true, null);
        }
        if (transport.Data is not JsonObject data)
        {
            return new(false, null);
        }
        if (!AllowsSubmittedItem(data))
        {
            return new(false, null);
        }
        if (data.ContainsKey("links"))
        {
            if (data.ContainsKey("id") || data["links"] is not JsonArray links)
            {
                return new(false, null);
            }
            if (links.Count != 1 || links[0] is not JsonObject item || !AllowsSubmittedItem(item))
            {
                return new(false, null);
            }
            return item.String("id") is { Length: > 0 } nested
                ? new(false, nested)
                : new(true, null);
        }
        return data.String("id") is { Length: > 0 } direct
            ? new(false, direct)
            : new(false, null);
    }

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

    private static DateOnly? StrictExpiry(JsonObject item)
    {
        if (!item.ContainsKey("date_expired") || item["date_expired"] is not JsonValue value)
        {
            throw new InvalidDataException("file.share.invalid-link-expiry");
        }
        if (StrictLong(value) is { } numeric)
        {
            return numeric == 0
                ? null
                : throw new InvalidDataException("file.share.invalid-link-expiry");
        }
        if (!value.TryGetValue<string>(out var text) || string.IsNullOrEmpty(text))
        {
            throw new InvalidDataException("file.share.invalid-link-expiry");
        }
        if (text == "0")
        {
            return null;
        }
        return DateOnly.TryParseExact(
            text,
            "yyyy-MM-dd",
            CultureInfo.InvariantCulture,
            DateTimeStyles.None,
            out var parsed)
                ? parsed
                : throw new InvalidDataException("file.share.invalid-link-expiry");
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
        string.Equals(observed.Owner, target.Owner, StringComparison.Ordinal) &&
        observed.CanWrite == target.CanWrite &&
        observed.CanDelete == target.CanDelete &&
        (target.IsDirectory ||
            observed.Size == target.Size && observed.ModifiedAt == target.ModifiedAt);

    private static bool ValidTarget(FileShareLinkTarget target) =>
        target.ProfileId != Guid.Empty &&
        StrictDsmAbsolutePath(target.Path) &&
        !string.IsNullOrWhiteSpace(target.Name) &&
        (target.IsDirectory || target.Size >= 0);

    private bool TryClaimSharePath(string path)
    {
        lock (_shareClaimSync)
        {
            return _activeSharePaths.Add(path);
        }
    }

    private void ReleaseSharePath(string path)
    {
        lock (_shareClaimSync)
        {
            _activeSharePaths.Remove(path);
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
        if (string.IsNullOrEmpty(value) || !string.Equals(value, value.Trim(), StringComparison.Ordinal))
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

    private readonly record struct SubmittedShare(bool AllowsMissingIdFallback, string? Id);
}
