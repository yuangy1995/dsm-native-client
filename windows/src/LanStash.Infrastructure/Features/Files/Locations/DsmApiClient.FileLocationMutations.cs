using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient : IFileLocationMutationTransport
{
    public async Task<FileLocationMutationTransportResult> SendFileLocationMutationAsync(NasProfile profile, DsmSession session,
        ApiCapability capability, FileLocationMutationRequest request, CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested) return new(FileLocationMutationTransportStatus.CancelledBeforeSubmission);
        // 仅接受逐项固化的提交契约，不能用任意 API/方法字符串绕过白名单。
        if (request is null || request.Parameters is null || profile.Id != session.ProfileId || string.IsNullOrWhiteSpace(session.Sid) ||
            !IsSafeWebApiPath(capability.Path) ||
            !(capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase))) return FavoriteTransportUnsupported();
        var parameters = request.Parameters.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
        if (parameters.Values.Any(value => value is null)) return FavoriteTransportUnsupported();
        var rawJson = new HashSet<string>(StringComparer.Ordinal);
        int version;
        if (capability.Name == "SYNO.FileStation.Favorite")
        {
            version = 2;
            var add = request.Kind == FileLocationMutationKind.AddFavorite && request.Method == "add";
            var remove = request.Kind == FileLocationMutationKind.RemoveFavorite && request.Method == "delete";
            if ((!add && !remove) || parameters.Count != (add ? 2 : 1) ||
                !parameters.TryGetValue("path", out var path) || !ValidMutationPath(path, false) || path.Length > 4096 || path.Any(char.IsControl) ||
                (add && (!parameters.TryGetValue("name", out var name) || string.IsNullOrWhiteSpace(name) || name != name.Trim() || name.Length > 1024 || name.Any(char.IsControl))))
                return FavoriteTransportUnsupported();
        }
        else if (capability.Name == "SYNO.FileStation.Mount" && request.Kind == FileLocationMutationKind.CreateRemoteMount && request.Method == "mount_remote")
        {
            version = 1;
            if (!ValidRemoteMountParameters(parameters)) return FavoriteTransportUnsupported();
            rawJson.UnionWith(["user_set", "auto_mount"]);
        }
        else if (capability.Name == "SYNO.FileStation.Mount.List" && request.Kind == FileLocationMutationKind.DeleteRemoteMount && request.Method == "unmount")
        {
            version = 1;
            if (parameters.Count != 1 || !parameters.TryGetValue("mount_point", out var encoded)) return FavoriteTransportUnsupported();
            try
            {
                var paths = JsonSerializer.Deserialize<string[]>(encoded);
                if (paths is null || paths.Length == 0 || paths.Any(path => !RemoteMountProtocol.IsMountPoint(path)) || paths.Distinct(StringComparer.Ordinal).Count() != paths.Length)
                    return FavoriteTransportUnsupported();
            }
            catch (JsonException) { return FavoriteTransportUnsupported(); }
            rawJson.Add("mount_point");
        }
        else return FavoriteTransportUnsupported();
        if (capability.MinVersion > version || capability.MaxVersion < version) return FavoriteTransportUnsupported();
        var values = parameters.ToDictionary(pair => pair.Key, pair => !rawJson.Contains(pair.Key) && capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
            ? JsonSerializer.Serialize(pair.Value) : pair.Value, StringComparer.Ordinal);
        values["api"] = capability.Name; values["version"] = version.ToString(System.Globalization.CultureInfo.InvariantCulture); values["method"] = request.Method; values["_sid"] = session.Sid;
        using var message = new HttpRequestMessage(HttpMethod.Post, ResolveSafeApiUri(profile, capability.Path))
        { Content = CreateSessionFormContent(values, session) };
        AddMutationRequestHeaders(message, profile, session);
        try
        {
            using var response = await _http.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return new(FileLocationMutationTransportStatus.SubmittedButUnverified,
                ErrorCategory: response.StatusCode == HttpStatusCode.Unauthorized ? MutationErrorCategory.Authentication :
                    response.StatusCode == HttpStatusCode.Forbidden ? MutationErrorCategory.Permission : MutationErrorCategory.Network);
            var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken).ConfigureAwait(false);
            if (!TryGetNativeBoolean(envelope, "success", out var success)) throw new JsonException();
            if (!success || envelope["error"] is not null) return new(FileLocationMutationTransportStatus.ConfirmedFailure, ErrorCategory: MutationCategory(MutationErrorCode(envelope)));
            if (envelope["data"] is not (null or JsonObject)) throw new JsonException();
            return new(FileLocationMutationTransportStatus.ResponseReceived, envelope["data"] as JsonObject);
        }
        catch (OperationCanceledException) { return new(FileLocationMutationTransportStatus.CancellationRequestedAfterSubmission, ErrorCategory: MutationErrorCategory.Network); }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException)
        { return new(FileLocationMutationTransportStatus.SubmittedButUnverified, ErrorCategory: MutationErrorCategory.Network); }
    }
    private static bool ValidRemoteMountParameters(IReadOnlyDictionary<string, string> values)
    {
        if (!values.TryGetValue("mount_type", out var type) || type is not ("CIFS" or "NFS") ||
            !values.TryGetValue("server_ip", out var source) || !RemoteMountProtocol.TryNormalizeSource(source, type == "CIFS" ? FileRemoteProtocol.Cifs : FileRemoteProtocol.Nfs, out _) ||
            !values.TryGetValue("mount_point", out var target) || !RemoteMountProtocol.IsMountPoint(target) ||
            !values.TryGetValue("user_set", out var manual) || manual != "true" ||
            !values.TryGetValue("auto_mount", out var automatic) || automatic != "false") return false;
        if (values.Count != 7) return false;
        if (type == "CIFS") return values.TryGetValue("account", out var account) && !account.Any(char.IsControl) && values.ContainsKey("passwd");
        return values.TryGetValue("nfs_version", out var version) && version is "3" or "4" &&
            values.TryGetValue("protocol", out var protocol) && protocol is "tcp" or "udp" && (version != "4" || protocol == "tcp");
    }
    private static FileLocationMutationTransportResult FavoriteTransportUnsupported() =>
        new(FileLocationMutationTransportStatus.Unsupported, ErrorCategory: MutationErrorCategory.Unsupported);
}
