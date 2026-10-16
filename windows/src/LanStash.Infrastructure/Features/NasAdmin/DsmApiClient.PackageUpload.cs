using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public bool CanUploadPackage => true;
    public async Task<JsonObject> UploadPackageAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        Stream source, long length, CancellationToken cancellationToken = default)
    {
        if (profile.Id != session.ProfileId || string.IsNullOrWhiteSpace(session.Sid) || capability.Name != "SYNO.Core.Package.Installation" ||
            capability.MinVersion > 1 || capability.MaxVersion < 1 || length <= 0 || !source.CanRead) throw new ArgumentException("package.upload.invalid-request");
        var fields = new List<KeyValuePair<string, string>>
        {
            new("api", capability.Name), new("version", "1"), new("method", "upload"), new("_sid", session.Sid),
            new("additional", JsonSerializer.Serialize(new[] { "description", "maintainer", "distributor", "startable", "dsm_apps", "status",
                "install_reboot", "install_type", "install_on_cold_storage", "break_pkgs", "replace_pkgs" })),
        };
        if (!string.IsNullOrWhiteSpace(session.SynoToken)) fields.Add(new("SynoToken", session.SynoToken));
        // 使用已有单次流上传，不生成含会话的磁盘 multipart 文件，也不发送本机文件名。
        using var content = new ExactLengthMultipartUploadContent("LanStashPackage-" + Guid.NewGuid().ToString("N"), fields, "package.spk", source, length, null);
        using var request = new HttpRequestMessage(HttpMethod.Post, ResolveSafeApiUri(profile, capability.Path)) { Content = content };
        AddMutationRequestHeaders(request, profile, session);
        cancellationToken.ThrowIfCancellationRequested();
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var failure = new DsmException(UserText.Key("NasPackageCenterFailed"), UserText.Key("NasPackageCenterUnknown"), (int)response.StatusCode);
            failure.Data[HttpStatusFailureMarker] = true; throw failure;
        }
        var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken).ConfigureAwait(false);
        if (!TryGetNativeBoolean(envelope, "success", out var success)) throw InvalidReadEnvelope();
        if (!success) throw MapFailure(MutationErrorCode(envelope));
        return envelope["data"] as JsonObject ?? new JsonObject();
    }
}
