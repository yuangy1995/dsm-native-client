using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<DsmBinaryResponse> ReadFileStationDefaultBackgroundAsync(NasProfile profile, DsmSession session, string filename, int maximumBytes, CancellationToken token = default)
    {
        if (profile.Id != session.ProfileId || string.IsNullOrEmpty(session.Sid) || !FileStationThemeImage.Defaults.Any(v => v.Path == filename))
            throw new ArgumentException("file.theme.default.invalid");
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumBytes, 1);
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(GetBaseUri(profile), "/webman/resources/images/1x/default_login_background/" + filename));
        request.Headers.Accept.ParseAdd("image/*"); SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        return await ReadBoundedBinaryContentAsync(response.Content, "image/", maximumBytes, token).ConfigureAwait(false);
    }

    public async Task<FileStationThemeUploadTransportResult> UploadFileStationThemeImageAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        FileStationThemeImageKind kind, string filename, ReadOnlyMemory<byte> bytes, CancellationToken token = default)
    {
        if (profile.Id != session.ProfileId || string.IsNullOrEmpty(session.Sid) || capability.Name != "SYNO.Core.Theme.Image" || capability.MinVersion > 1 || capability.MaxVersion < 1)
            return new(false, false, Error: MutationErrorCategory.Unsupported);
        if (!Enum.IsDefined(kind) || bytes.IsEmpty || !FileStationThemeImage.SupportsFilename(filename) || filename.Any(c => char.IsControl(c) || c is '"' or '/' or '\\'))
            return new(false, false, Error: MutationErrorCategory.Validation);
        Uri uri;
        try { uri = ResolveSafeApiUri(profile, capability.Path); }
        catch { return new(false, false, Error: MutationErrorCategory.Validation); }
        if (token.IsCancellationRequested) return new(false, false);
        var fields = new List<KeyValuePair<string, string>> { new("api", capability.Name), new("version", "1"), new("method", "upload"),
            new("type", "fbsharing_login_" + kind.ToString().ToLowerInvariant()), new("_sid", session.Sid) };
        if (!string.IsNullOrEmpty(session.SynoToken)) fields.Add(new("SynoToken", session.SynoToken));
        using var source = new MemoryStream(bytes.ToArray(), false);
        using var content = new ExactLengthMultipartUploadContent("LanStash-Theme-" + Guid.NewGuid().ToString("N"), fields, filename, source, source.Length, null, "upload_image");
        using var request = new HttpRequestMessage(HttpMethod.Post, uri) { Content = content };
        request.Headers.Accept.ParseAdd("application/json"); request.Headers.TryAddWithoutValidation("Cookie", "id=" + session.Sid);
        if (!string.IsNullOrEmpty(session.SynoToken)) request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        SetNasConnectionContext(request, profile);
        if (token.IsCancellationRequested) return new(false, false);
        try
        {
            // 唯一提交边界；HTTP、解析、取消及连接故障均保留未知，不重传图片。
            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return new(true, false);
            await using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
            var envelope = await JsonNode.ParseAsync(stream, cancellationToken: token).ConfigureAwait(false) as JsonObject;
            var success = StrictNativeBool(envelope, "success");
            if (success == true) return new(true, true, envelope?["data"]?["path"] is JsonValue path && path.TryGetValue<string>(out var text) ? text : null);
            if (success == false && StrictNativeInt(envelope?["error"] as JsonObject, "code") is { } code)
                return new(true, false, Error: code is 105 or 407 ? MutationErrorCategory.Permission : code is 102 or 103 or 104 ? MutationErrorCategory.Unsupported : MutationErrorCategory.Server);
            return new(true, false);
        }
        catch { return new(true, false); }
    }
}
