using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string FileAclApi = "SYNO.Core.ACL";
    private const string FileAclOwnerApi = "SYNO.FileStation.Property.ACLOwner";
    private const string FilePropertyApi = "SYNO.FileStation.Property";
    private static readonly string[] AclRightKeys = ["read_data", "write_data", "exe_file", "append_data", "delete",
        "delete_sub", "read_attr", "write_attr", "read_ext_attr", "write_ext_attr", "read_perm", "change_perm", "take_ownership"];
    private static readonly string[] AclInheritanceKeys = ["child_files", "child_folders", "this_folder", "all_descendants"];

    public async Task<FilePermissionSnapshot> LoadFilePermissionsAsync(string path, CancellationToken cancellationToken = default)
    {
        RequirePermissionSession();
        if (!PermissionPathValid(path)) throw PermissionInvalid();
        var data = await PermissionCallAsync(FileListApi, "getinfo", new()
        {
            ["path"] = JsonSerializer.Serialize(new[] { path }),
            ["additional"] = "[\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\",\"real_path\"]",
        }, cancellationToken, 2).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } files || files[0] is not JsonObject row ||
            PermissionText(row, "path") != path || row.ContainsKey("code") && StrictInt(row, "code") != 0 ||
            row["additional"] is not JsonObject additional || additional["perm"] is not JsonObject perm ||
            StrictBool(perm, "is_acl_mode") is not { } isAcl || StrictBool(row, "isdir") is not { } directory)
            throw PermissionInvalid();
        var resolved = PermissionText(additional, "real_path");
        if (!PermissionPathValid(resolved)) throw PermissionInvalid();
        var owner = additional["owner"] as JsonObject ?? throw PermissionInvalid();
        var mount = additional.ContainsKey("mount_point_type") ? PermissionText(additional, "mount_point_type") : null;
        var time = additional["time"] as JsonObject;
        var size = StrictLong(row.ContainsKey("size") ? row["size"] : additional["size"]);
        if (size is null or < 0 || time is null || StrictEpoch(time["mtime"]) is not { } modified) throw PermissionInvalid();
        var rights = FileStationPermissions.Parse(perm);
        var target = new FileItem(path, PermissionText(row, "name"), directory, size.Value, modified,
            PermissionText(owner, "user"), rights.Write == true, rights.Delete == true);
        var group = PermissionText(owner, "group");
        (bool Allowed, bool Administrator) access;
        try { access = await LoadFileAdvancedAccessAsync(cancellationToken).ConfigureAwait(false); }
        catch (Exception error) when (error is NotSupportedException or InvalidDataException or HttpRequestException ||
            error is DsmException dsm && !dsm.AuthenticationFailure)
        {
            // 授权摘要不可得时保留详情读取，但不推断任何编辑或管理员权限。
            access = (false, false);
        }
        var editable = access.Allowed && PermissionTargetEditable(path, mount);
        if (!isAcl)
        {
            var mode = StrictInt(perm, "posix")?.ToString("D3", CultureInfo.InvariantCulture);
            if (!ValidPosixMode(mode)) throw PermissionInvalid();
            return new(ServiceScope(), target, resolved, group, mount, false, editable && access.Administrator,
                access.Administrator, false, [], null, mode) { ActingAccount = _profile.Username };
        }
        var acl = await PermissionCallAsync(FileAclApi, "get", new()
        {
            ["file_path"] = ShareParameterString(FileAclApi, resolved),
            ["type"] = ShareParameterString(FileAclApi, "all"), ["include_noname_rules"] = "true",
        }, cancellationToken).ConfigureAwait(false);
        if (StrictBool(acl, "is_acl") != true || StrictBool(acl, "change_permission") is not { } canChange ||
            StrictBool(acl, "is_inherited") is not { } inherited || acl["acl"] is not JsonArray rules ||
            acl.ContainsKey("acl_editable") && StrictBool(acl, "acl_editable") is null) throw PermissionInvalid();
        var parsed = rules.Select(ParsePermissionRule).ToArray();
        var aclOwner = await PermissionCallAsync(FileAclOwnerApi, "get", new()
        { ["file"] = ShareParameterString(FileAclOwnerApi, resolved) }, cancellationToken).ConfigureAwait(false);
        if (StrictBool(aclOwner, "hasPrivilege") is not { } ownerPrivilege) throw PermissionInvalid();
        return new(ServiceScope(), target, resolved, group, mount, true,
            editable && canChange && StrictBool(acl, "acl_editable") != false, access.Administrator, inherited,
            Array.AsReadOnly(parsed), new(PermissionText(aclOwner, "name"), PermissionText(aclOwner, "type"),
                PermissionText(aclOwner, "value"), editable && access.Administrator && ownerPrivilege), null) { ActingAccount = _profile.Username };
    }

    public async Task<FilePermissionProgress> ChangeFilePermissionsAsync(FilePermissionChange change,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        change = change with { Baseline = change.Baseline with { Rules = change.Baseline.Rules.ToArray() },
            ExplicitRules = change.ExplicitRules?.ToArray() };
        var baseline = change.Baseline;
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return PermissionRejected(MutationErrorCategory.Conflict);
        try
        {
            var scope = ServiceScope(); var key = (scope, baseline.Target.Path);
            if (shared.FilePermissions.Keys.Any(active => active.Scope == scope && RemoteMountPathsOverlap(active.Path, key.Path)) ||
                shared.IsoMounts.Any(active => active.Key.Scope == scope && !active.Value.Complete &&
                    active.Value.Paths.Any(path => RemoteMountPathsOverlap(path, key.Path))) ||
                shared.RemoteMountOperations.Values.Any(active => active.Scope == scope && !active.IsTerminal &&
                    active.Paths.Any(path => RemoteMountPathsOverlap(path, key.Path)))) return PermissionRejected(MutationErrorCategory.Conflict);
            if (cancellationToken.IsCancellationRequested) return PermissionCancelled();
            Dictionary<string, string> parameters;
            var api = baseline.IsAcl ? FileAclApi : FilePropertyApi;
            try
            {
                RequirePermissionSession();
                if (baseline.Scope != scope || !PermissionTargetEditable(baseline.Target.Path, baseline.MountPointType) ||
                    !change.ConfirmedAccessRemoval || change.Recursive && (!baseline.Target.IsDirectory || !change.ConfirmedScope) ||
                    (change.Owner is not null || change.Group is not null) && !change.ConfirmedOwner)
                    return PermissionRejected(MutationErrorCategory.Validation);
                if (!HasFixedCapability(api, 1)) return PermissionRejected(MutationErrorCategory.Unsupported);
                if (!SamePermissionSnapshot(baseline, await LoadFilePermissionsAsync(baseline.Target.Path, cancellationToken).ConfigureAwait(false)))
                    return PermissionRejected(MutationErrorCategory.Conflict);
                if ((!baseline.IsAcl || change.Owner is not null || change.Group is not null) && !baseline.IsAdministrator)
                    return PermissionRejected(MutationErrorCategory.Permission);
                foreach (var principal in new[] { change.Owner, change.Group }.OfType<FileSharePrincipal>())
                    await RequirePermissionPrincipalAsync(principal, cancellationToken).ConfigureAwait(false);
                parameters = await BuildPermissionParametersAsync(change, cancellationToken).ConfigureAwait(false);
                // 成员与自锁查询期间可能换权；最后一次读取包含当前授权及完整目标快照。
                if (!SamePermissionSnapshot(baseline, await LoadFilePermissionsAsync(baseline.Target.Path, cancellationToken).ConfigureAwait(false)))
                    return PermissionRejected(MutationErrorCategory.Conflict);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return PermissionCancelled(); }
            catch (NotSupportedException) { return PermissionRejected(MutationErrorCategory.Unsupported); }
            catch (DsmException error) { return PermissionRejected(ServiceErrorCategory(error)); }
            catch (Exception error) when (error is InvalidDataException or ArgumentException) { return PermissionRejected(MutationErrorCategory.Validation); }
            catch (Exception) { return PermissionRejected(MutationErrorCategory.Network); }

            var pending = new PendingFilePermissionChange(change, api);
            shared.FilePermissions.Add(key, pending);
            try
            {
                var response = await PermissionCallAsync(api, "set", parameters, cancellationToken).ConfigureAwait(false);
                pending.Accepted = true;
                var idKey = baseline.IsAcl ? "task_id" : "taskid";
                if (response.ContainsKey(idKey)) pending.TaskId = PermissionText(response, idKey);
                ReadPermissionTask(response, pending);
                pending.ResponseValid = true;
                if (pending.TaskId is null && !change.Recursive && StrictBool(response, "running") == false) pending.Finished = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                shared.FilePermissions.Remove(key);
                return PermissionRejected(ServiceErrorCategory(error), submitted: true);
            }
            catch (Exception) { /* 已提交或可能已提交，保留原记录，后续只读。 */ }
            return await ReviewPermissionCoreAsync(pending, cancellationToken.IsCancellationRequested ? CancellationToken.None : cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<FilePermissionProgress?> ReviewFilePermissionsAsync(string path, CancellationToken cancellationToken = default)
    {
        RequirePermissionSession();
        var shared = ServiceMutations;
        await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return shared.FilePermissions.TryGetValue((ServiceScope(), path), out var pending)
            ? await ReviewPermissionCoreAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }

    private async Task<FilePermissionProgress> ReviewPermissionCoreAsync(PendingFilePermissionChange pending, CancellationToken token)
    {
        try
        {
            if (pending.TaskId is { Length: > 0 } task && !pending.Finished && !pending.Failed)
            {
                ReadPermissionTask(await PermissionCallAsync(pending.Api, "status", new()
                { [pending.Change.Baseline.IsAcl ? "task_id" : "taskid"] = ShareParameterString(pending.Api, task) }, token).ConfigureAwait(false), pending);
                pending.ResponseValid = true;
            }
            // 子树失败持续保留，不能被后来根项目恰好匹配覆盖。
            if (!pending.Failed && pending.Accepted && pending.ResponseValid &&
                (pending.TaskId is null && !pending.Change.Recursive || pending.TaskId is { Length: > 0 } && pending.Finished) &&
                PermissionChangeMatches(pending.Change, await LoadFilePermissionsAsync(pending.Change.Baseline.Target.Path, token).ConfigureAwait(false)))
            {
                ServiceMutations.FilePermissions.Remove((ServiceScope(), pending.Change.Baseline.Target.Path));
                return new(new(1, MutationResultStatus.ConfirmedSuccess, "filePermissions", true, false, new(1, 0, 0)));
            }
        }
        catch (Exception) { /* 读取失败不改变已提交事实。 */ }
        return new(new(1, MutationResultStatus.SubmittedButUnverified, "filePermissions", true, true, new(0, 0, 1)),
            pending.ErrorCount, pending.Failed);
    }

    private async Task<Dictionary<string, string>> BuildPermissionParametersAsync(FilePermissionChange change, CancellationToken token)
    {
        var baseline = change.Baseline;
        if (baseline.IsAcl)
        {
            if (change.PosixMode is not null || change.Group is not null || change.Owner is not null && baseline.Owner?.CanChange != true ||
                change.ExplicitRules is not null && !baseline.CanChangePermissions || change.ExplicitRules is null && change.Owner is null)
                throw PermissionDenied();
            var rules = change.ExplicitRules ?? baseline.Rules.Where(rule => rule.Level == 0).ToArray();
            if (rules.Count > 200 || rules.Any(rule => rule.Level != 0 || !Enum.IsDefined(rule.Effect) ||
                ((int)rule.Rights & ~8191) != 0 || ((int)rule.Inheritance & ~15) != 0)) throw PermissionInvalid();
            foreach (var rule in rules)
            {
                if (baseline.Rules.Any(old => old.Level == 0 && old.OwnerType == rule.OwnerType &&
                    old.OwnerName == rule.OwnerName && old.OwnerId == rule.OwnerId && old.IsInternal == rule.IsInternal)) continue;
                if (rule.OwnerType is not ("user" or "group") || rule.OwnerId is not null || rule.IsInternal is not null) throw PermissionInvalid();
                await RequirePermissionPrincipalAsync(new(rule.OwnerName, rule.OwnerType == "user" ? FileSharePrincipalKind.User : FileSharePrincipalKind.Group), token).ConfigureAwait(false);
            }
            var parameters = new Dictionary<string, string>
            {
                ["file_path"] = ShareParameterString(FileAclApi, baseline.ResolvedPath),
                ["change_acl"] = BoolText(change.ExplicitRules is not null),
                ["rules"] = JsonSerializer.Serialize(rules.Select(PermissionRuleValues)),
                ["inherited"] = BoolText(baseline.IsInherited), ["acl_recur"] = BoolText(change.Recursive && change.ExplicitRules is not null),
            };
            if (change.Owner is { } owner)
            {
                parameters["change_acl_owner"] = "true";
                parameters["acl_owner_type"] = ShareParameterString(FileAclApi, owner.Kind == FileSharePrincipalKind.User ? "user" : "group");
                parameters["acl_owner"] = ShareParameterString(FileAclApi, owner.Name);
                parameters["acl_owner_recur"] = BoolText(change.Recursive);
            }
            var check = await PermissionCallAsync(FileAclApi, "check_self_denied", parameters, token).ConfigureAwait(false);
            if (StrictBool(check, "is_denied") != false) throw PermissionDenied();
            return parameters;
        }
        if (!baseline.CanChangePermissions || change.ExplicitRules is not null || change.Owner?.Kind == FileSharePrincipalKind.Group ||
            change.Group?.Kind == FileSharePrincipalKind.User || change.PosixMode is not null && !ValidPosixMode(change.PosixMode) ||
            change.PosixMode is null && change.Owner is null && change.Group is null) throw PermissionDenied();
        var parent = baseline.Target.IsDirectory ? baseline.Target.Path : baseline.Target.Path[..baseline.Target.Path.LastIndexOf('/')];
        var posix = new Dictionary<string, string>
        {
            ["files"] = JsonSerializer.Serialize(new[] { baseline.ResolvedPath }), ["dir_paths"] = JsonSerializer.Serialize(new[] { parent }),
            ["mode"] = ShareParameterString(FilePropertyApi, change.PosixMode ?? "-1"),
            ["posix_mode_recur"] = BoolText(change.Recursive && change.PosixMode is not null),
            ["posix_owner_recur"] = BoolText(change.Recursive && (change.Owner is not null || change.Group is not null)),
        };
        if (change.Owner is { } user) posix["owner"] = ShareParameterString(FilePropertyApi, user.Name);
        if (change.Group is { } group) posix["group"] = ShareParameterString(FilePropertyApi, group.Name);
        return posix;
    }

    private async Task RequirePermissionPrincipalAsync(FileSharePrincipal principal, CancellationToken token)
    {
        if (!Enum.IsDefined(principal.Kind) || string.IsNullOrEmpty(principal.Name) ||
            !(await ListFileSharePrincipalsAsync(principal.Name, token).ConfigureAwait(false)).Contains(principal)) throw PermissionInvalid();
    }

    private Task<JsonObject> PermissionCallAsync(string api, string method, Dictionary<string, string> values, CancellationToken token, int version = 1)
    {
        RequirePermissionSession();
        if (!HasFixedCapability(api, version)) throw new NotSupportedException("file.permissions.unsupported");
        return _api.CallAsync(_profile, _session, FixedCapability(api, version), method, values, token);
    }
    private void RequirePermissionSession()
    {
        if (_session.ProfileId != _profile.Id || string.IsNullOrEmpty(_session.Sid)) throw PermissionDenied();
    }
    private static bool PermissionPathValid(string path) => path.StartsWith('/') && path.Length > 1 && !path.EndsWith('/') &&
        !path.Contains('\0') && !path.Contains('\\') && !path.Split('/').Skip(1).Any(part => part is "" or "." or "..");
    private static bool PermissionTargetEditable(string path, string? mount) => PermissionPathValid(path) &&
        path.Split('/').Length >= 3 && mount is "" or "normal" && !path.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase));
    private static bool ValidPosixMode(string? mode) => mode is { Length: 3 } && mode.All(ch => ch is >= '0' and <= '7');
    private static string BoolText(bool value) => value ? "true" : "false";
    private static string PermissionText(JsonObject obj, string key) => obj[key] is JsonValue value && value.TryGetValue<string>(out var text)
        ? text : throw PermissionInvalid();
    private static InvalidDataException PermissionInvalid() => new("file.permissions.invalid-response");
    private static DsmException PermissionDenied() => new("file.permissions.denied", "file.permissions.refresh", code: 105);

    private static FileAclRule ParsePermissionRule(JsonNode? node)
    {
        if (node is not JsonObject row || StrictInt(row, "level") is not (>= 0) ||
            PermissionText(row, "permission_type") is not ("allow" or "deny") ||
            row.ContainsKey("owner_id") && row["owner_id"] is not null && StrictLong(row["owner_id"]) is null ||
            row.ContainsKey("owner_is_internal") && row["owner_is_internal"] is not null && StrictBool(row, "owner_is_internal") is null)
            throw PermissionInvalid();
        return new(PermissionText(row, "owner_type"), PermissionText(row, "owner_name"), StrictLong(row["owner_id"]),
            StrictBool(row, "owner_is_internal"), PermissionText(row, "permission_type") == "allow" ? FileAclEffect.Allow : FileAclEffect.Deny,
            (FileAclRights)ParsePermissionBits(row["permission"], AclRightKeys),
            (FileAclInheritance)ParsePermissionBits(row["inherit"], AclInheritanceKeys), StrictInt(row, "level")!.Value);
    }
    private static int ParsePermissionBits(JsonNode? node, string[] keys)
    {
        if (node is not JsonObject obj || !obj.Select(pair => pair.Key).ToHashSet(StringComparer.Ordinal).SetEquals(keys)) throw PermissionInvalid();
        var flags = 0;
        for (var index = 0; index < keys.Length; index++)
            if (StrictBool(obj, keys[index]) is not { } value) throw PermissionInvalid();
            else if (value) flags |= 1 << index;
        return flags;
    }
    private static Dictionary<string, object> PermissionRuleValues(FileAclRule rule)
    {
        var result = new Dictionary<string, object>
        {
            ["owner_type"] = rule.OwnerType, ["owner_name"] = rule.OwnerName,
            ["permission_type"] = rule.Effect == FileAclEffect.Allow ? "allow" : "deny",
            ["permission"] = AclRightKeys.Select((key, index) => (key, index)).ToDictionary(item => item.key, item => ((int)rule.Rights & 1 << item.index) != 0),
            ["inherit"] = AclInheritanceKeys.Select((key, index) => (key, index)).ToDictionary(item => item.key, item => ((int)rule.Inheritance & 1 << item.index) != 0),
        };
        if (rule.OwnerId is { } id) result["owner_id"] = id;
        return result;
    }
    private static bool SamePermissionSnapshot(FilePermissionSnapshot first, FilePermissionSnapshot second) =>
        first with { Rules = second.Rules } == second && first.Rules.SequenceEqual(second.Rules);

    private static bool PermissionChangeMatches(FilePermissionChange change, FilePermissionSnapshot current)
    {
        var old = change.Baseline;
        if (old.Scope != current.Scope || old.Target.Path != current.Target.Path || old.Target.IsDirectory != current.Target.IsDirectory ||
            old.ResolvedPath != current.ResolvedPath || old.MountPointType != current.MountPointType || old.IsAcl != current.IsAcl) return false;
        if (!old.IsAcl) return current.PosixMode == (change.PosixMode ?? old.PosixMode) &&
            current.Target.Owner == (change.Owner?.Name ?? old.Target.Owner) && current.Group == (change.Group?.Name ?? old.Group);
        if (old.IsInherited != current.IsInherited || !old.Rules.Where(rule => rule.Level > 0).SequenceEqual(current.Rules.Where(rule => rule.Level > 0))) return false;
        var actual = current.Rules.Where(rule => rule.Level == 0).ToList();
        var expected = change.ExplicitRules ?? old.Rules.Where(rule => rule.Level == 0).ToArray();
        // 逐条消耗匹配，防止重复规则丢失仍被集合比较误判成功。
        foreach (var rule in expected)
        {
            var index = actual.FindIndex(row => row.OwnerType == rule.OwnerType && row.OwnerName == rule.OwnerName &&
                (rule.OwnerId is null || row.OwnerId == rule.OwnerId) && (rule.IsInternal is null || row.IsInternal == rule.IsInternal) &&
                row.Effect == rule.Effect && row.Rights == rule.Rights && row.Inheritance == rule.Inheritance);
            if (index < 0) return false;
            actual.RemoveAt(index);
        }
        return actual.Count == 0 && current.Owner?.Name == (change.Owner?.Name ?? old.Owner?.Name) &&
            current.Owner?.Type == (change.Owner is { } owner ? owner.Kind == FileSharePrincipalKind.User ? "user" : "group" : old.Owner?.Type);
    }
    private static void ReadPermissionTask(JsonObject response, PendingFilePermissionChange pending)
    {
        pending.Failed |= response["result"]?.ToString() == "fail" || StrictInt(response, "errno") is { } failure && failure != 0;
        foreach (var key in new[] { "finished", "running" })
            if (response.ContainsKey(key) && StrictBool(response, key) is null) throw PermissionInvalid();
        if (response.ContainsKey("errno") && StrictInt(response, "errno") is null ||
            response.ContainsKey("errItems") && response["errItems"] is not JsonArray ||
            response.ContainsKey("result") && (response["result"] is not JsonValue result || !result.TryGetValue<string>(out _))) throw PermissionInvalid();
        pending.Finished |= StrictBool(response, "finished") == true;
        pending.ErrorCount = Math.Max(pending.ErrorCount, (response["errItems"] as JsonArray)?.Count ?? 0);
        pending.Failed |= response["result"]?.ToString() == "fail" || StrictInt(response, "errno") is { } error && error != 0 || pending.ErrorCount > 0;
    }
    private static FilePermissionProgress PermissionRejected(MutationErrorCategory category, bool submitted = false) => new(new(1,
        category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
        category == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure,
        "filePermissions", submitted, false, new(0, 1, 0), category));
    private static FilePermissionProgress PermissionCancelled() => new(new(1, MutationResultStatus.CancelledBeforeSubmission,
        "filePermissions", false, false, new(0, 0, 0)));
    private sealed class PendingFilePermissionChange(FilePermissionChange change, string api)
    {
        public FilePermissionChange Change { get; } = change;
        public string Api { get; } = api;
        public string? TaskId { get; set; }
        public bool Accepted { get; set; }
        public bool ResponseValid { get; set; }
        public bool Finished { get; set; }
        public bool Failed { get; set; }
        public int ErrorCount { get; set; }
    }
}
