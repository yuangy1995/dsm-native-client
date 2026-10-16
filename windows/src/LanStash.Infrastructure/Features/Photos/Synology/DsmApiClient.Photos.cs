using System.Buffers;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    internal const int MaximumPhotoResponseBytes = 8 * 1024 * 1024;

    public async Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session,
        ApiCapability capability, int requiredVersion, string method,
        IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default)
        => SynologyPhotosCodec.Object(await CallPhotoDataAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken).ConfigureAwait(false));

    public async Task<JsonArray> CallPhotoArrayAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        int requiredVersion, string method, CancellationToken cancellationToken = default)
    {
        if ((capability.Name, requiredVersion, method) != ("SYNO.Foto.Setting.TeamSpace", 1, "list_permission"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        return await CallPhotoDataAsync(profile, session, capability, requiredVersion, method, null, cancellationToken).ConfigureAwait(false) as JsonArray ?? throw SynologyPhotosCodec.Invalid();
    }

    private async Task<JsonNode> CallPhotoDataAsync(NasProfile profile, DsmSession session,
        ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters, CancellationToken cancellationToken)
    {
        ValidatePhotoSession(profile, session);
        ValidatePhotoCapability(capability, requiredVersion);
        if (!IsRecordedPhotoCall(capability.Name, requiredVersion, method) || parameters?.Keys.Any(IsReservedReadParameter) == true)
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name, ["version"] = requiredVersion.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["method"] = method, ["_sid"] = session.Sid,
        };
        if (parameters is not null)
        {
            foreach (var (key, value) in parameters) values[key] = value;
        }
        // JSON 指业务参数；外层仍是表单。固定路由不接受能力响应注入的外部地址。
        using var request = PhotoRequest(profile, session, HttpMethod.Post,
            ResolveSafeApiUri(profile, $"entry.cgi/{capability.Name}"), "application/json");
        request.Content = CreateSessionFormContent(values, session);
        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        ValidatePhotoResponse(response, HttpStatusCode.OK);
        var bytes = await ReadBoundedPhotoBodyAsync(response.Content, MaximumPhotoResponseBytes, cancellationToken).ConfigureAwait(false);
        try
        {
            var envelope = JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 48 }) as JsonObject
                ?? throw SynologyPhotosCodec.Invalid();
            if (!SynologyPhotosCodec.Boolean(envelope, "success"))
            {
                var error = SynologyPhotosCodec.Object(envelope["error"]);
                throw MapFailure(SynologyPhotosCodec.Int(error, "code"));
            }
            return envelope["data"] ?? throw SynologyPhotosCodec.Invalid();
        }
        catch (JsonException) { throw SynologyPhotosCodec.Invalid(); }
    }

    public Task<byte[]> ReadPhotoThumbnailAsync(NasProfile profile, DsmSession session,
        SynologyPhotoThumbnail thumbnail, bool large, CancellationToken cancellationToken = default)
        => ReadPhotoThumbnailSizeAsync(profile, session, thumbnail, large ? SynologyPhotoThumbnailSize.Large : SynologyPhotoThumbnailSize.Medium, cancellationToken);

    public async Task<byte[]> ReadPhotoThumbnailSizeAsync(NasProfile profile, DsmSession session,
        SynologyPhotoThumbnail thumbnail, SynologyPhotoThumbnailSize size, CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session);
        if (!Enum.IsDefined(size) || thumbnail.UnitId <= 0 || thumbnail.AlbumId <= 0 || !Enum.IsDefined(thumbnail.Space) || thumbnail.FolderCoverSequence < 0 ||
            thumbnail.FolderCoverSequence is not null && thumbnail.AlbumId is not null || !Enum.IsDefined(thumbnail.Type) ||
            thumbnail.Type != SynologyPhotoThumbnailType.Unit && (thumbnail.AlbumId is not null || thumbnail.FolderCoverSequence is not null || !thumbnail.NativeSize)) throw SynologyPhotosCodec.Invalid();
        var values = SynologyPhotosCodec.Parameters(("id", thumbnail.UnitId), ("cache_key", thumbnail.Revision),
            ("type", "unit"), ("size", size switch { SynologyPhotoThumbnailSize.Small => "sm", SynologyPhotoThumbnailSize.Medium => "m", _ => "xl" }));
        if (thumbnail.FolderCoverSequence is { } sequence)
        { values["type"] = JsonSerializer.Serialize("folder"); values.Remove("size"); values["folder_cover_seq"] = JsonSerializer.Serialize(sequence); }
        if (thumbnail.Type == SynologyPhotoThumbnailType.Person) values["type"] = JsonSerializer.Serialize("person");
        if (thumbnail.Type == SynologyPhotoThumbnailType.Face) values["type"] = JsonSerializer.Serialize("face");
        if (thumbnail.NativeSize) values.Remove("size");
        if (thumbnail.AlbumId is { } albumId) values["album_id"] = JsonSerializer.Serialize(albumId);
        var source = thumbnail.AlbumId is null && thumbnail.Space == SynologyPhotoSpace.Shared ? "t" : "p";
        using var request = PhotoRequest(profile, session, HttpMethod.Get,
            PhotoQueryUri(profile, $"/synofoto/api/v2/{source}/Thumbnail/get", values), "image/*");
        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        ValidatePhotoResponse(response, HttpStatusCode.OK);
        if (response.Content.Headers.ContentType?.MediaType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) != true)
            throw PhotoMediaFailure();
        var bytes = await ReadBoundedPhotoBodyAsync(response.Content, MaximumPhotoResponseBytes, cancellationToken).ConfigureAwait(false);
        if (IsPhotoErrorBody(bytes)) throw PhotoMediaFailure();
        return bytes;
    }

    public async Task DownloadPhotoOriginalAsync(NasProfile profile, DsmSession session,
        SynologyPhotoMediaRequest media, string destination, long expectedBytes,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        => _ = await DownloadPhotoAsync(profile, session, media, destination, expectedBytes, false, progress, cancellationToken).ConfigureAwait(false);

    public async Task<SynologyPhotoBinaryResult> DownloadPhotoAsync(NasProfile profile, DsmSession session,
        SynologyPhotoMediaRequest media, string destination, long? expectedBytes, bool archive,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session);
        ValidatePhotoCapability(media.Capability, 2);
        ArgumentException.ThrowIfNullOrWhiteSpace(destination);
        if (expectedBytes < 0 || media.Capability.Name is not ("SYNO.Foto.Download" or "SYNO.FotoTeam.Download" or "SYNO.Foto.Browse.Album") || media.Method != "download" ||
            !archive && media.Capability.Name == "SYNO.Foto.Browse.Album" || media.Parameters.Keys.Any(IsReservedReadParameter))
            throw SynologyPhotosCodec.Invalid();
        var values = new Dictionary<string, string>(media.Parameters, StringComparer.Ordinal)
        { ["api"] = media.Capability.Name, ["version"] = "2", ["method"] = media.Method };
        // 下载统一使用能力路径与表单，协作相册口令不得进入 URL。
        using var request = PhotoRequest(profile, session, HttpMethod.Post, ResolveSafeApiUri(profile, media.Capability.Path),
            archive ? "application/zip, application/octet-stream" : "image/*, video/*, application/octet-stream");
        request.Content = CreateSessionFormContent(values, session);
        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        ValidatePhotoResponse(response, HttpStatusCode.OK);
        var contentType = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant() ?? "";
        if (archive)
        {
            if (contentType is not ("application/zip" or "application/x-zip-compressed")) ValidatePhotoBinaryType(response);
        }
        else ValidatePhotoBinaryType(response);
        var declared = response.Content.Headers.ContentLength;
        if (declared <= 0 || expectedBytes is { } expected && declared is { } length && length != expected)
            throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
        var limit = expectedBytes ?? declared;
        var created = false;
        var complete = false;
        try
        {
            // 目标为 Repository 提供的随机暂存文件。CreateNew 绝不覆盖已有文件。
            await using var destinationStream = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            created = true;
            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
            var done = 0L;
            var lastProgress = Environment.TickCount64;
            try
            {
                var prefix = new byte[64];
                var prefixLength = 0;
                while (prefixLength < prefix.Length)
                {
                    var count = await source.ReadAsync(prefix.AsMemory(prefixLength), cancellationToken).ConfigureAwait(false);
                    if (count == 0) break;
                    prefixLength += count;
                }
                if (prefixLength == 0 || (archive ? !IsPhotoZipHeader(prefix.AsSpan(0, prefixLength)) : IsPhotoErrorBody(prefix.AsSpan(0, prefixLength)))) throw PhotoMediaFailure();
                if (prefixLength > limit) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                await destinationStream.WriteAsync(prefix.AsMemory(0, prefixLength), cancellationToken).ConfigureAwait(false);
                done = prefixLength;
                progress?.Report(done);
                while (true)
                {
                    var count = await source.ReadAsync(buffer.AsMemory(0, buffer.Length), cancellationToken).ConfigureAwait(false);
                    if (count == 0) break;
                    if (count > limit - done) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                    await destinationStream.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
                    done += count;
                    if (Environment.TickCount64 - lastProgress >= 100 || done == limit)
                    {
                        progress?.Report(done);
                        lastProgress = Environment.TickCount64;
                    }
                }
                if (limit is { } total && done != total) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
                cancellationToken.ThrowIfCancellationRequested();
                await destinationStream.FlushAsync(cancellationToken).ConfigureAwait(false);
                progress?.Report(done);
                complete = true;
                return new(contentType, done);
            }
            finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
        }
        finally
        {
            if (created && !complete) File.Delete(destination);
        }
    }

    internal static bool IsPhotoZipHeader(ReadOnlySpan<byte> value) => value.Length >= 4 && value[0] == 0x50 && value[1] == 0x4b &&
        (value[2], value[3]) is (3, 4) or (5, 6) or (6, 6);

    private Uri PhotoMediaUri(NasProfile profile, SynologyPhotoMediaRequest media)
    {
        ValidatePhotoCapability(media.Capability, 2);
        if ((media.Capability.Name, media.Method) is not (("SYNO.Foto.Download" or "SYNO.FotoTeam.Download", "download") or ("SYNO.Foto.Streaming" or "SYNO.FotoTeam.Streaming", "streaming")) ||
            media.Parameters.Keys.Any(IsReservedReadParameter)) throw SynologyPhotosCodec.Invalid();
        var values = new Dictionary<string, string>(media.Parameters, StringComparer.Ordinal)
        {
            ["api"] = media.Capability.Name, ["version"] = "2", ["method"] = media.Method,
        };
        return PhotoQueryUri(profile, "/webapi/entry.cgi", values);
    }

    private Uri PhotoQueryUri(NasProfile profile, string path, IReadOnlyDictionary<string, string> values)
    {
        var basis = GetBaseUri(profile);
        if (!string.IsNullOrEmpty(basis.UserInfo)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var query = string.Join("&", values.Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        var result = new Uri(basis, $"{path}?{query}");
        if (result.Scheme != basis.Scheme || result.Host != basis.Host || result.Port != basis.Port)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return result;
    }

    private static HttpRequestMessage PhotoRequest(NasProfile profile, DsmSession session, HttpMethod method, Uri uri, string accept)
    {
        var request = new HttpRequestMessage(method, uri);
        request.Headers.Accept.ParseAdd(accept);
        request.Headers.AcceptEncoding.ParseAdd("identity");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken)) request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        return request;
    }

    private static void ValidatePhotoSession(NasProfile profile, DsmSession session)
    {
        if (profile.Id == Guid.Empty || profile.Id != session.ProfileId || string.IsNullOrWhiteSpace(session.Sid))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }

    private static void ValidatePhotoCapability(ApiCapability capability, int requiredVersion)
    {
        if ((!capability.Name.StartsWith("SYNO.Foto.", StringComparison.Ordinal) && !capability.Name.StartsWith("SYNO.FotoTeam.", StringComparison.Ordinal)) || requiredVersion < capability.MinVersion ||
            requiredVersion > capability.MaxVersion || !capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) ||
            capability.Path is not ("entry.cgi" or "webapi/entry.cgi" or "/webapi/entry.cgi"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }

    private static void ValidatePhotoResponse(HttpResponseMessage response, HttpStatusCode expected)
    {
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (response.StatusCode != expected || response.Content.Headers.ContentEncoding.Any(value => !value.Equals("identity", StringComparison.OrdinalIgnoreCase)))
            throw PhotoMediaFailure();
    }

    private static void ValidatePhotoBinaryType(HttpResponseMessage response)
    {
        var type = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant() ?? "";
        if (!type.StartsWith("image/", StringComparison.Ordinal) && !type.StartsWith("video/", StringComparison.Ordinal) &&
            type is not ("application/octet-stream" or "binary/octet-stream" or "application/force-download" or "application/download"))
            throw PhotoMediaFailure();
    }

    internal static bool IsPhotoErrorBody(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length == 0) return true;
        if (bytes.Length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) bytes = bytes[3..];
        while (bytes.Length > 0 && bytes[0] is 9 or 10 or 13 or 32) bytes = bytes[1..];
        return bytes.Length == 0 || bytes[0] is (byte)'<' or (byte)'{' or (byte)'[' || IsPhotoZipHeader(bytes) ||
            (bytes.Length >= 4 && bytes[0] == (byte)'P' && bytes[1] == (byte)'K' && (bytes[2], bytes[3]) is (7, 8) or (1, 2));
    }

    private static async Task<byte[]> ReadBoundedPhotoBodyAsync(HttpContent content, int maximumBytes, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is { } length && (length <= 0 || length > maximumBytes)) throw PhotoMediaFailure();
        await using var input = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            while (true)
            {
                var count = await input.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, maximumBytes - (int)output.Length + 1)), cancellationToken).ConfigureAwait(false);
                if (count == 0) break;
                if (count > maximumBytes - output.Length) throw PhotoMediaFailure();
                output.Write(buffer, 0, count);
            }
            if (output.Length == 0 || (content.Headers.ContentLength is { } declared && declared != output.Length)) throw PhotoMediaFailure();
            return output.ToArray();
        }
        finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
    }

    private static SynologyPhotoException PhotoMediaFailure() => new(SynologyPhotoFailure.Media);

    private static bool IsRecordedPhotoCall(string name, int version, string method) => (name, version, method) switch
    {
        ("SYNO.Foto.Index" or "SYNO.FotoTeam.Index" or "SYNO.Foto.Setting.Wizard", 1, "get") => true,
        ("SYNO.Foto.Upload.ConvertedFile" or "SYNO.FotoTeam.Upload.ConvertedFile", 3, "list_convert_needed") => true,
        ("SYNO.Foto.RegeneratePreview" or "SYNO.FotoTeam.RegeneratePreview", 1, "list_regenerating") => true,
        ("SYNO.Foto.Browse.Similar" or "SYNO.FotoTeam.Browse.Similar", 1, "get" or "get_status") => true,
        ("SYNO.Foto.Browse.SimilarItem" or "SYNO.FotoTeam.Browse.SimilarItem", 1, "get" or "list_similar") => true,
        ("SYNO.Foto.Browse.SimilarTimeline" or "SYNO.FotoTeam.Browse.SimilarTimeline", 1, "get_similar") => true,
        ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 6, "list_face") => true,
        ("SYNO.Foto.Browse.Person" or "SYNO.FotoTeam.Browse.Person", 1, "get" or "list_face") => true,
        ("SYNO.Foto.UserInfo", 1, "me") => true,
        ("SYNO.Foto.Setting.TeamSpace", 1, "list_permission") => true,
        ("SYNO.Foto.Setting.User" or "SYNO.Foto.Setting.Admin" or "SYNO.Foto.Setting.TeamSpace", 1, "get") => true,
        ("SYNO.Foto.Download", 2, "get_cache_status" or "calculate_cache_size") => true,
        ("SYNO.Foto.Browse.Timeline" or "SYNO.FotoTeam.Browse.Timeline", 5, "get") or ("SYNO.Foto.Browse.Timeline" or "SYNO.FotoTeam.Browse.Timeline", 3, "get_with_filter") => true,
        ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 4, "list") or ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 2, "list_with_filter") or ("SYNO.Foto.Browse.Item" or "SYNO.FotoTeam.Browse.Item", 5, "get") => true,
        ("SYNO.Foto.Browse.Folder" or "SYNO.FotoTeam.Browse.Folder", 2, "get" or "list") or ("SYNO.Foto.Browse.Album", 4, "list" or "get") => true,
        ("SYNO.Foto.Browse.NormalAlbum", 1, "list") or ("SYNO.Foto.Sharing.Passphrase", 1, "get_permission") => true,
        ("SYNO.Foto.Sharing.Misc", 1, "list_user_group") => true,
        ("SYNO.FotoTeam.Sharing.FolderPermission", 1, "get_folder_link" or "get_config") => true,
        ("SYNO.Foto.Browse.ConditionAlbum", 3, "get" or "suggest" or "peek_item_count") => true,
        ("SYNO.Foto.Browse.Album", 2, "get_album_list_order") or ("SYNO.Foto.Browse.Album", 3, "get_album_list_display") => true,
        ("SYNO.Foto.Browse.RecentlyAdded" or "SYNO.FotoTeam.Browse.RecentlyAdded" or "SYNO.Foto.Browse.Person" or "SYNO.FotoTeam.Browse.Person" or "SYNO.Foto.Browse.Geocoding" or "SYNO.FotoTeam.Browse.Geocoding" or "SYNO.Foto.Browse.GeneralTag" or "SYNO.FotoTeam.Browse.GeneralTag", 1, "list") => true,
        ("SYNO.Foto.Browse.Concept" or "SYNO.FotoTeam.Browse.Concept", 2, "list" or "get") or ("SYNO.Foto.Browse.Category", 3, "get") => true,
        ("SYNO.Foto.Search.Search" or "SYNO.FotoTeam.Search.Search", 2, "get_search_timeline") or ("SYNO.Foto.Search.Search" or "SYNO.FotoTeam.Search.Search", 1, "list_item") => true,
        ("SYNO.Foto.Search.Filter" or "SYNO.FotoTeam.Search.Filter", 3, "list") or ("SYNO.Foto.Sharing.Misc", 2, "list_shared_with_me_album") => true,
        ("SYNO.Foto.PhotoRequest", 1, "list") or ("SYNO.Foto.Browse.Unit" or "SYNO.FotoTeam.Browse.Unit", 1, "get") => true,
        ("SYNO.Foto.BackgroundTask.Info", 1, "get_status" or "list_user_task" or "get_error_detail") => true,
        _ => false,
    };
}
