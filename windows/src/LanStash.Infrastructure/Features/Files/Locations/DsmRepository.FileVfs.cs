using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string VfsProtocolApi = "SYNO.FileStation.VFS.Protocol";
    private const string VfsProfileApi = "SYNO.FileStation.VFS.Profile";
    private const string VfsConnectionApi = "SYNO.FileStation.VFS.Connection";
    public bool CanManageVfs => _profile.Id == _session.ProfileId && !string.IsNullOrEmpty(_session.Sid) &&
        new[] { VfsProtocolApi, VfsProfileApi, VfsConnectionApi, FileDesktopAccessApi }.All(api => HasFixedCapability(api, 1));

    private Task<JsonObject> VfsCallAsync(string api, string method, Dictionary<string, string> parameters, CancellationToken token)
    {
        if (_profile.Id != _session.ProfileId || string.IsNullOrEmpty(_session.Sid) || !HasFixedCapability(api, 1))
            throw new NotSupportedException("file.vfs.unavailable");
        return _api.CallAsync(_profile, _session, FixedCapability(api, 1), method, parameters, token);
    }

    public async Task<IReadOnlyList<FileVfsProtocol>> ListVfsProtocolsAsync(CancellationToken cancellationToken = default)
    {
        var data = await VfsCallAsync(VfsProtocolApi, "list", [], cancellationToken).ConfigureAwait(false);
        if (data["protocols"] is not JsonArray rows) throw VfsInvalid();
        var result = new List<FileVfsProtocol>(); var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject row || StrictBool(row, "has_server") is not { } exists) throw VfsInvalid();
            var id = VfsText(row, "protocol"); var name = VfsText(row, "name"); var port = VfsOptionalInt(row, "default_port");
            if (id.Length == 0 || name.Length == 0 || !ids.Add(id) || port is < 0 or > 65535) throw VfsInvalid();
            result.Add(new(id, name, port, exists));
        }
        return result;
    }

    public async Task<IReadOnlyList<FileVfsProfile>> ListVfsProfilesAsync(CancellationToken cancellationToken = default)
    {
        var data = await VfsCallAsync(VfsProfileApi, "list", [], cancellationToken).ConfigureAwait(false);
        if (data["profiles"] is not JsonArray rows || data.ContainsKey("total") && StrictInt(data, "total") != rows.Count) throw VfsInvalid();
        var result = new List<FileVfsProfile>(); var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in rows)
        {
            if (node is not JsonObject row || StrictInt(row, "connect_status") is not { } state) throw VfsInvalid();
            var id = VfsText(row, "id"); var protocol = VfsText(row, "protocol"); var uri = VfsText(row, "uri");
            var port = VfsOptionalInt(row, "port");
            if (id.Length == 0 || protocol.Length == 0 || uri.Length == 0 || !ids.Add(id) || port is < 0 or > 65535) throw VfsInvalid();
            result.Add(new(_profile.Id, id, protocol, VfsText(row, "protocol_name"), uri, VfsOptionalText(row, "hostname"), port,
                VfsText(row, "alias"), VfsOptionalText(row, "account"), VfsOptionalText(row, "codepage"),
                state == 1 ? FileVfsState.Connected : state == 0 ? FileVfsState.Disconnected : FileVfsState.Unknown));
        }
        return result;
    }

    public async Task<FileVfsDetail> LoadVfsDetailAsync(FileVfsProfile profile, CancellationToken cancellationToken = default)
    {
        if (profile.ProfileId != _profile.Id || profile.Protocol is not ("ftp" or "sftp" or "dav" or "davs")) throw VfsInvalid();
        if (!(await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false)).Contains(profile)) throw VfsInvalid();
        var data = await VfsCallAsync(VfsProfileApi, "get", new() { ["id"] = ShareParameterString(VfsProfileApi, profile.Id) }, cancellationToken).ConfigureAwait(false);
        // get 可包含密码；只读取已记录的配置字段，密码从不进入领域对象或表单。
        var port = StrictInt(data, "port"); var maximum = StrictInt(data, "max_connection");
        if (port is null || maximum is not (0 or 1)) throw VfsInvalid();
        var configuration = new FileVfsConfiguration(profile.Protocol, VfsText(data, "hostname"), port.Value,
            VfsText(data, "alias"), VfsText(data, "account"), VfsText(data, "codepage"), VfsText(data, "uri_path"), maximum == 1).Normalize();
        if (!configuration.IsValid || !VfsMatches(profile, configuration)) throw VfsInvalid();
        return new(profile, configuration);
    }

    public Task<FileVfsProgress> ChangeVfsAsync(FileVfsChange change, string? replacementPassword, CancellationToken cancellationToken = default) =>
        ChangeVfsCoreAsync(change, replacementPassword, null, cancellationToken);

    private async Task<FileVfsProgress> ChangeVfsCoreAsync(FileVfsChange change, string? replacementPassword, FileVfsCloudAuthorization? authorization, CancellationToken cancellationToken)
    {
        change = change with { Configuration = change.Configuration?.Normalize() };
        FileVfsProgress Reject(MutationErrorCategory category, bool submitted = false, FileVfsNotice notice = FileVfsNotice.None) =>
            VfsResult(change, category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
                category == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure, submitted, category, notice);
        if (!ValidVfsChange(change, replacementPassword, authorization)) return Reject(MutationErrorCategory.Validation);
        if (!CanManageVfs) return Reject(MutationErrorCategory.Unsupported);
        if (cancellationToken.IsCancellationRequested) return VfsResult(change, MutationResultStatus.CancelledBeforeSubmission, false);
        var cloud = change.Action is FileVfsAction.CreateCloud or FileVfsAction.Reauthorize;
        var setup = cloud || change.Action is FileVfsAction.Create or FileVfsAction.Update;
        if (setup)
        {
            try { if (_api.GetBaseUri(_profile).Scheme != Uri.UriSchemeHttps) return Reject(MutationErrorCategory.Permission, notice: FileVfsNotice.SecureConnectionRequired); }
            catch (DsmException) { return Reject(MutationErrorCategory.Permission, notice: FileVfsNotice.SecureConnectionRequired); }
        }
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict);
        try
        {
            var scope = ServiceScope();
            if (shared.Vfs.TryGetValue((scope, change.RequestId), out var prior))
                return prior.Change == change ? await ReviewVfsCoreAsync(prior, cancellationToken).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            if (shared.Vfs.Any(pair => pair.Key.Scope == scope && !pair.Value.Complete)) return Reject(MutationErrorCategory.Conflict);
            IReadOnlyList<FileVfsProfile> before;
            try
            {
                await RequireFileShareAdvancedWriteAsync(cancellationToken).ConfigureAwait(false);
                before = await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false);
                if (change.Existing is { } baseline && !before.Contains(baseline)) throw VfsInvalid();
                if (cloud)
                {
                    var identity = change.CloudIdentity!;
                    if (!(await ListVfsProtocolsAsync(cancellationToken).ConfigureAwait(false)).Any(p => p.Id == identity.Protocol && p.SupportsCloudAuthorization))
                        throw new NotSupportedException();
                    if (change.Action == FileVfsAction.CreateCloud && before.Any(p => p.Alias == identity.Alias || p.Protocol == identity.Protocol && p.Account == identity.Account)) throw VfsInvalid();
                }
                else if (setup)
                {
                    var config = change.Configuration!;
                    if (!(await ListVfsProtocolsAsync(cancellationToken).ConfigureAwait(false)).Any(p => p.Id == config.Protocol && p.SupportsServerSetup))
                        throw new NotSupportedException();
                    if (before.Any(p => p.Id != change.Existing?.Id && (p.Alias == config.Alias || change.Action == FileVfsAction.Create && VfsMatches(p, config)))) throw VfsInvalid();
                    if (change.Action == FileVfsAction.Update && await LoadVfsDetailAsync(change.Existing!, cancellationToken).ConfigureAwait(false) != change.Baseline) throw VfsInvalid();
                }
                var last = await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false);
                if (!before.OrderBy(p => p.Id, StringComparer.Ordinal).SequenceEqual(last.OrderBy(p => p.Id, StringComparer.Ordinal))) throw VfsInvalid();
                await RequireFileShareAdvancedWriteAsync(cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return VfsResult(change, MutationResultStatus.CancelledBeforeSubmission, false); }
            catch (DsmException error) { return Reject(ServiceErrorCategory(error)); }
            catch (NotSupportedException) { return Reject(MutationErrorCategory.Unsupported); }
            catch (InvalidDataException) { return Reject(MutationErrorCategory.Conflict); }
            catch { return Reject(MutationErrorCategory.Network); }

            var pending = new PendingVfs(change, before.Select(p => p.Id).ToHashSet(StringComparer.Ordinal));
            shared.Vfs.Add((scope, change.RequestId), pending);
            var method = change.Action switch { FileVfsAction.Update or FileVfsAction.Reauthorize => "set", FileVfsAction.Disconnect or FileVfsAction.RemoveSavedProfile => "delete", _ => "create" };
            try
            {
                if (change.Action == FileVfsAction.RemoveSavedProfile)
                {
                    await VfsCallAsync(VfsProfileApi, method, VfsParameters(VfsProfileApi, change, null), cancellationToken).ConfigureAwait(false);
                    pending.ProfileAccepted = true;
                }
                else
                {
                    var parameters = VfsParameters(VfsConnectionApi, change, replacementPassword, authorization);
                    if (method != "delete") parameters["force"] = "false";
                    await VfsCallAsync(VfsConnectionApi, method, parameters, cancellationToken).ConfigureAwait(false);
                    pending.ConnectionAccepted = true;
                    if (setup)
                    {
                        cancellationToken.ThrowIfCancellationRequested();
                        await VfsCallAsync(VfsProfileApi, method, VfsParameters(VfsProfileApi, change, replacementPassword, authorization), cancellationToken).ConfigureAwait(false);
                        pending.ProfileAccepted = true;
                    }
                }
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && !pending.ConnectionAccepted && !pending.ProfileAccepted)
            {
                shared.Vfs.Remove((scope, change.RequestId));
                return Reject(ServiceErrorCategory(error), true, error.Code is 2107 or 2112 or 2115 ? FileVfsNotice.IdentityWarning : FileVfsNotice.None);
            }
            catch { /* 已发送或接受的步骤不补发；密码仅存在于当前调用，不存入恢复记录。 */ }
            return await ReviewVfsCoreAsync(pending, cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<FileVfsProgress>> GetVfsOperationsAsync(CancellationToken cancellationToken = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.Vfs.Where(p => p.Key.Scope == scope && !p.Value.Complete).Select(p => VfsPendingResult(p.Value)).ToArray(); }
        finally { shared.Gate.Release(); }
    }
    public async Task<FileVfsProgress?> ReviewVfsAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return shared.Vfs.TryGetValue((ServiceScope(), requestId), out var pending) ? await ReviewVfsCoreAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<FileVfsProgress> ReviewVfsCoreAsync(PendingVfs pending, CancellationToken token)
    {
        if (pending.Complete) return VfsResult(pending.Change, MutationResultStatus.ConfirmedSuccess, true);
        try
        {
            var profiles = await ListVfsProfilesAsync(token).ConfigureAwait(false); var change = pending.Change;
            var existing = change.Existing;
            var matches = change.Action is FileVfsAction.Create or FileVfsAction.CreateCloud
                ? profiles.Where(p => !pending.OriginalIds.Contains(p.Id) && (change.CloudIdentity is { } cloud ? VfsMatchesCloud(p, cloud) : VfsMatches(p, change.Configuration!))).ToArray()
                : profiles.Where(p => p.Id == existing!.Id).ToArray();
            var profile = matches.Length == 1 ? matches[0] : null;
            pending.Complete = change.Action switch
            {
                FileVfsAction.Create or FileVfsAction.Update => pending.ConnectionAccepted && pending.ProfileAccepted &&
                    profile is { State: FileVfsState.Connected } && VfsMatches(profile, change.Configuration!) &&
                    (await LoadVfsDetailAsync(profile, token).ConfigureAwait(false)).Configuration == change.Configuration,
                FileVfsAction.CreateCloud => pending.ConnectionAccepted && pending.ProfileAccepted && profile is { State: FileVfsState.Connected } && VfsMatchesCloud(profile, change.CloudIdentity!),
                FileVfsAction.Reauthorize => pending.ConnectionAccepted && pending.ProfileAccepted && profile is { State: FileVfsState.Connected } && SameVfsIdentity(profile, existing!),
                FileVfsAction.Connect => pending.ConnectionAccepted && profile is { State: FileVfsState.Connected } && SameVfsIdentity(profile, existing!),
                FileVfsAction.Disconnect => pending.ConnectionAccepted && profile is { State: FileVfsState.Disconnected } && SameVfsIdentity(profile, existing!),
                FileVfsAction.RemoveSavedProfile => pending.ProfileAccepted && matches.Length == 0,
                _ => false,
            };
        }
        catch { /* 列表不完整、取消或回读失败都不能证明本次成功。 */ }
        return pending.Complete ? VfsResult(pending.Change, MutationResultStatus.ConfirmedSuccess, true) : VfsPendingResult(pending);
    }

    private bool ValidVfsChange(FileVfsChange change, string? password, FileVfsCloudAuthorization? authorization) => change.ProfileId == _profile.Id && change.RequestId != Guid.Empty && change.Confirmed &&
        (change.Action is FileVfsAction.CreateCloud or FileVfsAction.Reauthorize || change.CloudIdentity is null && authorization is null) &&
        (!(change.Configuration?.UsesCleartext == true || change.Action == FileVfsAction.Connect && change.Existing?.Protocol is "ftp" or "dav") || change.ConfirmedCleartext) && change.Action switch
        {
            FileVfsAction.CreateCloud => change.Existing is null && ValidVfsCloudChange(change, authorization, password),
            FileVfsAction.Reauthorize => change.Existing is { State: not FileVfsState.Unknown } original && original.ProfileId == _profile.Id &&
                change.CloudIdentity == new FileVfsCloudIdentity(original.Protocol, original.Alias, original.Account ?? "") && ValidVfsCloudChange(change, authorization, password),
            FileVfsAction.Create => change.Existing is null && change.Baseline is null && change.Configuration is { IsValid: true } && password is not null,
            FileVfsAction.Update => change.Existing is { State: not FileVfsState.Unknown } p && p.ProfileId == _profile.Id &&
                change.Baseline?.Profile == p && change.Configuration is { IsValid: true } c && c.Protocol == p.Protocol &&
                (c != change.Baseline.Configuration || password is not null),
            FileVfsAction.Connect or FileVfsAction.RemoveSavedProfile => change.Existing is { State: FileVfsState.Disconnected } p && p.ProfileId == _profile.Id && change.Configuration is null && change.Baseline is null && password is null,
            FileVfsAction.Disconnect => change.Existing is { State: FileVfsState.Connected } p && p.ProfileId == _profile.Id && change.Configuration is null && change.Baseline is null && password is null,
            _ => false,
        };
    private Dictionary<string, string> VfsParameters(string api, FileVfsChange change, string? password, FileVfsCloudAuthorization? authorization = null)
    {
        string Value(string value) => ShareParameterString(api, value);
        if (authorization is not null) return VfsCloudParameters(api, change, authorization);
        if (change.Configuration is not { } c) return new() { [change.Action == FileVfsAction.Connect ? "profile_id" : "id"] = Value(change.Existing!.Id) };
        var fields = new Dictionary<string, string>(); var previous = change.Baseline?.Configuration;
        if (change.Action == FileVfsAction.Create) fields["protocol"] = Value(c.Protocol); else fields["id"] = Value(change.Existing!.Id);
        void Text(string key, string current, string? old) { if (previous is null || current != old) fields[key] = Value(current); }
        Text("hostname", c.Hostname, previous?.Hostname); Text("alias", c.Alias, previous?.Alias); Text("account", c.Account, previous?.Account);
        Text("codepage", c.Codepage, previous?.Codepage); Text("uri_path", c.Folder, previous?.Folder);
        if (previous is null || c.Port != previous.Port) fields["port"] = c.Port.ToString(CultureInfo.InvariantCulture);
        if (previous is null || c.UsesOneConnection != previous.UsesOneConnection) fields["max_connection"] = c.UsesOneConnection ? "1" : "0";
        if (password is not null) fields["password"] = Value(password);
        return fields;
    }
    private static bool VfsMatches(FileVfsProfile profile, FileVfsConfiguration configuration) => profile.Protocol == configuration.Protocol &&
        profile.Hostname == configuration.Hostname && profile.Port == configuration.Port && profile.Alias == configuration.Alias && profile.Account == configuration.Account && profile.Codepage == configuration.Codepage;
    private static bool SameVfsIdentity(FileVfsProfile left, FileVfsProfile right) => left with { State = right.State } == right;
    private static string VfsText(JsonObject data, string key) => data[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : throw VfsInvalid();
    private static string? VfsOptionalText(JsonObject data, string key) => data[key] is null ? null : VfsText(data, key);
    private static int? VfsOptionalInt(JsonObject data, string key) => data[key] is null ? null : StrictInt(data, key) ?? throw VfsInvalid();
    private static InvalidDataException VfsInvalid() => new("file.vfs.changed");
    private static FileVfsProgress VfsPendingResult(PendingVfs pending) => VfsResult(pending.Change, MutationResultStatus.SubmittedButUnverified, true,
        notice: pending.ConnectionAccepted && !pending.ProfileAccepted && pending.Change.Action is FileVfsAction.Create or FileVfsAction.Update or FileVfsAction.CreateCloud or FileVfsAction.Reauthorize ? FileVfsNotice.Partial : FileVfsNotice.None);
    private static FileVfsProgress VfsResult(FileVfsChange change, MutationResultStatus status, bool submitted, MutationErrorCategory? error = null, FileVfsNotice notice = FileVfsNotice.None) =>
        new(change, new(1, status, "fileVfs", submitted, status == MutationResultStatus.SubmittedButUnverified,
            new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.Unsupported or MutationResultStatus.PermissionDenied ? 1 : 0,
                status == MutationResultStatus.SubmittedButUnverified ? 1 : 0), error), notice);
    private sealed class PendingVfs(FileVfsChange change, HashSet<string> originalIds)
    {
        public FileVfsChange Change { get; } = change;
        public HashSet<string> OriginalIds { get; } = originalIds;
        public bool ConnectionAccepted { get; set; }
        public bool ProfileAccepted { get; set; }
        public bool Complete { get; set; }
    }
}
