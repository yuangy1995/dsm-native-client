using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsFolderSharing => SupportsManagement;
    private void RequireFolderSharing()
    {
        RequireAccess(SynologyPhotoSpace.Shared);
        if (!_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        _ = Capability("Browse.Folder", 2, SynologyPhotoSpace.Shared);
        _ = Capability("Sharing.FolderPermission", 1, SynologyPhotoSpace.Shared);
    }
    private static void ValidateSharingFolder(SynologyPhotoFolder folder)
    {
        ValidatePhotoFolder(folder);
        if (folder.Space != SynologyPhotoSpace.Shared || folder.ParentId <= 0 || folder.IsRoot ||
            folder.Path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length is not (1 or 2))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    public async Task<SynologyPhotoFolderSharing> FolderSharingAsync(SynologyPhotoFolder folder, CancellationToken cancellationToken = default)
    {
        ValidateSharingFolder(folder); RequireFolderSharing(); var generation = Volatile.Read(ref _accessGeneration);
        var current = await ReadFolderSharingAsync(folder.Id, cancellationToken).ConfigureAwait(false);
        if (!SamePhotoFolder(folder, current.Folder)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        RequireGeneration(generation, cancellationToken); return current;
    }
    private async Task<SynologyPhotoFolderSharing> ReadFolderSharingAsync(long id, CancellationToken token)
    {
        RequireFolderSharing(); var generation = Volatile.Read(ref _accessGeneration);
        var data = await ReadAsync("Browse.Folder", 2, "get", Parameters(("id", id),
            ("additional", new[] { "sharing_info", "access_permission" })), token, SynologyPhotoSpace.Shared).ConfigureAwait(false);
        var raw = Object(data["folder"]); var folder = PhotoFolder(raw, SynologyPhotoSpace.Shared); ValidateSharingFolder(folder);
        if (folder.Id != id) throw Invalid();
        var shared = Boolean(raw, "shared"); var info = Object(Object(raw["additional"])["sharing_info"]);
        var access = !shared ? SynologyPhotoFolderAccess.Management : OptionalText(info, "privacy_type") switch
        { "private" => SynologyPhotoFolderAccess.Invited, "public-view" => SynologyPhotoFolderAccess.View, "public-download" => SynologyPhotoFolderAccess.Download, _ => throw Invalid() };
        var link = OptionalText(info, "sharing_link");
        if (string.IsNullOrEmpty(link))
        {
            if (shared) throw Invalid();
            link = Text(await ReadAsync("Sharing.FolderPermission", 1, "get_folder_link", Parameters(("folder_id", id)), token, SynologyPhotoSpace.Shared).ConfigureAwait(false), "folder_link");
        }
        var url = SafeSharingUri(link) ?? throw Invalid();
        var config = await ReadAsync("Sharing.FolderPermission", 1, "get_config", cancellationToken: token, space: SynologyPhotoSpace.Shared).ConfigureAwait(false);
        var apply = Boolean(config, "set_to_subfolder");
        var parent = Object((await ReadAsync("Browse.Folder", 2, "get", Parameters(("id", folder.ParentId)), token, SynologyPhotoSpace.Shared).ConfigureAwait(false))["folder"]);
        var expectedParentPath = folder.Path[..folder.Path.LastIndexOf('/')]; if (expectedParentPath.Length == 0) expectedParentPath = "/";
        if (Positive(parent, "id") != folder.ParentId || Text(parent, "name") != expectedParentPath) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var parentShared = Boolean(parent, "shared");
        var revision = new JsonObject { ["profile"] = ProfileId.ToString(), ["id"] = id, ["path"] = folder.Path, ["parent"] = folder.ParentId,
            ["shared"] = shared, ["info"] = info.DeepClone(), ["parentShared"] = parentShared, ["apply"] = apply };
        RequireGeneration(generation, token); RequireFolderSharing();
        return new(ProfileId, folder, access, parentShared, apply, PhotoTextHash(CanonicalAlbumJson(revision)!.ToJsonString()))
        { Url = url, HasPassword = info["enable_password"] is null ? null : Boolean(info, "enable_password"), Members = ShareMembers(info["permission"]) };
    }
    private static string FolderPermissionHash(SynologyPhotoFolderSharing value) => PhotoTextHash(JsonSerializer.Serialize(new
    { value.Access, value.HasPassword, Members = ShareMembersHash(value.Members) }));
    private static SynologyPhotoFolderSharing ExpectedFolderSharing(SynologyPhotoFolderSharingEdit edit) => edit.Original with
    {
        Access = edit.Access, Members = edit.Members ?? edit.Original.Members, AppliesToSubfolders = edit.AppliesToSubfolders,
        HasPassword = edit.PasswordChange switch { SynologyPhotoPasswordChange.Replace => true, SynologyPhotoPasswordChange.Clear => false, _ => edit.Original.HasPassword },
    };
    private static void ValidateFolderSharingEdit(SynologyPhotoFolderSharingEdit edit)
    {
        ValidateSharingFolder(edit.Original.Folder);
        if (!Enum.IsDefined(edit.Access) || !Enum.IsDefined(edit.PasswordChange) || !UploadHash(edit.Original.Revision) ||
            edit.PasswordChange == SynologyPhotoPasswordChange.Replace && string.IsNullOrEmpty(edit.Password) ||
            edit.PasswordChange != SynologyPhotoPasswordChange.Replace && edit.Password is not null) throw Invalid();
        if (edit.Original.InheritsManagementOnly || edit.Original.Depth == 2 && edit.AppliesToSubfolders != edit.Original.AppliesToSubfolders)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (edit.Members is not { } members) return;
        if (edit.Original.Members is null || members.DistinctBy(item => item.Id).Count() != members.Count) throw Invalid();
        foreach (var member in members)
        {
            _ = ShareIdentityValue(member.Id);
            if (edit.Original.Members.SingleOrDefault(item => item.Id == member.Id)?.Role != member.Role && member.Role is not ("view" or "download" or "upload" or "manage")) throw Invalid();
        }
    }
    /// <summary>目录接口的成员是扁平结构；名单变化时所有保留成员也须更新。</summary>
    private static JsonArray FolderPermissionDelta(SynologyPhotoFolderSharingEdit edit)
    {
        var result = new JsonArray();
        if (edit.Members is not { } members || ShareMembersHash(members) == ShareMembersHash(edit.Original.Members)) return result;
        foreach (var old in edit.Original.Members!.Where(item => !members.Any(value => value.Id == item.Id))) AddMember(old, "delete");
        foreach (var member in members) AddMember(member, "update");
        return result;
        void AddMember(SynologyPhotoShareGrant member, string action) => result.Add(new JsonObject
        { ["id"] = ShareIdentityValue(member.Id), ["type"] = member.Id.Type, ["role"] = member.Role, ["action"] = action });
    }
}
