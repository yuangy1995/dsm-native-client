using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static void ValidateUploadTarget(SynologyPhotoUploadTarget target)
    {
        if (!Enum.IsDefined(target.Space) || !Enum.IsDefined(target.Duplicate) || target.FolderId <= 0 || target.AlbumId <= 0 ||
            target.DirectToAlbum && (target.AlbumId is null || target.FolderId is not null)) throw Invalid();
    }
    public async Task<IReadOnlyList<SynologyPhotoCollection>> AddableAlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("category", "addable"), ("sort_by", "album_name"), ("sort_direction", "asc"), ("additional", new[] { "sharing_info", "thumbnail" })));
        var data = await ReadAsync("Browse.NormalAlbum", 1, "list", parameters, cancellationToken, null).ConfigureAwait(false);
        var entries = List(data);
        if (entries.Any(entry => Text(entry, "type") == "condition")) throw Invalid();
        // 不在分页层过滤冻结行，防止改变服务端 offset；权限在选中后逐次读取。
        return Collections(data, limit);
    }
    public async Task PrepareUploadAsync(SynologyPhotoUploadTarget target, CancellationToken cancellationToken = default)
    { _ = await PrepareUploadTargetAsync(target, cancellationToken).ConfigureAwait(false); }
    private async Task<(SynologyPhotoCollection? Root, PhotoAlbumSnapshot? Album)> PrepareUploadTargetAsync(
        SynologyPhotoUploadTarget target, CancellationToken token)
    {
        ValidateUploadTarget(target); RequireAccess(target.DirectToAlbum ? null : target.Space);
        _ = Capability("Upload.Item", 1, target.DirectToAlbum ? null : target.Space);
        PhotoAlbumSnapshot? album = null;
        if (target.AlbumId is { } albumId)
        {
            await CheckAlbumBusyAsync(albumId, token).ConfigureAwait(false);
            var rights = await ReadContributingAlbumAsync(albumId, token).ConfigureAwait(false); album = rights.Snapshot;
            if (!target.DirectToAlbum) _ = Capability("Browse.NormalAlbum", 1, null);
        }
        SynologyPhotoCollection? root = null;
        if (!target.DirectToAlbum) root = await WritableUploadFolderAsync(target.FolderId, target.Space, token).ConfigureAwait(false);
        return (root, album);
    }
    private async Task<SynologyPhotoCollection> WritableUploadFolderAsync(long? id, SynologyPhotoSpace space, CancellationToken token)
    {
        var folder = await ReadPhotoFolderAsync(id, space, PhotoFolderRight.Upload, token).ConfigureAwait(false);
        return Collection(folder, true) with { Space = space, Path = null };
    }
    private sealed record ContributingAlbum(PhotoAlbumSnapshot Snapshot, string? Passphrase);
    private async Task<ContributingAlbum> ReadContributingAlbumAsync(long id, CancellationToken token)
    {
        RequirePositive(id);
        var data = await ReadAsync("Browse.Album", 4, "get", Parameters(("id", new[] { id }), ("additional", new[] { "sharing_info" })), token, null).ConfigureAwait(false);
        var entries = List(data);
        if (entries.Length != 1 || Positive(entries[0], "id") != id || _currentUserId is not > 0) throw Invalid();
        return await ReadContributingAlbumAsync(entries[0], token).ConfigureAwait(false);
    }
    private async Task<ContributingAlbum> ReadContributingAlbumAsync(JsonObject album, CancellationToken token)
    {
        var id = Positive(album, "id"); var owner = Positive(album, "owner_user_id");
        if (_currentUserId is not > 0) throw Invalid();
        if (Text(album, "type") == "condition" || Permission(album, "freeze_album")) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var snapshot = new PhotoAlbumSnapshot(id, owner, _currentUserId.Value);
        if (owner == _currentUserId) return new(snapshot, null);
        var sharing = OptionalObject(OptionalObject(album, "additional") ?? new(), "sharing_info");
        var passphrase = OptionalText(album, "passphrase") ?? (sharing is null ? null : OptionalText(sharing, "passphrase"));
        if (string.IsNullOrWhiteSpace(passphrase)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var permission = await ReadAsync("Sharing.Passphrase", 1, "get_permission", Parameters(("passphrase", passphrase), ("exclude_public", false)), token, null).ConfigureAwait(false);
        if (!Permission(Object(permission["permission"]), "upload")) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(snapshot, passphrase);
    }
    private async Task<ContributingAlbum?> CheckUploadTargetAsync(PhotoUploadTask task, CancellationToken token)
    {
        RequireAccess(task.Record.Target.DirectToAlbum ? null : task.Record.Target.Space);
        if (task.Record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (task.Record.Root is { } expected)
        {
            await CheckManagedFolderConflictsAsync(expected.Id, task.Record.Target.Space, null, token).ConfigureAwait(false);
            var current = await WritableUploadFolderAsync(expected.Id, task.Record.Target.Space, token).ConfigureAwait(false);
            if (current.Id != expected.Id || current.ParentId != expected.ParentId || current.Name != expected.Name)
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        if (task.Record.Album is not { } album) return null;
        await CheckAlbumBusyAsync(album.Id, token).ConfigureAwait(false);
        var rights = await ReadContributingAlbumAsync(album.Id, token).ConfigureAwait(false);
        if (rights.Snapshot != album) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return rights;
    }
}
