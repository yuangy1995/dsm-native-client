using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string FileSharePrincipalsApi = "SYNO.FileStation.UserGrp";
    private const string FileDesktopAccessApi = "SYNO.Core.Desktop.Initdata";

    // 内部扩展只读取绑定会话的文件应用授权，不附加系统管理权限或固件白名单。
    private async Task RequireFileShareAdvancedWriteAsync(CancellationToken cancellationToken)
    {
        var access = await LoadFileAdvancedAccessAsync(cancellationToken).ConfigureAwait(false);
        if (!access.Allowed)
            throw new DsmException("file.share.access.denied", "file.share.access.refresh", code: 105);
    }

    private async Task<(bool Allowed, bool Administrator)> LoadFileAdvancedAccessAsync(CancellationToken cancellationToken)
    {
        if (!HasFixedCapability(FileDesktopAccessApi, 1))
            throw new NotSupportedException("file.share.access.unsupported");
        var data = await _api.CallReadJsonObjectAsync(_profile, _session,
            FixedCapability(FileDesktopAccessApi, 1), 1, "get_user_service",
            new Dictionary<string, string> { ["launch_app"] = "null" }, cancellationToken).ConfigureAwait(false);
        var loggedIn = data["Session"] is not JsonObject session || StrictBool(session, "isLogined") != false;
        return (loggedIn && data["AppPrivilege"] is JsonObject privileges &&
            StrictBool(privileges, "SYNO.SDS.App.FileStation3.Instance") == true,
            loggedIn && data["Session"] is JsonObject role && StrictBool(role, "is_admin") == true);
    }

    public async Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(
        string prefix, CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId || string.IsNullOrEmpty(_session.Sid) || !HasFixedCapability(FileSharePrincipalsApi, 1))
            throw new NotSupportedException("file.share.members.unsupported");
        ArgumentNullException.ThrowIfNull(prefix);
        var items = new List<FileSharePrincipal>();
        var seen = new HashSet<FileSharePrincipal>();
        int? expectedTotal = null;
        for (var offset = 0; ;)
        {
            var data = await CallShareReadAsync(FileSharePrincipalsApi, 1, "list_all",
                new Dictionary<string, string>
                {
                    ["type"] = ShareParameterString(FileSharePrincipalsApi, "all"),
                    ["prefix"] = ShareParameterString(FileSharePrincipalsApi, prefix),
                    ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                    ["limit"] = "200",
                }, cancellationToken).ConfigureAwait(false);
            if (StrictInt(data, "total") is not { } total || total < offset || total > 100_000 ||
                expectedTotal is { } previous && previous != total || data["owners"] is not JsonArray page ||
                page.Count > 200 || page.Count > total - offset || page.Count == 0 && offset != total)
                throw new InvalidDataException("file.share.members.invalid-page");
            expectedTotal ??= total;
            foreach (var node in page)
            {
                if (node is not JsonObject row || row["name"] is not JsonValue nameValue ||
                    !nameValue.TryGetValue<string>(out var name) || string.IsNullOrEmpty(name) ||
                    row["type"] is not JsonValue typeValue || !typeValue.TryGetValue<string>(out var type) ||
                    type is not ("user" or "group"))
                    throw new InvalidDataException("file.share.members.invalid-member");
                var member = new FileSharePrincipal(name,
                    type == "user" ? FileSharePrincipalKind.User : FileSharePrincipalKind.Group);
                if (!seen.Add(member)) throw new InvalidDataException("file.share.members.duplicate");
                items.Add(member);
            }
            offset += page.Count;
            if (offset == total) return items;
        }
    }

    public async Task<FileShareLinkEditOutcome> EditFileShareLinkAsync(
        EditFileShareLinkRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        request = FreezeShareEdit(request);
        if (!ValidShareEdit(request))
            return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Validation);
        if (!HasFileShareContract)
            return ShareEditOutcome(MutationResultStatus.Unsupported, false, MutationErrorCategory.Unsupported);
        if (cancellationToken.IsCancellationRequested)
            return ShareEditOutcome(MutationResultStatus.CancelledBeforeSubmission, false);
        if (!TryClaimSharePath(request.Link.Path))
            return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
        try
        {
            var parameters = new Dictionary<string, string>
            {
                ["id"] = JsonSerializer.Serialize(new[] { request.Link.Id }),
            };
            try
            {
                if (request.Advanced is not null || request.Link.Advanced?.IsFileRequest == true)
                    await RequireFileShareAdvancedWriteAsync(cancellationToken).ConfigureAwait(false);
                var observed = (await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false))
                    .SingleOrDefault(link => link.Id == request.Link.Id);
                if (observed is null || !ExactShareLink(observed, request.Link))
                    return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
                if (!observed.AvailabilityDateKnown)
                    return ShareEditOutcome(MutationResultStatus.Unsupported, false, MutationErrorCategory.Unsupported);
                if (request.Link.Advanced?.IsFileRequest == true)
                {
                    var target = await LoadShareTargetAsync(request.Link.Path, cancellationToken).ConfigureAwait(false);
                    if (!target.IsDirectory || !target.CanRead || !target.CanWrite)
                        return ShareEditOutcome(MutationResultStatus.PermissionDenied, false, MutationErrorCategory.Permission);
                    parameters["file_request"] = "true";
                }
                AddShareEditDate(parameters, "date_available", request.AvailableDateIntent, request.AvailableOn);
                AddShareEditDate(parameters, "date_expired", request.ExpiryDateIntent, request.ExpiresOn);
                if (request.PasswordIntent != FileShareValueIntent.Keep)
                    parameters["password"] = ShareParameterString(SharingApi,
                        request.PasswordIntent == FileShareValueIntent.Clear ? "" : request.Password!);
                if (request.Advanced is { } change)
                {
                    await AddAdvancedShareParametersAsync(parameters, request.Link, change, cancellationToken)
                        .ConfigureAwait(false);
                    // 名单分页可能耗时；提交前必须再核对原分享快照。
                    var latest = (await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false))
                        .SingleOrDefault(link => link.Id == request.Link.Id);
                    if (latest is null || !ExactShareLink(latest, request.Link))
                        return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
                }
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException)
            {
                return ShareEditOutcome(MutationResultStatus.CancelledBeforeSubmission, false);
            }
            catch (NotSupportedException)
            {
                return ShareEditOutcome(MutationResultStatus.Unsupported, false, MutationErrorCategory.Unsupported);
            }
            catch (DsmException error)
            {
                return ShareEditOutcome(error.Code == 105 ? MutationResultStatus.PermissionDenied :
                    MutationResultStatus.ConfirmedFailure, false,
                    error.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server);
            }
            catch (InvalidDataException)
            {
                return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
            }

            // 只保留非秘密预期值。任何只读恢复都不能重建写请求或重发密码。
            var pending = new PendingShareEdit(request with { Password = null });
            StoreShareEditReview(pending);
            try
            {
                var response = await _api.CallAsync(_profile, _session, FixedCapability(SharingApi, 3),
                    "edit", parameters, cancellationToken).ConfigureAwait(false);
                pending.Accepted = AllowsSubmittedItem(response);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                RemoveShareEditReview(request.Link.Id);
                return ShareEditOutcome(error.Code == 105 ? MutationResultStatus.PermissionDenied :
                    MutationResultStatus.ConfirmedFailure, true,
                    error.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server);
            }
            catch (Exception error) when (error is DsmException or OperationCanceledException or
                HttpRequestException or IOException or InvalidOperationException)
            {
                // 提交边界之后无法确定结果时，只能读回原编号。
            }
            pending.Ready = true;
            using var verification = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var result = await ReviewFileShareLinkEditAsync(request.Link.Id, verification.Token).ConfigureAwait(false);
            return cancellationToken.IsCancellationRequested && result.Result.Status != MutationResultStatus.ConfirmedSuccess
                ? ShareEditOutcome(MutationResultStatus.CancellationRequestedAfterSubmission, true)
                : result;
        }
        finally
        {
            ReleaseSharePath(request.Link.Path);
        }
    }

    public async Task<FileShareLinkEditOutcome> ReviewFileShareLinkEditAsync(
        string id, CancellationToken cancellationToken = default)
    {
        var state = ShareDeleteReviewState();
        PendingShareEdit? pending;
        lock (state.Sync) state.Edits.TryGetValue((_profile.Id, id), out pending);
        if (pending is null)
            return ShareEditOutcome(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
        try
        {
            var current = (await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false))
                .SingleOrDefault(link => link.Id == id);
            if (pending.Ready && current is not null && ShareEditMatches(pending, current))
            {
                RemoveShareEditReview(id);
                return ShareEditOutcome(MutationResultStatus.ConfirmedSuccess, true, link: current);
            }
        }
        catch (Exception error) when (error is DsmException or InvalidDataException or
            InvalidOperationException or OperationCanceledException or OverflowException) { }
        return ShareEditOutcome(MutationResultStatus.SubmittedButUnverified, true);
    }

    public async Task<FileShareLinkCreationOutcome> ReviewFileShareLinkCreationAsync(
        string path, CancellationToken cancellationToken = default)
    {
        var state = ShareDeleteReviewState();
        PendingShareCreation? pending;
        lock (state.Sync) state.Creations.TryGetValue((_profile.Id, path), out pending);
        if (pending is null)
            return Outcome(MutationResultStatus.ConfirmedFailure, false, failed: 1,
                category: MutationErrorCategory.Conflict);
        try
        {
            var links = await LoadAllShareLinksAsync(cancellationToken).ConfigureAwait(false);
            var link = links.SingleOrDefault(item => item.Id == pending.Id);
            if (pending.Accepted && pending.Id is not null && !pending.PreviousIds.Contains(pending.Id) &&
                link is not null && link.Path == pending.Path && link.HasPassword == pending.HasPassword &&
                ShareDateMatches(link.RawExpiryDate, link.ExpiresOn, pending.ExpiresOn) &&
                (pending.AvailableOn is null || link.AvailabilityDateKnown) &&
                ShareDateMatches(link.RawAvailableDate, link.AvailableOn, pending.AvailableOn) &&
                FileRequestMatches(link, pending.FileRequest))
            {
                lock (state.Sync) state.Creations.Remove((_profile.Id, path));
                return Outcome(MutationResultStatus.ConfirmedSuccess, true, succeeded: 1, link: link);
            }
        }
        catch (Exception error) when (error is DsmException or InvalidDataException or
            InvalidOperationException or OperationCanceledException or OverflowException) { }
        return Outcome(MutationResultStatus.SubmittedButUnverified, true, requiresRefresh: true,
            unknown: 1, category: MutationErrorCategory.Unknown);
    }

    private async Task AddAdvancedShareParametersAsync(Dictionary<string, string> parameters,
        FileShareLink baseline, FileShareAdvancedChange change, CancellationToken cancellationToken)
    {
        var original = baseline.Advanced!;
        if (change.Audience == FileShareAudienceIntent.Anyone)
            parameters["protect_type"] = ShareParameterString(SharingApi, "none");
        else if (change.Audience == FileShareAudienceIntent.Principals)
        {
            foreach (var principal in change.Principals)
                if (!(await ListFileSharePrincipalsAsync(principal.Name, cancellationToken).ConfigureAwait(false))
                    .Contains(principal)) throw new InvalidDataException("file.share.members.changed");
            var users = change.Principals.Where(item => item.Kind == FileSharePrincipalKind.User)
                .Select(item => item.Name).Order(StringComparer.Ordinal).ToArray();
            var groups = change.Principals.Where(item => item.Kind == FileSharePrincipalKind.Group)
                .Select(item => item.Name).Order(StringComparer.Ordinal).ToArray();
            parameters["protect_type"] = ShareParameterString(SharingApi, "user");
            parameters["protect_users"] = JsonSerializer.Serialize(users);
            parameters["protect_groups"] = JsonSerializer.Serialize(groups);
            parameters["new_protect_users"] = JsonSerializer.Serialize(users.Except(original.Users, StringComparer.Ordinal));
            parameters["new_protect_groups"] = JsonSerializer.Serialize(groups.Except(original.Groups, StringComparer.Ordinal));
        }
        if (change.MaximumAccesses is { } maximum)
            parameters["expire_times"] = maximum.ToString(CultureInfo.InvariantCulture);
        if (change.RequestName is { } name) parameters["request_name"] = ShareParameterString(SharingApi, name);
        if (change.RequestMessage is { } message) parameters["request_info"] = ShareParameterString(SharingApi, message);
    }

    private void AddShareEditDate(Dictionary<string, string> parameters, string name,
        FileShareValueIntent intent, DateOnly? value)
    {
        if (intent != FileShareValueIntent.Keep)
            parameters[name] = ShareParameterString(SharingApi,
                intent == FileShareValueIntent.Clear ? "0" : value!.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
    }

    private string ShareParameterString(string api, string value) =>
        _capabilities[api].RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
            ? JsonSerializer.Serialize(value) : value;

    private static EditFileShareLinkRequest FreezeShareEdit(EditFileShareLinkRequest request) => request with
    {
        Link = request.Link with { Advanced = request.Link.Advanced is { } original
            ? original with { Users = original.Users.ToArray(), Groups = original.Groups.ToArray() } : null },
        Advanced = request.Advanced is { } change ? change with { Principals = change.Principals.ToArray() } : null,
    };

    private static bool ValidShareEdit(EditFileShareLinkRequest request)
    {
        if (!ValidShareLink(request.Link) || !Enum.IsDefined(request.PasswordIntent) ||
            !Enum.IsDefined(request.AvailableDateIntent) || !Enum.IsDefined(request.ExpiryDateIntent) ||
            request.PasswordIntent == FileShareValueIntent.Replace && (string.IsNullOrEmpty(request.Password) ||
                new StringInfo(request.Password).LengthInTextElements > 16) ||
            request.PasswordIntent == FileShareValueIntent.Clear && request.Link.HasPassword && !request.PasswordRemovalConfirmed ||
            request.AvailableDateIntent == FileShareValueIntent.Replace && request.AvailableOn is null ||
            request.ExpiryDateIntent == FileShareValueIntent.Replace && request.ExpiresOn is null)
            return false;
        var from = request.AvailableDateIntent == FileShareValueIntent.Keep ? request.Link.AvailableOn :
            request.AvailableDateIntent == FileShareValueIntent.Clear ? null : request.AvailableOn;
        var until = request.ExpiryDateIntent == FileShareValueIntent.Keep ? request.Link.ExpiresOn :
            request.ExpiryDateIntent == FileShareValueIntent.Clear ? null : request.ExpiresOn;
        if (from > until) return false;
        if (request.Advanced is not { } advanced) return request.PasswordIntent != FileShareValueIntent.Keep ||
            request.AvailableDateIntent != FileShareValueIntent.Keep || request.ExpiryDateIntent != FileShareValueIntent.Keep;
        if (request.Link.Advanced is not { } original || !Enum.IsDefined(advanced.Audience) ||
            advanced.MaximumAccesses is < 0 or > 9999 ||
            advanced.Audience != FileShareAudienceIntent.Keep &&
                (!advanced.AudienceChangeConfirmed || request.PasswordIntent != FileShareValueIntent.Keep) ||
            advanced.Audience == FileShareAudienceIntent.Principals &&
                (original.IsFileRequest || advanced.Principals.Count == 0 ||
                    advanced.Principals.Distinct().Count() != advanced.Principals.Count ||
                    advanced.Principals.Any(item => string.IsNullOrEmpty(item.Name) || !Enum.IsDefined(item.Kind))) ||
            (advanced.RequestName is not null || advanced.RequestMessage is not null) && !original.IsFileRequest ||
            advanced.RequestName is not null && string.IsNullOrWhiteSpace(advanced.RequestName)) return false;
        return advanced.Audience != FileShareAudienceIntent.Keep || advanced.MaximumAccesses is not null ||
            advanced.RequestName is not null || advanced.RequestMessage is not null ||
            request.PasswordIntent != FileShareValueIntent.Keep || request.AvailableDateIntent != FileShareValueIntent.Keep ||
            request.ExpiryDateIntent != FileShareValueIntent.Keep;
    }

    private static bool ShareEditMatches(PendingShareEdit pending, FileShareLink updated)
    {
        var request = pending.Request;
        var baseline = request.Link;
        if (updated.Id != baseline.Id || updated.Path != baseline.Path || updated.Url != baseline.Url ||
            !updated.AvailabilityDateKnown ||
            !(request.AvailableDateIntent == FileShareValueIntent.Keep
                ? updated.RawAvailableDate == baseline.RawAvailableDate
                : ShareDateMatches(updated.RawAvailableDate, updated.AvailableOn,
                    request.AvailableDateIntent == FileShareValueIntent.Clear ? null : request.AvailableOn)) ||
            !(request.ExpiryDateIntent == FileShareValueIntent.Keep
                ? updated.RawExpiryDate == baseline.RawExpiryDate
                : ShareDateMatches(updated.RawExpiryDate, updated.ExpiresOn,
                    request.ExpiryDateIntent == FileShareValueIntent.Clear ? null : request.ExpiresOn))) return false;
        var hasPassword = request.PasswordIntent switch
        {
            FileShareValueIntent.Replace => pending.Accepted && updated.HasPassword,
            FileShareValueIntent.Clear => !updated.HasPassword,
            _ => updated.HasPassword == (request.Advanced is { Audience: not FileShareAudienceIntent.Keep }
                ? false : baseline.HasPassword),
        };
        if (!hasPassword) return false;
        if (baseline.Advanced is not { } old) return request.Advanced is null;
        if (updated.Advanced is not { } next || old.IsFileRequest != next.IsFileRequest ||
            old.AllowsUpload != next.AllowsUpload ||
            next.MaximumAccesses != (request.Advanced?.MaximumAccesses ?? old.MaximumAccesses) ||
            next.RequestName != (request.Advanced?.RequestName ?? old.RequestName) ||
            next.RequestMessage != (request.Advanced?.RequestMessage ?? old.RequestMessage)) return false;
        var change = request.Advanced;
        if (change?.Audience == FileShareAudienceIntent.Anyone) return next.Protection == FileShareProtection.None;
        if (change?.Audience == FileShareAudienceIntent.Principals)
            return next.Protection == FileShareProtection.Users &&
                SameShareNames(next.Users, change.Principals.Where(item => item.Kind == FileSharePrincipalKind.User).Select(item => item.Name)) &&
                SameShareNames(next.Groups, change.Principals.Where(item => item.Kind == FileSharePrincipalKind.Group).Select(item => item.Name));
        var expectedProtection = request.PasswordIntent switch
        {
            FileShareValueIntent.Replace => FileShareProtection.Password,
            FileShareValueIntent.Clear => FileShareProtection.None,
            _ => old.Protection,
        };
        return next.Protection == expectedProtection && SameShareNames(next.Users, old.Users) &&
            SameShareNames(next.Groups, old.Groups);
    }

    private static (DateOnly? Date, string? Raw) ParseShareDate(JsonObject item, string key, bool required)
    {
        if (!item.ContainsKey(key) && !required) return (null, null);
        if (item[key] is not JsonValue value) throw new InvalidDataException("file.share.invalid-date");
        if (StrictLong(value) == 0) return (null, null);
        if (!value.TryGetValue<string>(out var text)) throw new InvalidDataException("file.share.invalid-date");
        if (text is "" or "0") return (null, null);
        if (!DateTime.TryParseExact(text, ["yyyy-MM-dd", "yyyy-MM-dd HH:mm:ss"], CultureInfo.InvariantCulture,
            DateTimeStyles.None, out var date)) throw new InvalidDataException("file.share.invalid-date");
        return (DateOnly.FromDateTime(date), text);
    }

    private static bool ShareDateMatches(string? raw, DateOnly? date, DateOnly? expected) =>
        date == expected && (expected is null ? raw is null : raw is null ||
            raw == expected.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) ||
            raw == expected.Value.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + " 00:00:00");

    private static FileShareAdvancedDetails? ParseAdvancedShareDetails(JsonObject item)
    {
        if (item["protect_type"] is not JsonValue protectionValue ||
            !protectionValue.TryGetValue<string>(out var protection) || protection is not ("none" or "password" or "user") ||
            ParseShareNames(item["protect_users"]) is not { } users || ParseShareNames(item["protect_groups"]) is not { } groups ||
            StrictInt(item, "expire_times") is not (>= 0 and <= 9999) || StrictBool(item, "enable_upload") is not { } upload ||
            item["project_name"] is not JsonValue projectValue || !projectValue.TryGetValue<string>(out var project) ||
            project is not ("SYNO.SDS.App.FileStation3.Instance" or "SYNO.SDS.App.SharingUpload.Application") ||
            item["request_name"] is not JsonValue nameValue || !nameValue.TryGetValue<string>(out var name) ||
            item["request_info"] is not JsonValue messageValue || !messageValue.TryGetValue<string>(out var message)) return null;
        return new(protection switch { "password" => FileShareProtection.Password, "user" => FileShareProtection.Users,
                _ => FileShareProtection.None }, users, groups, StrictInt(item, "expire_times")!.Value, upload,
            project == "SYNO.SDS.App.SharingUpload.Application", name, message);
    }

    private static string[]? ParseShareNames(JsonNode? node)
    {
        if (node is not JsonArray items) return null;
        var names = new List<string>();
        foreach (var item in items)
            if (item is JsonValue value && value.TryGetValue<string>(out var name) && !string.IsNullOrEmpty(name)) names.Add(name);
            else return null;
        return names.Distinct(StringComparer.Ordinal).Count() == names.Count ? names.ToArray() : null;
    }

    private static bool ExactAdvancedShareDetails(FileShareAdvancedDetails? first, FileShareAdvancedDetails? second) =>
        first is null ? second is null : second is not null && first.Protection == second.Protection &&
            first.MaximumAccesses == second.MaximumAccesses && first.AllowsUpload == second.AllowsUpload &&
            first.IsFileRequest == second.IsFileRequest && first.RequestName == second.RequestName &&
            first.RequestMessage == second.RequestMessage && SameShareNames(first.Users, second.Users) && SameShareNames(first.Groups, second.Groups);

    private static bool SameShareNames(IEnumerable<string> first, IEnumerable<string> second) =>
        first.ToHashSet(StringComparer.Ordinal).SetEquals(second);

    private static bool FileRequestMatches(FileShareLink link, FileRequestConfiguration? configuration) =>
        configuration is null ? link.Advanced?.IsFileRequest != true :
            link.Advanced is { IsFileRequest: true, AllowsUpload: true } details &&
                details.RequestName == configuration.Name && details.RequestMessage == configuration.Message;

    private void StoreShareCreationReview(PendingShareCreation pending)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync) state.Creations[(_profile.Id, pending.Path)] = pending;
    }

    private void StoreShareEditReview(PendingShareEdit pending)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync) state.Edits[(_profile.Id, pending.Request.Link.Id)] = pending;
    }

    private void RemoveShareEditReview(string id)
    {
        var state = ShareDeleteReviewState();
        lock (state.Sync) state.Edits.Remove((_profile.Id, id));
    }

    private static FileShareLinkEditOutcome ShareEditOutcome(MutationResultStatus status, bool submitted,
        MutationErrorCategory? category = null, FileShareLink? link = null)
    {
        var success = status == MutationResultStatus.ConfirmedSuccess;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission;
        return new(new MutationResult(1, status, "shareLinkEdit", submitted, unknown,
            new MutationResultCounts(success ? 1 : 0, success || unknown || status == MutationResultStatus.CancelledBeforeSubmission ? 0 : 1,
                unknown ? 1 : 0), category, diagnosticTag: "file.share.edit"), link);
    }

    private sealed class PendingShareEdit(EditFileShareLinkRequest request)
    {
        public EditFileShareLinkRequest Request { get; } = request;
        public bool Accepted { get; set; }
        public bool Ready { get; set; }
    }

    private sealed record PendingShareCreation(string Path, string? Id, bool Accepted, HashSet<string> PreviousIds,
        bool HasPassword, DateOnly? AvailableOn, DateOnly? ExpiresOn, FileRequestConfiguration? FileRequest);
}
