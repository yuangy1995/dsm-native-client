using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsSharingManagement => SupportsManagement;
    private static SynologyPhotoShareIdentity? ShareIdentity(string type, JsonNode? value)
    {
        if (type is not ("user" or "group") || value is not JsonValue scalar) return null;
        if (scalar.TryGetValue<string>(out var text)) return string.IsNullOrEmpty(text) ? null : new(type, text);
        return scalar.TryGetValue<long>(out var number) && number > 0 ? new(type, number.ToString(CultureInfo.InvariantCulture), true) : null;
    }
    private static JsonNode ShareIdentityValue(SynologyPhotoShareIdentity id)
    {
        if (id.Type is not ("user" or "group") || string.IsNullOrEmpty(id.Value)) throw Invalid();
        if (!id.Numeric) return JsonValue.Create(id.Value)!;
        if (!long.TryParse(id.Value, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number <= 0 || number.ToString(CultureInfo.InvariantCulture) != id.Value) throw Invalid();
        return JsonValue.Create(number)!;
    }
    private static SynologyPhotoShareRecipient ShareRecipient(JsonObject item) => new(
        ShareIdentity(Text(item, "type"), item["id"]) ?? throw Invalid(), Text(item, "name"));
    private static IReadOnlyList<SynologyPhotoShareGrant>? ShareMembers(JsonNode? node)
    {
        if (node is not JsonArray list) return null;
        try
        {
            var result = list.Select(Object).Where(item => OptionalText(item, "type") != "public")
                .Select(item => new SynologyPhotoShareGrant(ShareRecipient(item), Text(item, "role"))).ToArray();
            return result.DistinctBy(item => item.Id).Count() == result.Length ? result : null;
        }
        catch (SynologyPhotoException) { return null; }
    }
    private static long? ShareExpiration(JsonNode? node)
    {
        if (node is not JsonValue scalar) return null;
        if (scalar.TryGetValue<long>(out var value)) return value >= 0 ? value : null;
        if (scalar.TryGetValue<decimal>(out var number) && number >= 0 && number <= long.MaxValue && decimal.Truncate(number) == number) return (long)number;
        return null;
    }
    private SynologyPhotoSharing SharingSnapshot(JsonObject raw)
    {
        var album = AlbumSnapshot(raw); if (!album.IsOwner) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var info = OptionalObject(OptionalObject(raw, "additional") ?? new(), "sharing_info");
        var configured = OptionalText(info ?? new(), "privacy_type") switch
        { "private" => SynologyPhotoLinkAccess.Invited, "public-view" => SynologyPhotoLinkAccess.View, "public-download" => SynologyPhotoLinkAccess.Download, _ => (SynologyPhotoLinkAccess?)null };
        var access = album.Shared == false ? SynologyPhotoLinkAccess.Disabled : album.Shared == true ? configured ?? throw Invalid() : throw Invalid();
        var revision = new JsonObject { ["id"] = raw["id"]?.DeepClone(), ["shared"] = raw["shared"]?.DeepClone(), ["temporary"] = raw["temporary_shared"]?.DeepClone(), ["info"] = info?.DeepClone() };
        return new(album, access, PhotoTextHash(CanonicalAlbumJson(revision)!.ToJsonString()))
        {
            ConfiguredAccess = configured, Url = access == SynologyPhotoLinkAccess.Disabled ? null : SafeSharingUri(OptionalText(info ?? new(), "sharing_link")),
            HasPassword = info?["enable_password"] is null ? null : Boolean(info, "enable_password"),
            Expiration = ShareExpiration(info?["expiration"]), Members = ShareMembers(info?["permission"]),
            Temporary = raw["temporary_shared"] is null ? null : Boolean(raw, "temporary_shared"),
        };
    }
    public async Task<SynologyPhotoSharing> AlbumSharingAsync(long id, CancellationToken cancellationToken = default)
    {
        RequireAccess(SynologyPhotoSpace.Personal);
        return SharingSnapshot(await ReadAlbumRawAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged));
    }
    public async Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharingRecipientsAsync(bool sharedFolder = false, CancellationToken cancellationToken = default)
    {
        RequireAccess(sharedFolder ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal);
        if (sharedFolder && !_managesSharedSpace || _currentUserUid is null) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var generation = Volatile.Read(ref _accessGeneration);
        var info = await ReadAsync("UserInfo", 1, "me", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        if (ShareIdentity("user", info["uid"]) != _currentUserUid) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var rows = List(await ReadAsync("Sharing.Misc", 1, "list_user_group", Parameters(("team_space_sharable_list", sharedFolder)), cancellationToken, null).ConfigureAwait(false));
        var all = rows.Select(ShareRecipient).ToArray();
        if (all.DistinctBy(item => item.Id).Count() != all.Length) throw Invalid();
        RequireGeneration(generation, cancellationToken); return all.Where(item => item.Id != _currentUserUid).ToArray();
    }
    private static string? ShareMembersHash(IReadOnlyList<SynologyPhotoShareGrant>? members) => members is null ? null :
        PhotoTextHash(JsonSerializer.Serialize(members.OrderBy(item => item.Id.Type, StringComparer.Ordinal).ThenBy(item => item.Id.Numeric)
            .ThenBy(item => item.Id.Value, StringComparer.Ordinal).Select(item => new { item.Id, item.Role })));
    private static string ShareConfigHash(SynologyPhotoSharing value) => PhotoTextHash(JsonSerializer.Serialize(new
    { value.ConfiguredAccess, value.HasPassword, value.Expiration, Members = ShareMembersHash(value.Members) }));
    private static SynologyPhotoSharing ExpectedSharing(SynologyPhotoSharingEdit edit) => edit.Original with
    {
        Access = edit.Access, ConfiguredAccess = edit.Access == SynologyPhotoLinkAccess.Disabled ? edit.Original.ConfiguredAccess : edit.Access,
        Members = edit.Members ?? edit.Original.Members, Expiration = edit.Expiration ?? edit.Original.Expiration,
        HasPassword = edit.PasswordChange switch { SynologyPhotoPasswordChange.Replace => true, SynologyPhotoPasswordChange.Clear => false, _ => edit.Original.HasPassword },
    };
    private static bool SharingConfigChanged(SynologyPhotoSharingEdit edit) => ShareConfigHash(edit.Original) != ShareConfigHash(ExpectedSharing(edit)) || edit.PasswordChange != SynologyPhotoPasswordChange.Keep;
    private static void ValidateSharingEdit(SynologyPhotoSharingEdit edit)
    {
        if (!Enum.IsDefined(edit.Access) || !Enum.IsDefined(edit.PasswordChange) || !UploadHash(edit.Original.Revision) ||
            edit.Original.Album.Id <= 0 || edit.Original.Album.ProfileId == Guid.Empty || edit.Expiration < 0 ||
            edit.PasswordChange == SynologyPhotoPasswordChange.Replace && string.IsNullOrEmpty(edit.Password) ||
            edit.PasswordChange != SynologyPhotoPasswordChange.Replace && edit.Password is not null) throw Invalid();
        if (edit.Members is null) return;
        if (edit.Original.Members is null || edit.Members.DistinctBy(item => item.Id).Count() != edit.Members.Count) throw Invalid();
        foreach (var member in edit.Members)
        {
            _ = ShareIdentityValue(member.Id);
            if (edit.Original.Members.SingleOrDefault(item => item.Id == member.Id)?.Role != member.Role &&
                (member.Role is not ("view" or "download" or "upload") || edit.Original.Album.Conditional && member.Role == "upload")) throw Invalid();
        }
    }
    private static JsonArray SharingMemberDelta(SynologyPhotoSharingEdit edit)
    {
        var result = new JsonArray();
        if (edit.Members is { } members)
        {
            foreach (var old in edit.Original.Members!.Where(item => !members.Any(value => value.Id == item.Id))) AddMember(old, true);
            foreach (var member in members.Where(item => edit.Original.Members!.SingleOrDefault(value => value.Id == item.Id)?.Role != item.Role)) AddMember(member, false);
        }
        if (edit.Access != SynologyPhotoLinkAccess.Disabled && edit.Access != edit.Original.Access)
        {
            var item = new JsonObject { ["action"] = edit.Access == SynologyPhotoLinkAccess.Invited ? "delete" : "update", ["member"] = new JsonObject { ["type"] = "public" } };
            if (edit.Access != SynologyPhotoLinkAccess.Invited) item["role"] = edit.Access == SynologyPhotoLinkAccess.View ? "view" : "download";
            result.Add(item);
        }
        return result;
        void AddMember(SynologyPhotoShareGrant grant, bool remove)
        {
            var item = new JsonObject { ["action"] = remove ? "delete" : "update", ["member"] = new JsonObject { ["type"] = grant.Id.Type, ["id"] = ShareIdentityValue(grant.Id) } };
            if (!remove) item["role"] = grant.Role; result.Add(item);
        }
    }
}
