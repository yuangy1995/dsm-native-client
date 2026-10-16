using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Windows.Graphics.Imaging;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string FileThemeApi = "SYNO.Core.Theme.FileSharingLogin", FileThemeImageApi = "SYNO.Core.Theme.Image";
    // 本机预览资源预算，与文档预览一致；不是 NAS 上传大小限制。
    private const int FileThemePreviewBytes = 128 * 1024 * 1024;
    public async Task<FileStationTheme> LoadFileStationThemeAsync(CancellationToken token = default)
    {
        var d = await FileSettingsCall(FileThemeApi, "get", null, token).ConfigureAwait(false);
        var result = new FileStationTheme(ProfileId, SettingsBool(d, "enable_logo_customize"), SettingsText(d, "logo_position") switch
        { "rightup" => FileStationLogoPosition.TopRight, "leftup" => FileStationLogoPosition.TopLeft, "rightbottom" => FileStationLogoPosition.BottomRight, "leftbottom" => FileStationLogoPosition.BottomLeft, _ => throw SettingsInvalid() },
            SettingsBool(d, "enable_background_customize"), SettingsText(d, "background_position") switch
            { "center" => FileStationBackgroundPosition.Center, "fill" => FileStationBackgroundPosition.Fill, "fit" => FileStationBackgroundPosition.Fit, "stretch" => FileStationBackgroundPosition.Stretch, "tile" => FileStationBackgroundPosition.Tile, _ => throw SettingsInvalid() },
            SettingsText(d, "background_color"), SettingsText(d, "footer_msg"), SettingsBool(d, "enable_footer_html"), ThemeSequence(d, "logo_seq"), ThemeSequence(d, "background_seq"));
        if (!result.IsValid) throw SettingsInvalid(); return result;
    }
    private static string? ThemeSequence(JsonObject data, string key)
    {
        if (data[key] is null) return null;
        if (data[key] is JsonValue value)
        { if (value.TryGetValue<string>(out var text)) return text; if (value.TryGetValue<long>(out var number)) return number.ToString(CultureInfo.InvariantCulture); }
        throw SettingsInvalid();
    }
    private async Task<Dictionary<string, string>> FileThemeFields(FileStationTheme old, FileStationTheme next, CancellationToken token)
    {
        if (old.LogoImage is not null || old.BackgroundImage is not null || !old.CustomLogo && next.CustomLogo && next.LogoImage is null ||
            !old.CustomBackground && next.CustomBackground && next.BackgroundImage is null) throw SettingsInvalid();
        string Encode(string value) => ShareParameterString(FileThemeApi, value);
        var fields = new Dictionary<string, string> { ["enable_logo_customize"] = next.CustomLogo ? "true" : "false", ["enable_background_customize"] = next.CustomBackground ? "true" : "false",
            ["logo_position"] = Encode(next.LogoPosition switch { FileStationLogoPosition.TopRight => "rightup", FileStationLogoPosition.TopLeft => "leftup", FileStationLogoPosition.BottomRight => "rightbottom", _ => "leftbottom" }),
            ["background_position"] = Encode(next.BackgroundPosition.ToString().ToLowerInvariant()), ["background_color"] = Encode(next.BackgroundColor),
            ["footer_msg"] = Encode(next.Footer), ["enable_footer_html"] = next.FooterUsesHtml ? "true" : "false" };
        foreach (var image in new[] { next.LogoImage, next.BackgroundImage }.OfType<FileStationThemeImage>())
        {
            await ValidateThemeImage(image, token).ConfigureAwait(false); var prefix = image.Kind.ToString().ToLowerInvariant();
            fields[prefix + "_type"] = Encode(image.Source switch { FileStationThemeImageSource.Nas => "fromDS", FileStationThemeImageSource.History => "history", _ => "default" });
            fields[prefix + "_path"] = Encode(image.Source == FileStationThemeImageSource.Nas ? image.Path : image.Path.Split('/')[^1]);
        }
        return fields;
    }
    public async Task<IReadOnlyList<FileStationThemeImage>> ListFileStationThemeImagesAsync(FileStationThemeImageKind kind, CancellationToken token = default)
    {
        if (!Enum.IsDefined(kind)) throw SettingsInvalid();
        var data = await FileSettingsCall(FileThemeImageApi, "list", new() { ["type"] = ShareParameterString(FileThemeImageApi, ThemeKind(kind)) }, token).ConfigureAwait(false);
        if (data["list"] is not JsonArray rows) throw SettingsInvalid(); var images = new List<FileStationThemeImage>();
        foreach (var row in rows)
        {
            if (row is not JsonObject obj || StrictInt(obj, "index") is not >= 0) throw SettingsInvalid();
            var path = SettingsText(obj, "path"); var name = obj["filename"] is null ? path.Split('/')[^1] : SettingsText(obj, "filename");
            var image = new FileStationThemeImage(kind, FileStationThemeImageSource.History, path, name, StrictInt(obj, "index"));
            if (!image.IsValid) throw SettingsInvalid(); images.Add(image);
        }
        if (images.Select(v => v.Path).Distinct(StringComparer.Ordinal).Count() != images.Count || images.Select(v => v.HistoryIndex).Distinct().Count() != images.Count) throw SettingsInvalid();
        return images;
    }
    private static string ThemeKind(FileStationThemeImageKind kind) => "fbsharing_login_" + kind.ToString().ToLowerInvariant();
    private async Task<FileStationThemeImage> ValidateThemeImage(FileStationThemeImage image, CancellationToken token)
    {
        if (!image.IsValid) throw SettingsInvalid();
        if (image.Source == FileStationThemeImageSource.History)
            return (await ListFileStationThemeImagesAsync(image.Kind, token).ConfigureAwait(false)).SingleOrDefault(v => v.Path == image.Path) ?? throw SettingsInvalid();
        if (image.Source == FileStationThemeImageSource.Nas)
        {
            var row = await ReadFileInfoRowAsync(image.Path, "[\"perm\"]", token).ConfigureAwait(false);
            if (row is null || !NativeBool(row, "isdir", out var directory) || directory || FileStationPermissions.Parse(row["additional"]?["perm"]).Read == false) throw SettingsInvalid();
        }
        return image;
    }
    public async Task<byte[]> ReadFileStationThemeImageAsync(FileStationThemeImage image, CancellationToken token = default)
    {
        if (_profile.Id != _session.ProfileId || string.IsNullOrEmpty(_session.Sid)) throw SettingsInvalid();
        var current = await ValidateThemeImage(image, token).ConfigureAwait(false);
        DsmBinaryResponse data;
        if (image.Source == FileStationThemeImageSource.Default)
            data = await _api.ReadFileStationDefaultBackgroundAsync(_profile, _session, image.Path, FileThemePreviewBytes, token).ConfigureAwait(false);
        else if (image.Source == FileStationThemeImageSource.History)
            data = await _api.ReadBinaryAsync(_profile, _session, FixedCapability(FileThemeImageApi, 1), "get", new Dictionary<string, string> {
                ["type"] = ShareParameterString(FileThemeImageApi, ThemeKind(image.Kind)), ["index"] = current.HistoryIndex!.Value.ToString(CultureInfo.InvariantCulture), ["is_thumbnail"] = "true" }, "image/", FileThemePreviewBytes, token).ConfigureAwait(false);
        else
        {
            const string api = "SYNO.FileStation.Thumb"; if (!HasFixedCapability(api, 2)) throw new NotSupportedException();
            data = await _api.ReadBinaryAsync(_profile, _session, FixedCapability(api, 2), "get", new Dictionary<string, string> {
                ["path"] = ShareParameterString(api, image.Path), ["size"] = ShareParameterString(api, "large"), ["rotate"] = "0" }, "image/", FileThemePreviewBytes, token).ConfigureAwait(false);
        }
        await DecodeThemeImage(data.Bytes, token).ConfigureAwait(false); return data.Bytes;
    }
    private static async Task DecodeThemeImage(byte[] bytes, CancellationToken token)
    {
        if (bytes.Length == 0) throw SettingsInvalid();
        using var stream = new MemoryStream(bytes, false); using var random = stream.AsRandomAccessStream();
        var decoder = await BitmapDecoder.CreateAsync(random).AsTask(token).ConfigureAwait(false);
        if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0) throw SettingsInvalid();
        _ = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
            new BitmapTransform { ScaledWidth = 1, ScaledHeight = 1 }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask(token).ConfigureAwait(false);
    }
    public async Task<FileStationThemeUploadResult> UploadFileStationThemeImageAsync(FileStationThemeImageKind kind, string filename, ReadOnlyMemory<byte> content, bool confirmed, CancellationToken token = default)
    {
        FileStationThemeUploadResult Result(MutationResultStatus status, bool sent, MutationErrorCategory? error = null, FileStationThemeImage? image = null) => new(
            new(1, status, "fileThemeUpload", sent, status == MutationResultStatus.SubmittedButUnverified,
                new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0, status == MutationResultStatus.SubmittedButUnverified ? 1 : 0), error, diagnosticTag: "file.theme.upload"), image);
        if (!confirmed || !Enum.IsDefined(kind) || !FileStationThemeImage.SupportsFilename(filename) || filename.Any(c => char.IsControl(c) || c is '"' or '/' or '\\'))
            return Result(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Validation);
        if (token.IsCancellationRequested) return Result(MutationResultStatus.CancelledBeforeSubmission, false);
        var bytes = content.ToArray();
        try { await DecodeThemeImage(bytes, token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return Result(MutationResultStatus.CancelledBeforeSubmission, false); }
        catch { return Result(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Validation); }
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Result(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict);
        try
        {
            var key = (ServiceScope(), kind, Convert.ToHexString(SHA256.HashData(bytes)));
            if (shared.FileThemeUploads.Contains(key)) return Result(MutationResultStatus.SubmittedButUnverified, true);
            try { await RequireFileSettingsWrite(token).ConfigureAwait(false); if (!HasFixedCapability(FileThemeImageApi, 1)) throw new NotSupportedException(); token.ThrowIfCancellationRequested(); }
            catch (OperationCanceledException) { return Result(MutationResultStatus.CancelledBeforeSubmission, false); }
            catch (DsmException e) { return Result(MutationResultStatus.PermissionDenied, false, ServiceErrorCategory(e)); }
            catch (NotSupportedException) { return Result(MutationResultStatus.Unsupported, false, MutationErrorCategory.Unsupported); }
            catch { return Result(MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Network); }
            shared.FileThemeUploads.Add(key);
            FileStationThemeUploadTransportResult response;
            try { response = await _api.UploadFileStationThemeImageAsync(_profile, _session, FixedCapability(FileThemeImageApi, 1), kind, filename, bytes, token).ConfigureAwait(false); }
            catch { return Result(MutationResultStatus.SubmittedButUnverified, true); }
            if (!response.Submitted || response.Error is not null)
            {
                shared.FileThemeUploads.Remove(key);
                return Result(response.Error is null ? MutationResultStatus.CancelledBeforeSubmission : response.Error == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : response.Error == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure, response.Submitted, response.Error);
            }
            if (response.Accepted && response.Path is not null)
            {
                try
                {
                    var image = (await ListFileStationThemeImagesAsync(kind, token).ConfigureAwait(false)).SingleOrDefault(v => v.Path == response.Path);
                    if (image is not null) { shared.FileThemeUploads.Remove(key); return Result(MutationResultStatus.ConfirmedSuccess, true, image: image); }
                }
                catch { /* 历史缺失或读取失败保留摘要，不能重新上传同一内容。 */ }
            }
            return Result(MutationResultStatus.SubmittedButUnverified, true);
        }
        finally { shared.Gate.Release(); }
    }
}
