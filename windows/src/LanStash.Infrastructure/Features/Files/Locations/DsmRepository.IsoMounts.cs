using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string IsoMountApi = "SYNO.FileStation.Mount";
    private const string IsoListApi = "SYNO.FileStation.Mount.List";
    public bool CanManageIsoMounts => _profile.Id == _session.ProfileId && _profile.Id != Guid.Empty &&
        !string.IsNullOrEmpty(_session.Sid) && HasFixedCapability(IsoMountApi, 1) &&
        HasFixedCapability(IsoListApi, 1) && HasFixedCapability(FileListApi, 2) && HasFixedCapability(FileDesktopAccessApi, 1);

    public async Task<IsoMountProgress> ChangeIsoMountAsync(IsoMountChange change, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        IsoMountProgress Reject(MutationErrorCategory category, bool submitted = false) => IsoResult(change,
            category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
            category == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure, submitted, category);
        if (change.ProfileId != _profile.Id || change.RequestId == Guid.Empty || !change.Confirmed ||
            !PermissionTargetEditable(change.MountPoint, "normal") ||
            change.IsUnmount && (change.Source is not null || change.Existing!.ProfileId != _profile.Id || change.Existing.MountPoint != change.MountPoint) ||
            !change.IsUnmount && (change.Source is not { IsDirectory: false } source ||
                !source.Name.EndsWith(".iso", StringComparison.OrdinalIgnoreCase) || !source.Path.EndsWith(".iso", StringComparison.OrdinalIgnoreCase) || !PermissionPathValid(source.Path) ||
                RemoteMountPathsOverlap(source.Path, change.MountPoint)) ||
            !change.IsUnmount && change.AutomaticMount && !change.ConfirmedAutomatic)
            return Reject(MutationErrorCategory.Validation);
        if (!CanManageIsoMounts) return Reject(MutationErrorCategory.Unsupported);
        var shared = ServiceMutations; var scope = ServiceScope();
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict);
        try
        {
            if (shared.IsoMounts.TryGetValue((scope, change.RequestId), out var existing))
                return existing.Change == change ? await ReviewIsoCoreAsync(existing, cancellationToken).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            if (cancellationToken.IsCancellationRequested) return IsoResult(change, MutationResultStatus.CancelledBeforeSubmission, false);
            var paths = new[] { change.MountPoint, change.Source?.Path ?? change.Existing?.Source }.OfType<string>().ToArray();
            if (shared.IsoMounts.Any(pair => pair.Key.Scope == scope && !pair.Value.Complete &&
                    pair.Value.Paths.Any(active => paths.Any(path => RemoteMountPathsOverlap(active, path)))) ||
                shared.FilePermissions.Keys.Any(key => key.Scope == scope && paths.Any(path => RemoteMountPathsOverlap(key.Path, path))) ||
                shared.RemoteMountOperations.Values.Any(active => active.Scope == scope && !active.IsTerminal &&
                    active.Paths.Any(path => paths.Any(target => RemoteMountPathsOverlap(path, target))))) return Reject(MutationErrorCategory.Conflict);
            try
            {
                var first = await CheckIsoBeforeWriteAsync(change, cancellationToken).ConfigureAwait(false);
                // 空目录和权限在用户确认后仍会变化；发送前再读同一来源、目标、清单和授权。
                var last = await CheckIsoBeforeWriteAsync(change, cancellationToken).ConfigureAwait(false);
                if (first != last) return Reject(MutationErrorCategory.Conflict);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return IsoResult(change, MutationResultStatus.CancelledBeforeSubmission, false); }
            catch (DsmException error) { return Reject(ServiceErrorCategory(error)); }
            catch (NotSupportedException) { return Reject(MutationErrorCategory.Unsupported); }
            catch (InvalidDataException) { return Reject(MutationErrorCategory.Conflict); }
            catch (Exception) { return Reject(MutationErrorCategory.Network); }
            var pending = new PendingIsoMount(change, paths);
            shared.IsoMounts.Add((scope, change.RequestId), pending);
            var api = change.IsUnmount ? IsoListApi : IsoMountApi;
            var parameters = change.IsUnmount ? new Dictionary<string, string>
                { ["mount_point"] = JsonSerializer.Serialize(new[] { change.MountPoint }) } : new()
                {
                    ["source"] = ShareParameterString(api, change.Source!.Path),
                    ["mount_point"] = ShareParameterString(api, change.MountPoint),
                    ["auto_mount"] = BoolText(change.AutomaticMount), ["user_set"] = "true",
                };
            try
            {
                await _api.CallAsync(_profile, _session, FixedCapability(api, 1), change.IsUnmount ? "unmount" : "mount_iso",
                    parameters, cancellationToken).ConfigureAwait(false);
                pending.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                shared.IsoMounts.Remove((scope, change.RequestId)); return Reject(ServiceErrorCategory(error), true);
            }
            catch (Exception) { /* 可能已经生效，保留原目标，不再次发送。 */ }
            return await ReviewIsoCoreAsync(pending, cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<IsoMountProgress>> GetIsoMountOperationsAsync(CancellationToken cancellationToken = default)
    {
        if (!CanManageIsoMounts) return [];
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.IsoMounts.Where(pair => pair.Key.Scope == scope && !pair.Value.Complete)
            .Select(pair => IsoResult(pair.Value.Change, MutationResultStatus.SubmittedButUnverified, true)).ToArray(); }
        finally { shared.Gate.Release(); }
    }

    public async Task<IsoMountProgress?> ReviewIsoMountAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        if (!CanManageIsoMounts) return null;
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return shared.IsoMounts.TryGetValue((ServiceScope(), requestId), out var pending)
            ? await ReviewIsoCoreAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }

    private async Task<(IsoTarget? Source, IsoTarget Target, bool Administrator)> CheckIsoBeforeWriteAsync(IsoMountChange change, CancellationToken token)
    {
        var access = await LoadFileAdvancedAccessAsync(token).ConfigureAwait(false);
        if (!access.Allowed || (change.AutomaticMount || change.Existing?.AutomaticMount == true) && !access.Administrator)
            throw PermissionDenied();
        var inventory = await LoadRemoteMountInventoryAsync(token).ConfigureAwait(false);
        if (inventory.IsoItems is not { } iso || inventory.IsoMountingEnabled is null) throw new NotSupportedException();
        if (inventory.IsoMountingEnabled != true) throw PermissionDenied();
        if (inventory.Items.Any(item => RemoteMountPathsOverlap(item.MountPoint, change.MountPoint)) ||
            iso.Any(item => item != change.Existing && RemoteMountPathsOverlap(item.MountPoint, change.MountPoint))) throw PermissionInvalid();
        var target = await ReadIsoTargetAsync(change.MountPoint, token).ConfigureAwait(false);
        if (change.IsUnmount)
        {
            if (!iso.Contains(change.Existing!) || !target.Directory || !IsoMountedKind(target.Kind)) throw PermissionInvalid();
            return (null, target, access.Administrator);
        }
        if (!target.Directory || !target.CanWrite || target.Kind is not ("normal" or "")) throw PermissionDenied();
        var source = await ReadIsoTargetAsync(change.Source!.Path, token).ConfigureAwait(false);
        if (source.Directory || !source.CanRead || source.Size != change.Source.Size || source.Modified != change.Source.ModifiedAt ||
            inventory.Items.Any(item => RemoteMountPathsOverlap(item.MountPoint, source.Path)) ||
            iso.Any(item => RemoteMountPathsOverlap(item.MountPoint, source.Path))) throw PermissionInvalid();
        var page = await _api.CallAsync(_profile, _session, FixedCapability(FileListApi, 2), "list", new Dictionary<string, string>
        { ["folder_path"] = ShareParameterString(FileListApi, change.MountPoint), ["offset"] = "0", ["limit"] = "1" }, token).ConfigureAwait(false);
        if (StrictInt(page, "total") != 0 || page["files"] is not JsonArray { Count: 0 } ||
            page.ContainsKey("offset") && StrictInt(page, "offset") != 0) throw PermissionInvalid();
        return (source, target, access.Administrator);
    }

    private async Task<IsoMountProgress> ReviewIsoCoreAsync(PendingIsoMount pending, CancellationToken token)
    {
        if (!pending.Complete)
        {
            try
            {
                var inventory = await LoadRemoteMountInventoryAsync(token).ConfigureAwait(false);
                if (inventory.IsoItems is { } iso)
                {
                    var change = pending.Change;
                    var target = await ReadIsoTargetAsync(change.MountPoint, token).ConfigureAwait(false);
                    var unrelated = inventory.Items.Any(item => RemoteMountPathsOverlap(item.MountPoint, change.MountPoint));
                    var expected = new IsoMountConnection(_profile.Id, change.Source?.Path ?? change.Existing!.Source, change.MountPoint, change.AutomaticMount);
                    // 目标恰好匹配不能代替本次接受回执，卸载也不得认领他人的操作。
                    pending.Complete = pending.Accepted && !unrelated && target.Directory && (change.IsUnmount
                        ? !iso.Any(item => RemoteMountPathsOverlap(item.MountPoint, change.MountPoint)) && target.Kind is "normal" or ""
                        : iso.Contains(expected) && !iso.Any(item => item != expected && RemoteMountPathsOverlap(item.MountPoint, change.MountPoint)) && IsoMountedKind(target.Kind));
                }
            }
            catch (Exception) { /* 失败、取消和缺字段都不能证明挂载已改变。 */ }
        }
        return IsoResult(pending.Change, pending.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, true);
    }

    private async Task<IsoTarget> ReadIsoTargetAsync(string path, CancellationToken token)
    {
        var data = await _api.CallAsync(_profile, _session, FixedCapability(FileListApi, 2), "getinfo", new Dictionary<string, string>
        { ["path"] = JsonSerializer.Serialize(new[] { path }), ["additional"] = "[\"size\",\"time\",\"perm\",\"mount_point_type\"]" }, token).ConfigureAwait(false);
        if (data["files"] is not JsonArray { Count: 1 } rows || rows[0] is not JsonObject row || PermissionText(row, "path") != path ||
            row.ContainsKey("code") && StrictInt(row, "code") != 0 || StrictBool(row, "isdir") is not { } directory ||
            row["additional"] is not JsonObject additional || additional["perm"] is not JsonObject perm ||
            !additional.ContainsKey("mount_point_type") || additional["time"] is not JsonObject time ||
            StrictEpoch(time["mtime"]) is not { } modified || StrictLong(row.ContainsKey("size") ? row["size"] : additional["size"]) is not { } size || size < 0)
            throw PermissionInvalid();
        var rights = FileStationPermissions.Parse(perm);
        return new(path, directory, size, modified, PermissionText(additional, "mount_point_type"), rights.Read == true, rights.Write == true);
    }
    private static bool IsoMountedKind(string kind) => kind.Length > 0 && kind is not ("normal" or "shared_folder");
    private static IsoMountProgress IsoResult(IsoMountChange change, MutationResultStatus status, bool submitted, MutationErrorCategory? error = null) =>
        new(change, new(1, status, "isoMount", submitted, status == MutationResultStatus.SubmittedButUnverified,
            new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0,
                status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0,
                status == MutationResultStatus.SubmittedButUnverified ? 1 : 0), error));
    private sealed record IsoTarget(string Path, bool Directory, long Size, DateTimeOffset Modified, string Kind, bool CanRead, bool CanWrite);
    private sealed class PendingIsoMount(IsoMountChange change, string[] paths)
    {
        public IsoMountChange Change { get; } = change;
        public string[] Paths { get; } = paths;
        public bool Accepted { get; set; }
        public bool Complete { get; set; }
    }
}
