using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    /// <summary>内部 Photos 写接口，明确区分拒绝和丢回执，不把读取或解析失败当作未提交。</summary>
    public async Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session,
        ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session); ValidatePhotoCapability(capability, requiredVersion);
        if ((capability.Name, requiredVersion, method) is not
            (("SYNO.Foto.Download" or "SYNO.FotoTeam.Download", 2, "convert") or
             ("SYNO.Foto.Index" or "SYNO.FotoTeam.Index", 1, "reindex") or
             ("SYNO.Foto.Index", 1, "reindex_all_user") or
             ("SYNO.Foto.Setting.Wizard", 1, "set") or
             ("SYNO.Foto.Upload.ConvertedFile" or "SYNO.FotoTeam.Upload.ConvertedFile", 3, "set_broken") or
             ("SYNO.Foto.Setting.User" or "SYNO.Foto.Setting.Admin", 1, "set") or
             ("SYNO.Foto.Download", 2, "clear_cache") or
             ("SYNO.Foto.Setting.TeamSpace", 1, "set" or "set_enable" or "update_permission") or
             ("SYNO.FotoTeam.Sharing.FolderBatchPermission", 1, "update_by_member" or "update_all_by_member") or
             ("SYNO.Foto.RegeneratePreview" or "SYNO.FotoTeam.RegeneratePreview", 1, "set_regenerating" or "regenerate_preview_by_nas" or "restore_from_regenerating") or
             ("SYNO.Foto.Browse.Similar" or "SYNO.FotoTeam.Browse.Similar", 1, "set_top_pick" or "remove_item" or "ungroup" or "add_item") or
             ("SYNO.Foto.Browse.Folder" or "SYNO.FotoTeam.Browse.Folder", 1, "create" or "rename" or "set_order") or
             ("SYNO.Foto.Browse.Folder" or "SYNO.FotoTeam.Browse.Folder", 2, "set_cover") or
             ("SYNO.Foto.BackgroundTask.File" or "SYNO.FotoTeam.BackgroundTask.File", 1, "copy" or "move" or "delete") or
             ("SYNO.Foto.BackgroundTask.Info", 1, "abort_task" or "clear_completed_task") or
             ("SYNO.Foto.Browse.NormalAlbum", 1, "create" or "copy" or "add_item" or "delete_item" or "set_unfreeze") or
             ("SYNO.Foto.Browse.ConditionAlbum", 3, "create" or "set_condition") or
             ("SYNO.Foto.Sharing.Passphrase", 1, "set_shared" or "update") or
             ("SYNO.Foto.PhotoRequest", 1, "create" or "update" or "delete") or
             ("SYNO.FotoTeam.Sharing.FolderPermission", 1, "update" or "set_config") or
             ("SYNO.Foto.Browse.Person" or "SYNO.FotoTeam.Browse.Person", 1, "set" or "show" or "delete_face" or "separate" or "set_cover") or
             ("SYNO.Foto.Browse.Person" or "SYNO.FotoTeam.Browse.Person", 2, "merge") or
             ("SYNO.Foto.Browse.Person" or "SYNO.FotoTeam.Browse.Person", 3, "add_face") or
             ("SYNO.Foto.Browse.Concept" or "SYNO.FotoTeam.Browse.Concept", 2, "set_visibility") or
             ("SYNO.Foto.Browse.Concept" or "SYNO.FotoTeam.Browse.Concept", 1, "set_cover" or "hide_item") or
             ("SYNO.Foto.Browse.Album", 1, "set_name" or "delete" or "set_cover" or "set_order") or
             ("SYNO.Foto.Browse.Album", 2, "set_album_list_order") or ("SYNO.Foto.Browse.Album", 3, "set_album_list_display") or
             ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 2, "set") or
             ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 1, "add_tag" or "remove_tag") or
             ("SYNO.Foto.Browse.GeneralTag" or "SYNO.FotoTeam.Browse.GeneralTag", 1, "create")) || parameters.Keys.Any(key =>
                 IsReservedReadParameter(key) && !(key == "password" && capability.Name is "SYNO.Foto.Sharing.Passphrase" or "SYNO.FotoTeam.Sharing.FolderPermission" && requiredVersion == 1 && method == "update")))
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (capability.Name == "SYNO.Foto.BackgroundTask.Info" && !ValidPhotoBackgroundControl(method, parameters)) throw SynologyPhotosCodec.Invalid();
        var fields = new Dictionary<string, string>(parameters, StringComparer.Ordinal)
        { ["api"] = capability.Name, ["version"] = requiredVersion.ToString(CultureInfo.InvariantCulture), ["method"] = method };
        using var request = PhotoRequest(profile, session, HttpMethod.Post,
            ResolveSafeApiUri(profile, $"entry.cgi/{capability.Name}"), "application/json");
        request.Content = CreateSessionFormContent(fields, session);
        SetNasConnectionContext(request, profile);
        cancellationToken.ThrowIfCancellationRequested();
        return await SendPhotoWriteAsync(request, cancellationToken,
            strictReceipt: capability.Name is "SYNO.Foto.Upload.ConvertedFile" or "SYNO.FotoTeam.Upload.ConvertedFile" or "SYNO.Foto.Setting.User" or "SYNO.Foto.Setting.TeamSpace" or "SYNO.Foto.Setting.Admin" or "SYNO.FotoTeam.Sharing.FolderBatchPermission" or "SYNO.Foto.Index" or "SYNO.FotoTeam.Index" or "SYNO.Foto.Setting.Wizard" or "SYNO.Foto.BackgroundTask.Info" || method == "clear_cache").ConfigureAwait(false);
    }

    private static bool ValidPhotoBackgroundControl(string method, IReadOnlyDictionary<string, string> parameters)
    {
        if (parameters.Count != 1 || !parameters.TryGetValue("id", out var value)) return false;
        try
        {
            var node = JsonNode.Parse(value);
            if (method == "clear_completed_task") return node is JsonValue number && number.TryGetValue<long>(out var id) && id > 0;
            if (method != "abort_task" || node is not JsonArray { Count: > 0 } ids) return false;
            var seen = new HashSet<long>();
            return ids.All(item => item is JsonValue number && number.TryGetValue<long>(out var id) && id > 0 && seen.Add(id));
        }
        catch (JsonException) { return false; }
    }

    public async Task<SynologyPhotoWriteReceipt> UploadPhotoAsync(NasProfile profile, DsmSession session,
        ApiCapability capability, SynologyPhotoUploadTransport upload, Stream source, IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session); ValidatePhotoCapability(capability, 1);
        if (capability.Name is not ("SYNO.Foto.Upload.Item" or "SYNO.FotoTeam.Upload.Item") ||
            upload.Length <= 0 || string.IsNullOrWhiteSpace(upload.Name) || !Enum.IsDefined(upload.Duplicate) ||
            upload.FolderId <= 0 || upload.AlbumId <= 0 ||
            (upload.FolderId is not null && (upload.AlbumId is not null || upload.AlbumPassphrase is not null)) ||
            (upload.AlbumPassphrase is not null && upload.AlbumId is not null) ||
            (capability.Name.StartsWith("SYNO.FotoTeam.", StringComparison.Ordinal) && (upload.AlbumId is not null || upload.AlbumPassphrase is not null)))
            throw SynologyPhotosCodec.Invalid();
        var fields = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name, ["version"] = "1", ["method"] = upload.FolderId is null ? "upload" : "upload_to_folder",
            ["name"] = JsonSerializer.Serialize(upload.Name), ["mtime"] = upload.ModifiedAt.ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture),
            ["duplicate"] = JsonSerializer.Serialize(upload.Duplicate == SynologyPhotoDuplicatePolicy.Skip ? "ignore" : "rename"),
        };
        if (upload.FolderId is { } folder) fields["target_folder_id"] = JsonSerializer.Serialize(folder);
        else
        {
            fields["folder"] = "[\"PhotoLibrary\"]";
            if (upload.AlbumPassphrase is { Length: > 0 } passphrase) fields["passphrase"] = JsonSerializer.Serialize(passphrase);
            else if (upload.AlbumId is { } album) fields["album_id"] = JsonSerializer.Serialize(album);
            else fields["uploadDestination"] = "\"timeline\"";
        }
        using var request = PhotoRequest(profile, session, HttpMethod.Post, ResolveSafeApiUri(profile, "entry.cgi"), "application/json");
        request.Content = new ExactLengthMultipartUploadContent($"LanStash-Photos-{Guid.NewGuid():N}", fields.ToArray(),
            "upload", source, upload.Length, progress);
        SetNasConnectionContext(request, profile);
        cancellationToken.ThrowIfCancellationRequested();
        return await SendPhotoWriteAsync(request, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>内部手工人脸缩略图接口；只使用本次新增回执中的编号，禁止自动重放。</summary>
    public async Task<SynologyPhotoWriteReceipt> UploadPhotoFaceAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        long faceId, byte[] jpeg, CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session); ValidatePhotoCapability(capability, 1);
        if (capability.Name is not ("SYNO.Foto.Upload.Face" or "SYNO.FotoTeam.Upload.Face") || faceId <= 0 ||
            jpeg is not { Length: >= 3 and <= MaximumPhotoResponseBytes } || jpeg[0] != 255 || jpeg[1] != 216 || jpeg[2] != 255)
            throw SynologyPhotosCodec.Invalid();
        var fields = new Dictionary<string, string>(StringComparer.Ordinal)
        { ["api"] = capability.Name, ["method"] = "upload", ["version"] = "1", ["face_id"] = faceId.ToString(CultureInfo.InvariantCulture) };
        using var source = new MemoryStream(jpeg, false);
        using var request = PhotoRequest(profile, session, HttpMethod.Post, ResolveSafeApiUri(profile, capability.Path), "application/json");
        request.Content = new ExactLengthMultipartUploadContent($"LanStash-Face-{Guid.NewGuid():N}", fields.ToArray(),
            "face.jpg", source, jpeg.Length, null, contentType: "image/jpeg");
        SetNasConnectionContext(request, profile); cancellationToken.ThrowIfCancellationRequested();
        return await SendPhotoWriteAsync(request, cancellationToken).ConfigureAwait(false);
    }

    private async Task<SynologyPhotoWriteReceipt> SendPhotoWriteAsync(HttpRequestMessage request, CancellationToken token, bool strictReceipt = false)
    {
        try
        {
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                return new(SynologyPhotoWriteStatus.Rejected, Failure: SynologyPhotoFailure.Permission);
            ValidatePhotoResponse(response, HttpStatusCode.OK);
            var bytes = await ReadBoundedPhotoBodyAsync(response.Content, MaximumPhotoResponseBytes, token).ConfigureAwait(false);
            var envelope = SynologyPhotosCodec.Object(JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 48 }));
            if (!SynologyPhotosCodec.Boolean(envelope, "success"))
            {
                var error = SynologyPhotosCodec.Object(envelope["error"]);
                var code = SynologyPhotosCodec.Int(error, "code");
                if (code == 117) return new(SynologyPhotoWriteStatus.Unknown);
                return new(SynologyPhotoWriteStatus.Rejected, Failure: code switch
                { 105 => SynologyPhotoFailure.Permission, 106 or 107 or 119 => SynologyPhotoFailure.SessionExpired, _ => SynologyPhotoFailure.WriteFailed });
            }
            if (strictReceipt && envelope["error"] is not null) return new(SynologyPhotoWriteStatus.Unknown);
            return new(SynologyPhotoWriteStatus.Accepted, envelope["data"] is null ? new() : SynologyPhotosCodec.Object(envelope["data"]));
        }
        catch (Exception error) when (error is HttpRequestException or IOException or OperationCanceledException or ObjectDisposedException or JsonException or SynologyPhotoException)
        { return new(SynologyPhotoWriteStatus.Unknown); }
    }
}
