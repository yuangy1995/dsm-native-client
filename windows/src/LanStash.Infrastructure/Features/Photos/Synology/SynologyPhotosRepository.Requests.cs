using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsRequestManagement => SupportsManagement;
    private void RequirePhotoRequests()
    {
        RequireAccess();
        if (!_personalAllowed && !_sharedAllowed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    public async Task<SynologyPhotoRequest> PhotoRequestAsync(string id, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(id)) throw Invalid();
        return await FindPhotoRequestAsync(PhotoTextHash(id), cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
    private async Task<SynologyPhotoRequest?> FindPhotoRequestAsync(string targetHash, CancellationToken token)
    {
        RequirePhotoRequests(); var generation = Volatile.Read(ref _accessGeneration); var seen = new HashSet<string>(StringComparer.Ordinal);
        for (var offset = 0; ;)
        {
            var payload = await ReadAsync("PhotoRequest", 1, "list", Parameters(("offset", offset), ("limit", 500)), token, null).ConfigureAwait(false);
            RequireGeneration(generation, token); RequirePhotoRequests(); var page = List(payload);
            if (page.Length > 500) throw Invalid();
            foreach (var item in page)
            { var id = Text(item, "passphrase"); if (id.Length == 0 || !seen.Add(id)) throw Invalid(); }
            var raw = page.SingleOrDefault(item => PhotoTextHash(Text(item, "passphrase")) == targetHash);
            if (raw is not null) return DecodePhotoRequest(raw);
            if (page.Length < 500) return null;
            offset = checked(offset + page.Length);
        }
    }
    private SynologyPhotoRequest DecodePhotoRequest(JsonObject item)
    {
        var space = Text(item, "library") switch
        { "personal_space" => SynologyPhotoSpace.Personal, "shared_space" => SynologyPhotoSpace.Shared, _ => throw Invalid() };
        var albumPassphrase = OptionalText(item, "album_passphrase"); if (albumPassphrase == "") albumPassphrase = null;
        var expiration = Number(item, "expiration"); var size = Number(item, "filesize_limit");
        if (expiration < 0 || size < 0 || Text(item, "passphrase").Length == 0) throw Invalid();
        long? Id(string field) => item[field] is null ? null : Number(item, field) is var value && value > 0 ? value : null;
        return new(ProfileId, Text(item, "passphrase"), new(Text(item, "subject"), Text(item, "description"), space, Text(item, "folder_home_path"))
        {
            FolderId = Id("folder_id"), AlbumId = albumPassphrase is null ? Id("album_id") : null,
            AlbumPassphrase = albumPassphrase, Expiration = expiration, SizeLimit = size,
        }, Boolean(item, "is_folder_valid"), OptionalText(item, "album_name"), SafeSharingUri(OptionalText(item, "sharing_link")));
    }
    public async Task<IReadOnlyList<SynologyPhotoRequestAlbum>> PhotoRequestAlbumsAsync(CancellationToken cancellationToken = default)
    {
        RequirePhotoRequests(); if (_currentUserId is null) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var generation = Volatile.Read(ref _accessGeneration); var seen = new HashSet<long>(); var result = new List<SynologyPhotoRequestAlbum>();
        for (var offset = 0; ;)
        {
            var payload = await ReadAsync("Browse.NormalAlbum", 1, "list", Parameters(("category", "addable"), ("offset", offset), ("limit", 500),
                ("sort_by", "album_name"), ("sort_direction", "asc"), ("additional", new[] { "sharing_info", "thumbnail" })), cancellationToken, null).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken); RequirePhotoRequests(); var page = List(payload);
            if (page.Length > 500) throw Invalid();
            foreach (var item in page)
            {
                var id = Positive(item, "id"); if (!seen.Add(id)) throw Invalid();
                var owner = Number(item, "owner_user_id"); if (owner < 0) throw Invalid(); var shared = Boolean(item, "shared");
                if (Permission(item, "freeze_album")) continue;
                var passphrase = owner == _currentUserId ? null : OptionalText(OptionalObject(OptionalObject(item, "additional") ?? new(), "sharing_info") ?? new(), "passphrase");
                if (owner != _currentUserId && string.IsNullOrEmpty(passphrase)) throw Invalid();
                result.Add(new(id, owner == _currentUserId ? id : null, passphrase, Text(item, "name"), shared));
            }
            if (page.Length < 500) return result;
            offset = checked(offset + page.Length);
        }
    }
    private static string RequestSettingsHash(SynologyPhotoRequestSettings settings, bool ignoreFolderId) =>
        PhotoTextHash(JsonSerializer.Serialize(ignoreFolderId ? settings with { FolderId = null } : settings));
    private static string RequestSnapshotHash(SynologyPhotoRequest value) => PhotoTextHash(JsonSerializer.Serialize(value));
    private static Dictionary<string, string> RequestParameters(SynologyPhotoRequestSettings settings)
    {
        var result = Parameters(("subject", settings.Subject), ("description", settings.Description),
            ("library", settings.Space == SynologyPhotoSpace.Personal ? "personal_space" : "shared_space"), ("folder_home_path", settings.FolderPath),
            ("expiration", settings.Expiration), ("filesize_limit", settings.SizeLimit));
        if (settings.AlbumPassphrase is { } passphrase) Add(result, Parameters(("album_passphrase", passphrase)));
        else if (settings.AlbumId is { } id) Add(result, Parameters(("album_id", id)));
        return result;
    }
    private static Dictionary<string, string> RequestDelta(SynologyPhotoRequestSettings original, SynologyPhotoRequestSettings desired)
    {
        var old = RequestParameters(original); var next = RequestParameters(desired);
        var result = next.Where(pair => !old.TryGetValue(pair.Key, out var value) || value != pair.Value).ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        if (original.Space != desired.Space || original.FolderPath != desired.FolderPath)
        { result["library"] = next["library"]; result["folder_home_path"] = next["folder_home_path"]; }
        if (original.AlbumId != desired.AlbumId || original.AlbumPassphrase != desired.AlbumPassphrase)
        {
            if (desired.AlbumPassphrase is { } passphrase) { Add(result, Parameters(("album_passphrase", passphrase))); result.Remove("album_id"); }
            else { Add(result, Parameters(("album_id", desired.AlbumId ?? -1))); result.Remove("album_passphrase"); }
        }
        return result;
    }
    private async Task<long?> ValidateRequestSettingsAsync(SynologyPhotoRequestSettings settings, Guid operationId, CancellationToken token)
    {
        if (!settings.IsValid) throw Invalid(); RequireAccess(settings.Space);
        var folder = PhotoFolder(await ReadPhotoFolderAsync(settings.FolderId, settings.Space, PhotoFolderRight.Upload, token).ConfigureAwait(false), settings.Space);
        if (settings.FolderId is not null)
        { if (folder.Path != settings.FolderPath) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged); }
        else if (!folder.IsRoot || settings.FolderPath != SynologyPhotoRequestSettings.DefaultFolderPath(settings.Subject) ||
            settings.Space == SynologyPhotoSpace.Shared && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        await CheckManagedFolderConflictsAsync(folder.Id, settings.Space, null, token).ConfigureAwait(false);
        if (settings.FolderId is null) CheckFolderSharingLocks(folder with { Path = settings.FolderPath });
        if (settings.AlbumId is null && settings.AlbumPassphrase is null) return null;
        var choices = await PhotoRequestAlbumsAsync(token).ConfigureAwait(false);
        var matching = choices.Where(item => item.AlbumId == settings.AlbumId && item.Passphrase == settings.AlbumPassphrase).ToArray();
        if (matching.Length != 1) throw new SynologyPhotoException(SynologyPhotoFailure.Permission); var album = matching[0];
        await CheckAlbumBusyAsync(album.Id, token, operationId).ConfigureAwait(false); return album.Id;
    }
}
