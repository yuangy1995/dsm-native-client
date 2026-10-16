using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<SynologyPhotoSharedMembers> SharedMembersAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var admin = await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var list = await _api.CallPhotoArrayAsync(_profile, _session, Capability("Setting.TeamSpace", 1, null), 1, "list_permission", cancellationToken).ConfigureAwait(false);
        var members = list.Select(Object).Select(raw => new SynologyPhotoSharedMember(ShareRecipient(raw), Text(raw, "permission"), Boolean(raw, "auto_backup"))).ToArray();
        if (members.Any(x => string.IsNullOrEmpty(x.Role)) || members.DistinctBy(x => x.Id).Count() != members.Length) throw Invalid();
        RequireGeneration(generation, cancellationToken); return new(ProfileId, admin, Boolean(team, "enabled"), members);
    }
    public async Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharedMemberCandidatesAsync(CancellationToken cancellationToken = default)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        var data = await CallAsync("Sharing.Misc", 1, "list_user_group", cancellationToken: cancellationToken).ConfigureAwait(false);
        var list = (data["list"] as JsonArray ?? throw Invalid()).Select(Object).Select(ShareRecipient).ToArray();
        if (list.DistinctBy(x => x.Id).Count() != list.Length) throw Invalid();
        RequireGeneration(generation, cancellationToken); return list;
    }
    public async Task<IReadOnlyList<SynologyPhotoMemberFolder>> SharedMemberFoldersAsync(SynologyPhotoShareIdentity member, CancellationToken cancellationToken = default)
    {
        RequireAccess(); _ = ShareIdentityValue(member); var generation = Volatile.Read(ref _accessGeneration);
        await RequirePhotoAdministratorAsync(cancellationToken).ConfigureAwait(false);
        if (!Boolean(await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false), "enabled"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var root = Positive(Object((await CallAsync("Browse.Folder", 2, "get", cancellationToken: cancellationToken, space: SynologyPhotoSpace.Shared).ConfigureAwait(false))["folder"]), "id");
        var folders = new List<SynologyPhotoMemberFolder>(); var seen = new HashSet<long>();
        async Task ReadChildren(long parentId, SynologyPhotoMemberFolder? parent)
        {
            for (var offset = 0; ; offset = checked(offset + 200))
            {
                if (parent is not null)
                {
                    var current = MemberFolder(Object((await CallAsync("Browse.Folder", 2, "get", Parameters(("id", parent.Id), ("additional", new[] { "sharing_info" })), cancellationToken, SynologyPhotoSpace.Shared).ConfigureAwait(false))["folder"]), member, root, root, 0);
                    if (current != parent) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                }
                var raw = await CallAsync("Browse.Folder", 2, "list", Parameters(("id", parentId), ("offset", offset), ("limit", 200),
                    ("sort_by", "filename"), ("sort_direction", "asc"), ("additional", new[] { "sharing_info" })), cancellationToken, SynologyPhotoSpace.Shared).ConfigureAwait(false);
                var list = raw["list"] as JsonArray ?? throw Invalid(); if (list.Count > 200) throw Invalid();
                foreach (var node in list)
                {
                    var folder = MemberFolder(Object(node), member, root, parentId, parent is null ? 0 : 1);
                    if (!seen.Add(folder.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    folders.Add(folder);
                }
                RequireGeneration(generation, cancellationToken); if (list.Count < 200) break;
            }
        }
        await ReadChildren(root, null).ConfigureAwait(false);
        foreach (var parent in folders.ToArray()) await ReadChildren(parent.Id, parent).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken); return folders;
    }
    private SynologyPhotoMemberFolder MemberFolder(JsonObject raw, SynologyPhotoShareIdentity member, long root, long parent, int depth)
    {
        var id = Positive(raw, "id"); var actualParent = Number(raw, "parent"); var name = Text(raw, "name");
        if (id == root || id == parent || actualParent != parent) throw Invalid();
        var info = Object(Object(raw["additional"])["sharing_info"]); var privacy = Text(info, "privacy_type");
        if (privacy.Length == 0) throw Invalid();
        var roles = (info["permission"] as JsonArray ?? throw Invalid()).Select(Object).Where(x => OptionalText(x, "type") != "public")
            .Select(x => (Id: ShareIdentity(Text(x, "type"), x["id"]) ?? throw Invalid(), Role: Text(x, "role"))).ToArray();
        if (roles.Any(x => x.Role.Length == 0) || roles.DistinctBy(x => x.Id).Count() != roles.Length) throw Invalid();
        var identity = new JsonObject { ["id"] = id, ["parent"] = parent, ["name"] = name };
        var identityHash = PhotoTextHash(identity.ToJsonString());
        identity["privacy"] = privacy;
        JsonArray Permissions(bool others) => new(roles.Where(x => !others || x.Id != member).OrderBy(x => x.Id.Type, StringComparer.Ordinal).ThenBy(x => x.Id.Numeric).ThenBy(x => x.Id.Value, StringComparer.Ordinal)
            .Select(x => (JsonNode)new JsonObject { ["type"] = x.Id.Type, ["id"] = ShareIdentityValue(x.Id), ["role"] = x.Role }).ToArray());
        identity["permissions"] = Permissions(false);
        return new(ProfileId, member, root, id, parent, name, depth, privacy, roles.FirstOrDefault(x => x.Id == member).Role,
            PhotoTextHash(identity.ToJsonString()), identityHash, PhotoTextHash(Permissions(true).ToJsonString()));
    }
}
