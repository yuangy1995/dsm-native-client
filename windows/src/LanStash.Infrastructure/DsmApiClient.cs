using System.Buffers;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed class DsmApiClient(HttpClient httpClient) : IDsmApiClient
{
    private readonly HttpClient _http = httpClient;

    public Uri GetBaseUri(NasProfile profile)
    {
        var input = profile.Host.Trim();
        if (!input.Contains("://", StringComparison.Ordinal))
        {
            input = $"https://{input}";
        }

        if (!Uri.TryCreate(input, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(uri.Host))
        {
            throw new DsmException(
                UserText.Key("WinShared23ac67f1f673dd23"),
                UserText.Key("WinShareddcac071c2cf16346"));
        }

        var builder = new UriBuilder(uri);
        if (profile.Port is not null)
        {
            builder.Port = profile.Port.Value;
        }
        builder.Path = builder.Path.TrimEnd('/');
        return builder.Uri;
    }

    public async Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        CancellationToken cancellationToken = default) =>
        await DiscoverAsync(
            profile,
            DsmConnectionSource.DirectAddress,
            cancellationToken).ConfigureAwait(false);

    public async Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default)
    {
        var data = await PostAsync(
            profile,
            "/webapi/query.cgi",
            new Dictionary<string, string>
            {
                ["api"] = "SYNO.API.Info",
                ["version"] = "1",
                ["method"] = "query",
                ["query"] = "all",
            },
            session: null,
            source: source,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var result = new Dictionary<string, ApiCapability>(StringComparer.Ordinal);
        foreach (var (name, node) in data)
        {
            if (node is not JsonObject value ||
                value["path"]?.GetValue<string>() is not { Length: > 0 } path)
            {
                continue;
            }
            var minVersion = value["minVersion"]?.GetValue<int>() ?? 1;
            var maxVersion = value["maxVersion"]?.GetValue<int>() ?? minVersion;
            result[name] = new ApiCapability(
                name,
                path,
                minVersion,
                maxVersion,
                value["requestFormat"]?.GetValue<string>() ?? "FORM");
        }
        return result;
    }

    public async Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        CancellationToken cancellationToken = default) =>
        await LoginAsync(
            profile,
            password,
            otp,
            DsmConnectionSource.DirectAddress,
            cancellationToken).ConfigureAwait(false);

    public async Task<DsmSession> LoginAsync(
        NasProfile profile,
        string password,
        string? otp,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default)
    {
        var parameters = new Dictionary<string, string>
        {
            ["api"] = "SYNO.API.Auth",
            ["version"] = "7",
            ["method"] = "login",
            ["account"] = profile.Username,
            ["passwd"] = password,
            ["session"] = "FileStation",
            ["format"] = "sid",
            ["enable_syno_token"] = "yes",
            ["enable_device_token"] = "yes",
            ["device_name"] = "LanStash Windows",
        };
        if (!string.IsNullOrWhiteSpace(otp))
        {
            parameters["otp_code"] = otp.Trim();
        }
        var data = await PostAsync(
            profile,
            "/webapi/auth.cgi",
            parameters,
            session: null,
            source: source,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var sid = data["sid"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(sid))
        {
            throw new DsmException(
                UserText.Key("WinSharedab4ce8cd180797fc"),
                UserText.Key("WinSharedc144a2dc9ace5c1f"),
                authenticationFailure: true);
        }
        return new DsmSession(
            profile.Id,
            sid,
            data["synotoken"]?.GetValue<string>(),
            data["did"]?.GetValue<string>());
    }

    public async Task LogoutAsync(
        NasProfile profile,
        DsmSession session,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await PostAsync(
                profile,
                "/webapi/auth.cgi",
                new Dictionary<string, string>
                {
                    ["api"] = "SYNO.API.Auth",
                    ["version"] = "7",
                    ["method"] = "logout",
                    ["session"] = "FileStation",
                },
                session,
                cancellationToken).ConfigureAwait(false);
        }
        catch (DsmException)
        {
            // 本机仍应清除会话，远端退出失败不阻塞用户。
        }
    }

    public Task<JsonObject> CallAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string method,
        IReadOnlyDictionary<string, string>? parameters = null,
        CancellationToken cancellationToken = default)
    {
        var values = new Dictionary<string, string>
        {
            ["api"] = capability.Name,
            ["version"] = capability.MaxVersion.ToString(),
            ["method"] = method,
        };
        if (parameters is not null)
        {
            foreach (var (key, value) in parameters)
            {
                values[key] = value;
            }
        }
        var path = capability.Path.StartsWith('/') ? capability.Path : $"/webapi/{capability.Path}";
        return PostAsync(profile, path, values, session, cancellationToken);
    }

    public async Task<JsonObject> CallReadJsonObjectAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        int requiredVersion,
        string method,
        IReadOnlyDictionary<string, string>? parameters = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        ArgumentException.ThrowIfNullOrWhiteSpace(capability.Name);
        if (method is not ("get" or "list" or "list_share"))
        {
            throw new ArgumentException("The fixed-version read method is not allowed.", nameof(method));
        }
        ArgumentOutOfRangeException.ThrowIfLessThan(requiredVersion, 1);
        if (session.ProfileId != profile.Id)
        {
            throw new ArgumentException("The session does not belong to the requested profile.", nameof(session));
        }
        if (string.IsNullOrWhiteSpace(session.Sid))
        {
            throw new ArgumentException("The session is missing its identifier.", nameof(session));
        }
        if (requiredVersion < capability.MinVersion || requiredVersion > capability.MaxVersion)
        {
            throw new NotSupportedException("The required fixed API version is unavailable.");
        }
        if (!string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase))
        {
            throw new NotSupportedException("The fixed-version read contract requires FORM requests.");
        }
        if (parameters?.Keys.Any(IsReservedReadParameter) == true)
        {
            throw new ArgumentException("Reserved or authentication parameters are not allowed.", nameof(parameters));
        }

        var requestUri = ResolveSafeApiUri(profile, capability.Path);
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = requiredVersion.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["method"] = method,
        };
        if (parameters is not null)
        {
            foreach (var (key, value) in parameters)
            {
                values[key] = value;
            }
        }
        values["_sid"] = session.Sid;

        using var request = new HttpRequestMessage(HttpMethod.Post, requestUri)
        {
            Content = new FormUrlEncodedContent(values),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DsmException(
                UserText.Key("WinShared5a870c4775a4ef6b"),
                UserText.Key("WinShared199c5367bae9682d"));
        }
        catch (HttpRequestException)
        {
            throw new DsmException(
                UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"));
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new DsmException(
                    UserText.Key("WinSharedf91eef8a1cf7b01c"),
                    UserText.Key("WinShared79c4d60046afa3ff"),
                    (int)response.StatusCode,
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
            }
            await using var stream = await response.Content
                .ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            JsonObject envelope;
            try
            {
                envelope = await JsonNode.ParseAsync(
                    stream,
                    cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject
                    ?? throw new JsonException();
            }
            catch (JsonException)
            {
                throw InvalidReadEnvelope();
            }
            cancellationToken.ThrowIfCancellationRequested();

            if (!TryGetNativeBoolean(envelope, "success", out var success))
            {
                throw InvalidReadEnvelope();
            }
            if (!success)
            {
                if (envelope["error"] is not JsonObject error ||
                    !TryGetNativeInt32(error, "code", out var code) || code < 0)
                {
                    throw InvalidReadEnvelope();
                }
                throw MapFailure(code);
            }
            return envelope["data"] as JsonObject ?? throw InvalidReadEnvelope();
        }
    }

    public async Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string folderPath, string name,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.CheckPermission", 3) ||
            !ValidMutationPath(folderPath, allowSharedRoot: false) ||
            !ValidMutationName(name))
        {
            return new(FilePermissionTransportStatus.Unsupported,
                MutationErrorCategory.Unsupported, "file.mutation.permission.unsupported");
        }
        var result = await SendFileMutationFormAsync(profile, session, capability, 3, "write",
            new Dictionary<string, string>
            {
                ["path"] = folderPath, ["filename"] = name, ["create_only"] = "true",
            }, cancellationToken, permissionProbe: true).ConfigureAwait(false);
        return result.Status switch
        {
            FileMutationTransportStatus.ResponseReceived => new(FilePermissionTransportStatus.Allowed),
            FileMutationTransportStatus.ConfirmedFailure when result.ErrorCategory == MutationErrorCategory.Permission =>
                new(FilePermissionTransportStatus.Denied, result.ErrorCategory, result.DiagnosticTag),
            FileMutationTransportStatus.CancelledBeforeSubmission or
                FileMutationTransportStatus.CancellationRequestedAfterSubmission =>
                new(FilePermissionTransportStatus.Cancelled, result.ErrorCategory, result.DiagnosticTag),
            FileMutationTransportStatus.Unsupported => new(FilePermissionTransportStatus.Unsupported,
                result.ErrorCategory, result.DiagnosticTag),
            _ => new(FilePermissionTransportStatus.Failed, result.ErrorCategory, result.DiagnosticTag),
        };
    }

    public Task<FileMutationTransportResult> CreateFolderMutationAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string parentPath, string name,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.CreateFolder", 2) ||
            !ValidMutationPath(parentPath, allowSharedRoot: false) || !ValidMutationName(name))
        {
            return Task.FromResult(new FileMutationTransportResult(
                FileMutationTransportStatus.Unsupported, MutationErrorCategory.Unsupported,
                "file.create-folder.unsupported"));
        }
        return SendFileMutationFormAsync(profile, session, capability, 2, "create",
            new Dictionary<string, string>
            {
                ["folder_path"] = parentPath, ["name"] = name, ["force_parent"] = "false",
            }, cancellationToken, permissionProbe: false);
    }

    public Task<FileMutationTransportResult> RenameFileMutationAsync(
        NasProfile profile, DsmSession session, ApiCapability capability,
        string path, string newName,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.Rename", 2) ||
            !ValidMutationPath(path, allowSharedRoot: false) || !ValidMutationName(newName))
        {
            return Task.FromResult(new FileMutationTransportResult(
                FileMutationTransportStatus.Unsupported, MutationErrorCategory.Unsupported,
                "file.rename.unsupported"));
        }
        return SendFileMutationFormAsync(profile, session, capability, 2, "rename",
            new Dictionary<string, string>
            {
                ["path"] = JsonSerializer.Serialize(new[] { path }),
                ["name"] = JsonSerializer.Serialize(new[] { newName }),
            }, cancellationToken, permissionProbe: false);
    }

    public async Task<FileCopyMoveStartTransportResult> StartFileCopyMoveAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string sourcePath,
        string destinationDirectoryPath,
        bool removeSource,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.CopyMove", 3) ||
            !ValidMutationPath(sourcePath, allowSharedRoot: false) ||
            !ValidMutationPath(destinationDirectoryPath, allowSharedRoot: false))
        {
            return new(FileMutationTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "file.copy-move.unsupported");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new(FileMutationTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "file.copy-move.cancelled-before-submit");
        }
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = "3",
            ["method"] = "start",
            ["path"] = JsonSerializer.Serialize(new[] { sourcePath }),
            ["dest_folder_path"] = destinationDirectoryPath,
            ["remove_src"] = removeSource ? "true" : "false",
            ["overwrite"] = "false",
            ["accurate_progress"] = "true",
            ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(HttpMethod.Post,
            ResolveSafeApiUri(profile, capability.Path))
        { Content = new FormUrlEncodedContent(values) };
        AddMutationRequestHeaders(request, profile, session);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.copy-move.cancelled-after-submit");
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            return new(FileMutationTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.copy-move.network-unverified");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    ErrorCategory: response.StatusCode switch
                    {
                        HttpStatusCode.Unauthorized => MutationErrorCategory.Authentication,
                        HttpStatusCode.Forbidden => MutationErrorCategory.Permission,
                        _ => MutationErrorCategory.Server,
                    },
                    DiagnosticTag: "file.copy-move.http-unverified");
            }
            try
            {
                var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken)
                    .ConfigureAwait(false);
                if (!TryGetNativeBoolean(envelope, "success", out var success))
                    throw new JsonException();
                if (!success)
                {
                    var code = MutationErrorCode(envelope);
                    return new(FileMutationTransportStatus.ConfirmedFailure,
                        ErrorCategory: MutationCategory(code),
                        DiagnosticTag: "file.copy-move.dsm-failure");
                }
                if (envelope["data"] is not JsonObject data ||
                    data["taskid"] is not JsonValue taskNode ||
                    !taskNode.TryGetValue<string>(out var taskId) ||
                    !ValidCopyMoveTaskId(taskId))
                    throw new JsonException();
                return new(FileMutationTransportStatus.ResponseReceived, taskId);
            }
            catch (OperationCanceledException)
            {
                return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "file.copy-move.cancelled-after-submit");
            }
            catch (Exception error) when (error is JsonException or IOException or HttpRequestException)
            {
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "file.copy-move.response-unverified");
            }
        }
    }

    public async Task<FileCopyMoveTaskTransportResult> ReadFileCopyMoveStatusAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string taskId,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.CopyMove", 3) || !ValidCopyMoveTaskId(taskId))
            return new(FileCopyMoveTaskTransportStatus.Unsupported,
                MutationErrorCategory.Unsupported, "file.copy-move.status-unsupported");
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = "3",
            ["method"] = "status",
            ["taskid"] = taskId,
            ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(HttpMethod.Post,
            ResolveSafeApiUri(profile, capability.Path))
        { Content = new FormUrlEncodedContent(values) };
        AddMutationRequestHeaders(request, profile, session);
        using var response = await _http.SendAsync(request,
            HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new DsmException(UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"), (int)response.StatusCode,
                response.StatusCode == HttpStatusCode.Unauthorized);
        var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken)
            .ConfigureAwait(false);
        if (!TryGetNativeBoolean(envelope, "success", out var success))
            throw InvalidReadEnvelope();
        if (!success) throw CopyMoveStatusFailure(MutationErrorCode(envelope));
        if (envelope["data"] is not JsonObject data ||
            !TryGetNativeBoolean(data, "finished", out var finished))
            throw InvalidReadEnvelope();
        ValidateOptionalNonNegativeNumber(data, "progress");
        ValidateOptionalNonNegativeInt64(data, "total");
        ValidateOptionalNonNegativeInt64(data, "processed_size");
        return new(finished ? FileCopyMoveTaskTransportStatus.Finished :
            FileCopyMoveTaskTransportStatus.Running);
    }

    public async Task<FileRecycleStartTransportResult> StartMoveToRecycleAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string sourcePath,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.Delete", 2) ||
            !ValidMutationPath(sourcePath, allowSharedRoot: false))
        {
            return new(FileMutationTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "file.recycle.move.unsupported");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new(FileMutationTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "file.recycle.move.cancelled-before-submit");
        }
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = "2",
            ["method"] = "start",
            ["path"] = JsonSerializer.Serialize(new[] { sourcePath }),
            ["recursive"] = "true",
            ["accurate_progress"] = "true",
            ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(HttpMethod.Post,
            ResolveSafeApiUri(profile, capability.Path))
        { Content = new FormUrlEncodedContent(values) };
        AddMutationRequestHeaders(request, profile, session);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.recycle.move.cancelled-after-submit");
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            return new(FileMutationTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.recycle.move.network-unverified");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    ErrorCategory: response.StatusCode switch
                    {
                        HttpStatusCode.Unauthorized => MutationErrorCategory.Authentication,
                        HttpStatusCode.Forbidden => MutationErrorCategory.Permission,
                        _ => MutationErrorCategory.Server,
                    },
                    DiagnosticTag: "file.recycle.move.http-unverified");
            }
            try
            {
                var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken)
                    .ConfigureAwait(false);
                if (!TryGetNativeBoolean(envelope, "success", out var success))
                    throw new JsonException();
                if (!success)
                {
                    var code = MutationErrorCode(envelope);
                    return new(FileMutationTransportStatus.ConfirmedFailure,
                        ErrorCategory: MutationCategory(code),
                        DiagnosticTag: "file.recycle.move.dsm-failure");
                }
                if (envelope["data"] is not JsonObject data ||
                    data["taskid"] is not JsonValue taskNode ||
                    !taskNode.TryGetValue<string>(out var taskId) ||
                    !ValidCopyMoveTaskId(taskId))
                    throw new JsonException();
                return new(FileMutationTransportStatus.ResponseReceived, taskId);
            }
            catch (OperationCanceledException)
            {
                return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "file.recycle.move.cancelled-after-submit");
            }
            catch (Exception error) when (error is JsonException or IOException or HttpRequestException)
            {
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "file.recycle.move.response-unverified");
            }
        }
    }

    public async Task<FileRecycleTaskTransportResult> ReadFileRecycleStatusAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string taskId,
        CancellationToken cancellationToken = default)
    {
        if (!ValidMutationCapability(profile, session, capability,
                "SYNO.FileStation.Delete", 2) || !ValidCopyMoveTaskId(taskId))
            return new(FileRecycleTaskTransportStatus.Unsupported,
                MutationErrorCategory.Unsupported, "file.recycle.status-unsupported");
        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = "2",
            ["method"] = "status",
            ["taskid"] = taskId,
            ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(HttpMethod.Post,
            ResolveSafeApiUri(profile, capability.Path))
        { Content = new FormUrlEncodedContent(values) };
        AddMutationRequestHeaders(request, profile, session);
        using var response = await _http.SendAsync(request,
            HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new DsmException(UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"), (int)response.StatusCode,
                response.StatusCode == HttpStatusCode.Unauthorized);
        var envelope = await ReadMutationEnvelopeAsync(response, cancellationToken)
            .ConfigureAwait(false);
        if (!TryGetNativeBoolean(envelope, "success", out var success))
            throw InvalidReadEnvelope();
        if (!success) throw CopyMoveStatusFailure(MutationErrorCode(envelope));
        if (envelope["data"] is not JsonObject data ||
            !TryGetNativeBoolean(data, "finished", out var finished))
            throw InvalidReadEnvelope();
        ValidateOptionalNonNegativeNumber(data, "progress");
        ValidateOptionalNonNegativeInt64(data, "total");
        ValidateOptionalNonNegativeInt64(data, "processed_size");
        return new(finished ? FileRecycleTaskTransportStatus.Finished :
            FileRecycleTaskTransportStatus.Running);
    }

    private static async Task<JsonObject> ReadMutationEnvelopeAsync(
        HttpResponseMessage response, CancellationToken cancellationToken)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        return await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken)
            .ConfigureAwait(false) as JsonObject ?? throw new JsonException();
    }

    private static int MutationErrorCode(JsonObject envelope) =>
        envelope["error"] is JsonObject error &&
        TryGetNativeInt32(error, "code", out var code) && code >= 0
            ? code : throw new JsonException();

    private static MutationErrorCategory MutationCategory(int code) => code switch
    {
        105 => MutationErrorCategory.Permission,
        106 or 107 or 119 or 401 => MutationErrorCategory.Authentication,
        400 or 408 or 900 or 1805 => MutationErrorCategory.Conflict,
        _ => MutationErrorCategory.Server,
    };

    private static bool ValidCopyMoveTaskId(string? taskId) =>
        !string.IsNullOrWhiteSpace(taskId) && taskId == taskId.Trim() &&
        taskId.Length <= 256 && taskId.IndexOfAny(['\r', '\n', '\0']) < 0;

    private static void ValidateOptionalNonNegativeInt64(JsonObject data, string key)
    {
        if (data[key] is null) return;
        if (data[key] is not JsonValue value || !value.TryGetValue<long>(out var result) || result < 0)
            throw InvalidReadEnvelope();
    }

    private static void ValidateOptionalNonNegativeNumber(JsonObject data, string key)
    {
        if (data[key] is null) return;
        if (data[key] is not JsonValue value ||
            !(value.TryGetValue<long>(out var integer) && integer >= 0) &&
            !(value.TryGetValue<double>(out var number) && double.IsFinite(number) && number >= 0))
            throw InvalidReadEnvelope();
    }

    private static DsmException CopyMoveStatusFailure(int code) => new(
        UserText.Key("WinShared0addf7c060c570ce"),
        UserText.Key("WinShared5448ceb91a80e260"),
        code,
        code is 106 or 107 or 119 or 401);

    private static void AddMutationRequestHeaders(HttpRequestMessage request,
        NasProfile profile, DsmSession session)
    {
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        SetNasConnectionContext(request, profile);
    }

    private async Task<FileMutationTransportResult> SendFileMutationFormAsync(
        NasProfile profile, DsmSession session, ApiCapability capability, int version,
        string method, IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken, bool permissionProbe)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return new(FileMutationTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "file.mutation.cancelled-before-submit");
        }
        var values = new Dictionary<string, string>(parameters, StringComparer.Ordinal)
        {
            ["api"] = capability.Name, ["version"] = version.ToString(
                System.Globalization.CultureInfo.InvariantCulture),
            ["method"] = method, ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(HttpMethod.Post,
            ResolveSafeApiUri(profile, capability.Path))
        { Content = new FormUrlEncodedContent(values) };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        SetNasConnectionContext(request, profile);
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                MutationErrorCategory.Network, "file.mutation.cancelled-after-submit");
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            return new(FileMutationTransportStatus.SubmittedButUnverified,
                MutationErrorCategory.Network, "file.mutation.network-unverified");
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var category = response.StatusCode switch
                {
                    System.Net.HttpStatusCode.Unauthorized => MutationErrorCategory.Authentication,
                    System.Net.HttpStatusCode.Forbidden => MutationErrorCategory.Permission,
                    _ => MutationErrorCategory.Server,
                };
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    category, "file.mutation.http-unverified");
            }
            try
            {
                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken)
                    .ConfigureAwait(false);
                var envelope = await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken)
                    .ConfigureAwait(false) as JsonObject;
                if (envelope is null || !TryGetNativeBoolean(envelope, "success", out var success))
                    return new(FileMutationTransportStatus.SubmittedButUnverified,
                        MutationErrorCategory.Server, "file.mutation.response-unverified");
                if (success) return new(FileMutationTransportStatus.ResponseReceived);
                if (envelope["error"] is not JsonObject error ||
                    !TryGetNativeInt32(error, "code", out var code) || code < 0)
                    return new(FileMutationTransportStatus.SubmittedButUnverified,
                        MutationErrorCategory.Server, "file.mutation.response-unverified");
                var category = code switch
                {
                    105 => MutationErrorCategory.Permission,
                    106 or 107 or 119 or 401 => MutationErrorCategory.Authentication,
                    _ => MutationErrorCategory.Server,
                };
                return new(FileMutationTransportStatus.ConfirmedFailure, category,
                    permissionProbe ? "file.mutation.permission-denied" : "file.mutation.dsm-failure");
            }
            catch (OperationCanceledException)
            {
                return new(FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                    MutationErrorCategory.Network, "file.mutation.cancelled-after-submit");
            }
            catch (Exception error) when (error is JsonException or IOException or HttpRequestException)
            {
                return new(FileMutationTransportStatus.SubmittedButUnverified,
                    MutationErrorCategory.Server, "file.mutation.response-unverified");
            }
        }
    }

    private bool ValidMutationCapability(NasProfile profile, DsmSession session,
        ApiCapability capability, string name, int version) =>
        profile.Id == session.ProfileId && !string.IsNullOrWhiteSpace(session.Sid) &&
        string.Equals(capability.Name, name, StringComparison.Ordinal) &&
        version >= capability.MinVersion && version <= capability.MaxVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) &&
        IsSafeWebApiPath(capability.Path);

    private static bool ValidMutationName(string value) =>
        !string.IsNullOrWhiteSpace(value) && value == value.Trim() && value is not ("." or "..") &&
        value.IndexOfAny(['/', '\\', '\r', '\n', '\0']) < 0;

    private static bool ValidMutationPath(string value, bool allowSharedRoot) =>
        !string.IsNullOrWhiteSpace(value) && value.StartsWith('/') &&
        (allowSharedRoot || value != "/") && !value.EndsWith('/') &&
        !value.Contains("//", StringComparison.Ordinal) && !value.Contains('\\') &&
        value.IndexOfAny(['\r', '\n', '\0']) < 0 &&
        !value.Split('/').Any(segment => segment is "." or "..");

    private static void SetNasConnectionContext(
        HttpRequestMessage request,
        NasProfile profile) =>
        WindowsCertificateTrustHandler.SetConnectionContext(
            request,
            profile.Id,
            DsmConnectionSource.DirectAddress);

    private static bool IsReservedReadParameter(string name) =>
        name.Equals("api", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("version", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("method", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("cookie", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("did", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("password", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("passwd", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("token", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("_syno_token", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("credential", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("authorization", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("otp", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("otp_code", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("device_id", StringComparison.OrdinalIgnoreCase) ||
        IsAuthenticationParameter(name);

    private Uri ResolveSafeApiUri(NasProfile profile, string path)
    {
        if (string.IsNullOrWhiteSpace(path) ||
            Uri.TryCreate(path, UriKind.Absolute, out _) ||
            path.StartsWith("//", StringComparison.Ordinal) ||
            path.StartsWith('\\') ||
            path.Contains('\\') ||
            path.Contains('%') ||
            path.Contains("//", StringComparison.Ordinal) ||
            path.Contains('?') ||
            path.Contains('#'))
        {
            throw new ArgumentException("The API capability path is invalid.", nameof(path));
        }
        var trimmed = path.TrimStart('/');
        var segments = trimmed.Split('/');
        if (segments.Length == 0 || segments.Any(segment => segment is "." or ".."))
        {
            throw new ArgumentException("The API capability path is invalid.", nameof(path));
        }
        var relative = trimmed.StartsWith("webapi/", StringComparison.OrdinalIgnoreCase)
            ? $"/{trimmed}"
            : $"/webapi/{trimmed}";
        var baseUri = GetBaseUri(profile);
        var requestUri = new Uri(baseUri, relative);
        if (!string.Equals(requestUri.Scheme, baseUri.Scheme, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(requestUri.Host, baseUri.Host, StringComparison.OrdinalIgnoreCase) ||
            requestUri.Port != baseUri.Port ||
            !string.IsNullOrEmpty(requestUri.UserInfo))
        {
            throw new ArgumentException("The API capability path changes the NAS authority.", nameof(path));
        }
        return requestUri;
    }

    private static bool TryGetNativeBoolean(JsonObject value, string name, out bool result)
    {
        result = default;
        return value[name] is JsonValue node && node.TryGetValue(out result);
    }

    private static bool TryGetNativeInt32(JsonObject value, string name, out int result)
    {
        result = default;
        return value[name] is JsonValue node && node.TryGetValue(out result);
    }

    private static DsmException InvalidReadEnvelope() => new(
        UserText.Key("WinShared9cb9ec075b03b6cb"),
        UserText.Key("WinShared09f262a53ad074ca"));

    public async Task<DsmBinaryResponse> ReadBinaryAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        string acceptedMediaTypePrefix,
        int maximumBytes,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(method);
        ArgumentException.ThrowIfNullOrWhiteSpace(acceptedMediaTypePrefix);
        ArgumentOutOfRangeException.ThrowIfLessThan(maximumBytes, 1);
        if (parameters?.Keys.Any(IsAuthenticationParameter) == true)
        {
            throw new ArgumentException(
                "Authentication material must be supplied through the session, not binary request parameters.",
                nameof(parameters));
        }

        var values = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = capability.SelectVersion(2).ToString(
                System.Globalization.CultureInfo.InvariantCulture),
            ["method"] = method,
        };
        if (parameters is not null)
        {
            foreach (var (key, value) in parameters)
            {
                values[key] = value;
            }
        }
        var query = string.Join(
            "&",
            values.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        if (string.IsNullOrWhiteSpace(capability.Path) ||
            capability.Path.StartsWith("//", StringComparison.Ordinal) ||
            capability.Path.StartsWith('\\') ||
            capability.Path.Contains('?') ||
            capability.Path.Contains('#'))
        {
            throw new ArgumentException(
                "The binary API capability path is invalid.",
                nameof(capability));
        }
        var path = capability.Path.StartsWith('/')
            ? capability.Path
            : $"/webapi/{capability.Path}";
        var baseUri = GetBaseUri(profile);
        var requestUri = new Uri(baseUri, $"{path}?{query}");
        if (!string.Equals(requestUri.Scheme, baseUri.Scheme, StringComparison.OrdinalIgnoreCase) ||
            !string.Equals(requestUri.Host, baseUri.Host, StringComparison.OrdinalIgnoreCase) ||
            requestUri.Port != baseUri.Port)
        {
            throw new ArgumentException(
                "The binary API capability path changes the NAS authority.",
                nameof(capability));
        }
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            requestUri);
        request.Headers.Accept.ParseAdd($"{acceptedMediaTypePrefix}*");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new DsmException(
                UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"),
                (int)response.StatusCode,
                response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
        }

        var mediaType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
        if (!mediaType.StartsWith(acceptedMediaTypePrefix, StringComparison.OrdinalIgnoreCase))
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.UnexpectedMediaType,
                "The binary response media type does not match the requested contract.");
        }
        if (response.Content.Headers.ContentLength is { } contentLength &&
            contentLength > maximumBytes)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.ResponseTooLarge,
                "The binary response exceeds the configured byte limit.");
        }

        await using var source = await response.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var destination = new MemoryStream(
            Math.Min(maximumBytes, 64 * 1024));
        var buffer = ArrayPool<byte>.Shared.Rent(64 * 1024);
        try
        {
            var total = 0;
            while (true)
            {
                var requested = total < maximumBytes
                    ? Math.Min(buffer.Length, maximumBytes - total)
                    : 1;
                var read = await source.ReadAsync(
                    buffer.AsMemory(0, requested),
                    cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }
                total += read;
                if (total > maximumBytes)
                {
                    throw new DsmBinaryResponseException(
                        DsmBinaryResponseFailure.ResponseTooLarge,
                        "The binary response exceeds the configured byte limit.");
                }
                await destination.WriteAsync(
                    buffer.AsMemory(0, read),
                    cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }

        if (destination.Length == 0)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.EmptyBody,
                "The binary response is empty.");
        }
        return new DsmBinaryResponse(destination.ToArray(), mediaType);
    }

    private static bool IsAuthenticationParameter(string name) =>
        name.Equals("_sid", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("sid", StringComparison.OrdinalIgnoreCase) ||
        name.Equals("synotoken", StringComparison.OrdinalIgnoreCase);

    public async Task<byte[]> ReadFileRangeAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string remotePath,
        long offset,
        long length,
        CancellationToken cancellationToken = default)
    {
        var result = await ReadFileRangeResultAsync(
            profile,
            session,
            capability,
            remotePath,
            offset,
            length,
            expectedContentVersion: null,
            expectedTotalLength: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (result.RequestedStart != 0 || result.RequestedLength != result.TotalLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnsafeSegmentedRead,
                "The byte-array compatibility API cannot prove consistency across multiple ranges.",
                result.StatusCode);
        }
        return result.Bytes;
    }

    public async Task<FileRangeReadResult> ReadFileRangeResultAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        string remotePath,
        long offset,
        long length,
        string? expectedContentVersion = null,
        long? expectedTotalLength = null,
        CancellationToken cancellationToken = default)
    {
        if (offset < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        if (length <= 0 || length > int.MaxValue)
        {
            throw new ArgumentOutOfRangeException(nameof(length));
        }
        var requestedEnd = length - 1 > long.MaxValue - offset
            ? throw new ArgumentOutOfRangeException(
                nameof(length),
                "The requested byte range exceeds the supported offset range.")
            : offset + length - 1;
        if (expectedTotalLength is <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(expectedTotalLength));
        }
        if (expectedTotalLength is { } knownTotalLength &&
            (offset >= knownTotalLength || length > knownTotalLength - offset))
        {
            throw new ArgumentOutOfRangeException(
                nameof(length),
                "The requested byte range exceeds the expected total length.");
        }

        EntityTagHeaderValue? expectedEntityTag = null;
        if (expectedContentVersion is not null &&
            (!EntityTagHeaderValue.TryParse(expectedContentVersion, out expectedEntityTag) ||
             expectedEntityTag is null ||
             expectedEntityTag.IsWeak))
        {
            throw new ArgumentException(
                "Expected content version must be a strong HTTP entity tag.",
                nameof(expectedContentVersion));
        }

        var path = capability.Path.StartsWith('/')
            ? capability.Path
            : $"/webapi/{capability.Path}";
        var parameters = new Dictionary<string, string>
        {
            ["api"] = capability.Name,
            ["version"] = capability.MaxVersion.ToString(),
            ["method"] = "download",
            ["path"] = JsonSerializer.Serialize(new[] { remotePath }),
            ["mode"] = "download",
            ["_sid"] = session.Sid,
        };
        var query = string.Join(
            "&",
            parameters.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            new Uri(GetBaseUri(profile), $"{path}?{query}"));
        request.Headers.Range = new RangeHeaderValue(offset, requestedEnd);
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        if (expectedEntityTag is not null)
        {
            request.Headers.IfMatch.Add(expectedEntityTag);
        }
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }
        SetNasConnectionContext(request, profile);
        using var response = await _http.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);

        if (response.StatusCode != HttpStatusCode.PartialContent)
        {
            var failure = expectedEntityTag is not null &&
                          response.StatusCode == HttpStatusCode.PreconditionFailed
                ? FileRangeContractFailure.ContentVersionMismatch
                : FileRangeContractFailure.UnexpectedStatus;
            throw new FileRangeContractException(
                failure,
                $"Expected HTTP 206 for a range response, received {(int)response.StatusCode}.",
                (int)response.StatusCode);
        }

        var contentRange = response.Content.Headers.ContentRange;
        if (contentRange is null ||
            !string.Equals(contentRange.Unit, "bytes", StringComparison.OrdinalIgnoreCase) ||
            !contentRange.HasRange ||
            !contentRange.HasLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.MissingContentRange,
                "The 206 response does not include a complete byte Content-Range header.",
                (int)response.StatusCode);
        }

        var responseStart = contentRange.From!.Value;
        var responseEnd = contentRange.To!.Value;
        var totalLength = contentRange.Length!.Value;
        if (responseStart != offset)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedRangeStart,
                $"Expected range start {offset}, received {responseStart}.",
                (int)response.StatusCode);
        }

        var responseLength = checked(responseEnd - responseStart + 1);
        if (responseLength != length)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedRangeLength,
                $"Expected range length {length}, received {responseLength}.",
                (int)response.StatusCode);
        }
        if (totalLength <= responseEnd ||
            expectedTotalLength is not null && totalLength != expectedTotalLength.Value)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedTotalLength,
                expectedTotalLength is null
                    ? $"Content-Range total length {totalLength} does not contain byte {responseEnd}."
                    : $"Expected total length {expectedTotalLength.Value}, received {totalLength}.",
                (int)response.StatusCode);
        }
        if (response.Content.Headers.ContentLength is { } contentLength &&
            contentLength != responseLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedContentLength,
                $"Content-Length {contentLength} does not match range length {responseLength}.",
                (int)response.StatusCode);
        }

        var responseEntityTag = response.Headers.ETag;
        if (expectedEntityTag is not null && responseEntityTag?.IsWeak == true)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.ContentVersionMismatch,
                "The response returned a weak content version where a strong version was required.",
                (int)response.StatusCode);
        }
        if (responseEntityTag?.IsWeak == true)
        {
            responseEntityTag = null;
        }
        if (expectedEntityTag is not null &&
            responseEntityTag is not null &&
            !string.Equals(
                responseEntityTag.Tag,
                expectedEntityTag.Tag,
                StringComparison.Ordinal))
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.ContentVersionMismatch,
                "The response content version differs from the requested version.",
                (int)response.StatusCode);
        }

        await using var source = await response.Content.ReadAsStreamAsync(
            cancellationToken).ConfigureAwait(false);
        var bytes = new byte[checked((int)responseLength)];
        var actualByteCount = 0;
        while (actualByteCount < bytes.Length)
        {
            var read = await source.ReadAsync(
                bytes.AsMemory(actualByteCount),
                cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new FileRangeContractException(
                    FileRangeContractFailure.UnexpectedBodyLength,
                    $"Expected {responseLength} response bytes, received {actualByteCount}.",
                    (int)response.StatusCode);
            }
            actualByteCount += read;
        }
        var trailingByte = new byte[1];
        if (await source.ReadAsync(trailingByte, cancellationToken).ConfigureAwait(false) != 0)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedBodyLength,
                $"The response body contains more than the expected {responseLength} bytes.",
                (int)response.StatusCode);
        }

        var serverContentVersion = responseEntityTag?.Tag ?? expectedEntityTag?.Tag;
        return new FileRangeReadResult(
            (int)response.StatusCode,
            offset,
            length,
            responseStart,
            responseLength,
            totalLength,
            actualByteCount,
            bytes,
            serverContentVersion,
            serverContentVersion is not null);
    }

    public async Task<FileUploadTransportResult> UploadFileAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        FileUploadRequest upload,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!string.Equals(
                capability.Name,
                "SYNO.FileStation.Upload",
                StringComparison.Ordinal))
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.Unsupported,
                MutationErrorCategory.Unsupported,
                "file.upload.unsupported");
        }

        var boundary = $"LanStash-{Guid.NewGuid():N}";
        var fields = new KeyValuePair<string, string>[]
        {
            new("api", capability.Name),
            new("version", capability.SelectVersion(2).ToString(
                System.Globalization.CultureInfo.InvariantCulture)),
            new("method", "upload"),
            new("_sid", session.Sid),
            new("path", upload.FolderPath),
            new("create_parents", "false"),
            new("overwrite", upload.Overwrite ? "true" : "false"),
        };
        using var content = new ExactLengthMultipartUploadContent(
            boundary,
            fields,
            upload.FileName,
            upload.Content,
            upload.Length,
            progress);
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(
                GetBaseUri(profile),
                capability.Path.StartsWith('/')
                    ? capability.Path
                    : $"/webapi/{capability.Path}"))
        {
            Content = content,
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        if (cancellationToken.IsCancellationRequested)
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.CancelledBeforeSubmission);
        }

        HttpResponseMessage response;
        try
        {
            // 调用 SendAsync 是上传的提交边界；跨过此点后任何不确定结果都禁止重放。
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.CancellationRequestedAfterSubmission,
                MutationErrorCategory.Network,
                "file.upload.cancelled-after-submit");
        }
        catch (HttpRequestException)
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.SubmittedButUnverified,
                MutationErrorCategory.Network,
                "file.upload.network-unverified");
        }
        catch (IOException)
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.SubmittedButUnverified,
                MutationErrorCategory.Network,
                "file.upload.stream-unverified");
        }
        catch (InvalidOperationException)
        {
            return new FileUploadTransportResult(
                FileUploadTransportStatus.SubmittedButUnverified,
                MutationErrorCategory.Network,
                "file.upload.replay-blocked");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.SubmittedButUnverified,
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                        ? MutationErrorCategory.Authentication
                        : MutationErrorCategory.Server,
                    "file.upload.http-unverified");
            }

            JsonObject? envelope;
            try
            {
                await using var responseStream = await response.Content
                    .ReadAsStreamAsync(cancellationToken)
                    .ConfigureAwait(false);
                envelope = await JsonNode.ParseAsync(
                    responseStream,
                    cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject;
            }
            catch (OperationCanceledException)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.CancellationRequestedAfterSubmission,
                    MutationErrorCategory.Network,
                    "file.upload.cancelled-after-submit");
            }
            catch (JsonException)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.SubmittedButUnverified,
                    MutationErrorCategory.Server,
                    "file.upload.response-unverified");
            }
            catch (HttpRequestException)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.SubmittedButUnverified,
                    MutationErrorCategory.Network,
                    "file.upload.response-unverified");
            }
            catch (IOException)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.SubmittedButUnverified,
                    MutationErrorCategory.Network,
                    "file.upload.response-unverified");
            }

            if (envelope is null)
            {
                return new FileUploadTransportResult(
                    FileUploadTransportStatus.SubmittedButUnverified,
                    MutationErrorCategory.Server,
                    "file.upload.response-unverified");
            }
            try
            {
                if (envelope["success"]?.GetValue<bool>() == true)
                {
                    return new FileUploadTransportResult(FileUploadTransportStatus.Accepted);
                }
                if (envelope["success"]?.GetValue<bool>() == false)
                {
                    var code = envelope["error"]?["code"]?.GetValue<int>();
                    return ConfirmedUploadFailure(code);
                }
            }
            catch (InvalidOperationException)
            {
                // 响应形状不符合公开 envelope，提交结果保持未知。
            }

            return new FileUploadTransportResult(
                FileUploadTransportStatus.SubmittedButUnverified,
                MutationErrorCategory.Server,
                "file.upload.response-unverified");
        }
    }

    public async Task<DownloadTaskFileCreateTransportResult> CreateDownloadTaskFromFileAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        DownloadTaskFileCreateRequest upload,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!string.Equals(
                capability.Name,
                "SYNO.DownloadStation.Task",
                StringComparison.Ordinal) ||
            capability.MinVersion > 1 ||
            capability.MaxVersion < 1 ||
            !string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) ||
            !IsSafeWebApiPath(capability.Path) ||
            profile.Id != session.ProfileId ||
            upload.ProfileId != profile.Id)
        {
            return new DownloadTaskFileCreateTransportResult(
                DownloadTaskFileCreateTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "download-station.create.file.unsupported");
        }

        var fields = new List<KeyValuePair<string, string>>
        {
            new("api", capability.Name),
            new("version", "1"),
            new("method", "create"),
            new("_sid", session.Sid),
        };
        if (!string.IsNullOrWhiteSpace(upload.Destination))
        {
            fields.Add(new("destination", upload.Destination));
        }

        var boundary = $"LanStashDownload-{Guid.NewGuid():N}";
        using var content = new ExactLengthMultipartUploadContent(
            boundary,
            fields,
            upload.FileName,
            upload.Content,
            upload.Length,
            progress);
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(
                GetBaseUri(profile),
                capability.Path.StartsWith('/')
                    ? capability.Path
                    : $"/webapi/{capability.Path}"))
        {
            Content = content,
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        if (cancellationToken.IsCancellationRequested)
        {
            return new DownloadTaskFileCreateTransportResult(
                DownloadTaskFileCreateTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "download-station.create.file.cancelled-before-submit");
        }

        HttpResponseMessage response;
        try
        {
            // SendAsync 是任务文件创建的唯一提交边界；跨过此点后任何不确定结果都禁止重放。
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new DownloadTaskFileCreateTransportResult(
                DownloadTaskFileCreateTransportStatus.CancellationRequestedAfterSubmission,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "download-station.create.file.cancelled-after-submit");
        }
        catch (Exception error) when (
            error is HttpRequestException or IOException or InvalidOperationException)
        {
            return new DownloadTaskFileCreateTransportResult(
                DownloadTaskFileCreateTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "download-station.create.file.network-unverified");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new DownloadTaskFileCreateTransportResult(
                    DownloadTaskFileCreateTransportStatus.SubmittedButUnverified,
                    ErrorCategory: response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                        ? MutationErrorCategory.Authentication
                        : MutationErrorCategory.Server,
                    DiagnosticTag: "download-station.create.file.http-unverified");
            }

            JsonObject? envelope;
            try
            {
                await using var responseStream = await response.Content
                    .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                envelope = await JsonNode.ParseAsync(
                    responseStream,
                    cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject;
            }
            catch (OperationCanceledException)
            {
                return new DownloadTaskFileCreateTransportResult(
                    DownloadTaskFileCreateTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "download-station.create.file.cancelled-after-submit");
            }
            catch (Exception error) when (
                error is JsonException or HttpRequestException or IOException)
            {
                return new DownloadTaskFileCreateTransportResult(
                    DownloadTaskFileCreateTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "download-station.create.file.response-unverified");
            }

            var success = StrictNativeBool(envelope, "success");
            if (success == true)
            {
                var taskId = StableJsonString(
                    envelope?["data"]?["taskid"] ??
                    envelope?["data"]?["task_id"] ??
                    envelope?["data"]?["taskId"] ??
                    envelope?["data"]?["id"]);
                return new DownloadTaskFileCreateTransportResult(
                    DownloadTaskFileCreateTransportStatus.Accepted,
                    TaskId: taskId,
                    DiagnosticTag: "download-station.create.file.accepted");
            }

            var code = StrictNativeInt(envelope?["error"] as JsonObject, "code");
            if (success != false || code is null)
            {
                return new DownloadTaskFileCreateTransportResult(
                    DownloadTaskFileCreateTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "download-station.create.file.response-unverified");
            }
            return ConfirmedDownloadTaskFileCreateFailure(code);
        }
    }

    public async Task<FileShareLinkTransportResult> CreateFileShareLinkAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken = default)
    {
        if (!string.Equals(capability.Name, "SYNO.FileStation.Sharing", StringComparison.Ordinal) ||
            capability.MinVersion != 3 ||
            capability.MaxVersion != 3 ||
            !string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) ||
            !IsSafeWebApiPath(capability.Path) ||
            profile.Id != session.ProfileId ||
            !ValidFileShareParameters(parameters))
        {
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "file.share.create.unsupported");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "file.share.create.cancelled-before-submit");
        }

        Uri baseUri;
        try
        {
            baseUri = GetBaseUri(profile);
        }
        catch (DsmException)
        {
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "file.share.create.invalid-endpoint");
        }

        var values = new Dictionary<string, string>(parameters, StringComparer.Ordinal)
        {
            ["api"] = capability.Name,
            ["version"] = "3",
            ["method"] = "create",
            ["_sid"] = session.Sid,
        };
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(
                baseUri,
                capability.Path.StartsWith('/')
                    ? capability.Path
                    : $"/webapi/{capability.Path}"))
        {
            Content = new FormUrlEncodedContent(values),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        HttpResponseMessage response;
        try
        {
            // SendAsync 是唯一提交边界；进入调用后任何不确定结果均禁止重放。
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.share.create.cancelled-after-submit");
        }
        catch (Exception error) when (
            error is HttpRequestException or IOException or InvalidOperationException)
        {
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "file.share.create.network-unverified");
        }

        using (response)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "file.share.create.cancelled-after-submit");
            }
            if (!response.IsSuccessStatusCode)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.SubmittedButUnverified,
                    ErrorCategory: response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                        ? MutationErrorCategory.Authentication
                        : MutationErrorCategory.Server,
                    DiagnosticTag: "file.share.create.http-unverified");
            }

            JsonObject? envelope;
            try
            {
                await using var stream = await response.Content
                    .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                envelope = await JsonNode.ParseAsync(
                    stream,
                    cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject;
            }
            catch (OperationCanceledException)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "file.share.create.cancelled-after-submit");
            }
            catch (Exception error) when (
                error is JsonException or HttpRequestException or IOException)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "file.share.create.response-unverified");
            }

            var success = StrictNativeBool(envelope, "success");
            if (success == true)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.ResponseReceived,
                    envelope?["data"]?.DeepClone());
            }
            var code = StrictNativeInt(envelope?["error"] as JsonObject, "code");
            if (success != false || code is null)
            {
                return new FileShareLinkTransportResult(
                    FileShareLinkTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "file.share.create.response-unverified");
            }
            return new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ConfirmedFailure,
                ErrorCategory: code switch
                {
                    105 => MutationErrorCategory.Permission,
                    _ => MutationErrorCategory.Server,
                },
                DiagnosticTag: code is >= 100 and <= 9999
                    ? $"file.share.create.dsm-{code}"
                    : "file.share.create.dsm-failure");
        }
    }

    private static bool? StrictNativeBool(JsonObject? item, string key) =>
        item?[key] is JsonValue value && value.TryGetValue<bool>(out var result)
            ? result
            : null;

    private static int? StrictNativeInt(JsonObject? item, string key) =>
        item?[key] is JsonValue value && value.TryGetValue<int>(out var result)
            ? result
            : null;

    private static string? StableJsonString(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<string>(out var text))
        {
            var trimmed = text.Trim();
            return trimmed.Length == 0 ? null : trimmed;
        }
        if (value.TryGetValue<long>(out var longValue))
        {
            return longValue.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<int>(out var intValue))
        {
            return intValue.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        return null;
    }

    private static bool IsSafeWebApiPath(string path) =>
        !string.IsNullOrWhiteSpace(path) &&
        !Uri.TryCreate(path, UriKind.Absolute, out _) &&
        !path.StartsWith("//", StringComparison.Ordinal) &&
        !path.StartsWith('\\') &&
        !path.Contains('\\') &&
        !path.Contains("..", StringComparison.Ordinal) &&
        !path.Contains('?') &&
        !path.Contains('#');

    private static bool ValidFileShareParameters(IReadOnlyDictionary<string, string> parameters)
    {
        if (parameters.Keys.Any(key => key is not ("path" or "password" or "date_expired")) ||
            !parameters.TryGetValue("path", out var encodedPath))
        {
            return false;
        }
        try
        {
            if (JsonNode.Parse(encodedPath) is not JsonArray { Count: 1 } paths ||
                paths[0] is not JsonValue pathNode ||
                !pathNode.TryGetValue<string>(out var path) ||
                string.IsNullOrEmpty(path) ||
                path.Length <= 1 ||
                !path.StartsWith('/') ||
                path.EndsWith('/') ||
                path.Contains("//", StringComparison.Ordinal) ||
                path.Contains('\\') ||
                path.Split('/').Any(component => component is "." or ".."))
            {
                return false;
            }
        }
        catch (JsonException)
        {
            return false;
        }
        if (parameters.TryGetValue("password", out var password) &&
            (password.Length == 0 || new System.Globalization.StringInfo(password).LengthInTextElements > 16))
        {
            return false;
        }
        return !parameters.TryGetValue("date_expired", out var expiry) ||
            DateOnly.TryParseExact(
                expiry,
                "yyyy-MM-dd",
                System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None,
                out _);
    }

    private static FileUploadTransportResult ConfirmedUploadFailure(int? code)
    {
        var category = code switch
        {
            105 or 115 => MutationErrorCategory.Permission,
            106 or 107 or 119 => MutationErrorCategory.Authentication,
            1805 => MutationErrorCategory.Conflict,
            _ => MutationErrorCategory.Server,
        };
        var diagnostic = code is >= 100 and <= 9999
            ? $"file.upload.dsm-{code}"
            : "file.upload.dsm-failure";
        return new FileUploadTransportResult(
            FileUploadTransportStatus.ConfirmedFailure,
            category,
            diagnostic);
    }

    private static DownloadTaskFileCreateTransportResult ConfirmedDownloadTaskFileCreateFailure(int? code)
    {
        var category = code switch
        {
            105 or 115 => MutationErrorCategory.Permission,
            106 or 107 or 119 => MutationErrorCategory.Authentication,
            1805 => MutationErrorCategory.Conflict,
            _ => MutationErrorCategory.Server,
        };
        var diagnostic = code is >= 100 and <= 9999
            ? $"download-station.create.file.dsm-{code}"
            : "download-station.create.file.dsm-failure";
        return new DownloadTaskFileCreateTransportResult(
            DownloadTaskFileCreateTransportStatus.ConfirmedFailure,
            ErrorCategory: category,
            DiagnosticTag: diagnostic);
    }

    private Task<JsonObject> PostAsync(
        NasProfile profile,
        string path,
        IReadOnlyDictionary<string, string> parameters,
        DsmSession? session,
        CancellationToken cancellationToken) =>
        PostAsync(
            profile,
            path,
            parameters,
            session,
            DsmConnectionSource.DirectAddress,
            cancellationToken);

    private async Task<JsonObject> PostAsync(
        NasProfile profile,
        string path,
        IReadOnlyDictionary<string, string> parameters,
        DsmSession? session,
        DsmConnectionSource source,
        CancellationToken cancellationToken)
    {
        var values = new Dictionary<string, string>(parameters, StringComparer.Ordinal);
        if (session is not null)
        {
            values["_sid"] = session.Sid;
        }
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            new Uri(GetBaseUri(profile), path))
        {
            Content = new FormUrlEncodedContent(values),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        WindowsCertificateTrustHandler.SetConnectionContext(
            request,
            profile.Id,
            source);
        if (session is not null)
        {
            request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
            if (!string.IsNullOrWhiteSpace(session.SynoToken))
            {
                request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
            }
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new DsmException(
                UserText.Key("WinShared5a870c4775a4ef6b"),
                UserText.Key("WinShared199c5367bae9682d"));
        }
        catch (HttpRequestException)
        {
            throw new DsmException(
                UserText.Key("WinSharedf91eef8a1cf7b01c"),
                UserText.Key("WinShared79c4d60046afa3ff"));
        }
        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                throw new DsmException(
                    UserText.Key("WinSharedf91eef8a1cf7b01c"),
                    UserText.Key("WinShared79c4d60046afa3ff"),
                    (int)response.StatusCode,
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden);
            }
            await using var stream = await response.Content
                .ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            var envelope = await JsonNode.ParseAsync(
                stream,
                cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject
                ?? throw new DsmException(
                    UserText.Key("WinShared9cb9ec075b03b6cb"),
                    UserText.Key("WinShared09f262a53ad074ca"));
            if (envelope["success"]?.GetValue<bool>() == true)
            {
                return envelope["data"] switch
                {
                    JsonObject dataObject => dataObject,
                    JsonArray dataArray => new JsonObject
                    {
                        [DsmApiResponseKeys.RootArray] = dataArray.DeepClone(),
                    },
                    _ => [],
                };
            }
            var code = envelope["error"]?["code"]?.GetValue<int>();
            throw MapFailure(code);
        }
    }

    private static DsmException MapFailure(int? code) => code switch
    {
        102 => new(UserText.Key("WinShared11a208e43c34b77c"), UserText.Key("WinShared371d84f48836296f"), code),
        103 => new(UserText.Key("WinShared189ee06b7da78f3f"), UserText.Key("WinSharedb5641013fbf13d8b"), code),
        104 => new(UserText.Key("WinSharedd727aa9e0a8cff65"), UserText.Key("WinSharedc144a2dc9ace5c1f"), code, true),
        105 => new(UserText.Key("WinShared12188668a1d4cff1"), UserText.Key("WinShared4a1330714c58b25d"), code),
        406 => new(UserText.Key("WinShared3cd43f3a371513e2"), UserText.Key("WinShared46e3e4901826eb40"), code, true),
        407 => new(UserText.Key("WinSharedef0eed96e1f28ed8"), UserText.Key("WinShared2ad42c7573d49cbc"), code, true),
        400 or 401 or 402 or 403 or 404 =>
            new(UserText.Key("WinShared78eee40d2f30576e"), UserText.Key("WinShared2f7ffa8e29481728"), code, true),
        _ => new(UserText.Key("WinShared0addf7c060c570ce"), UserText.Key("WinShared5448ceb91a80e260"), code),
    };

    private sealed class ExactLengthMultipartUploadContent : HttpContent
    {
        private const int BufferSize = 64 * 1024;
        private readonly byte[] _prefix;
        private readonly byte[] _suffix;
        private readonly Stream _source;
        private readonly long _sourceLength;
        private readonly IProgress<long>? _progress;
        private readonly long _contentLength;
        private int _serializationStarted;

        public ExactLengthMultipartUploadContent(
            string boundary,
            IReadOnlyList<KeyValuePair<string, string>> fields,
            string fileName,
            Stream source,
            long sourceLength,
            IProgress<long>? progress)
        {
            _source = source;
            _sourceLength = sourceLength;
            _progress = progress;
            _prefix = BuildPrefix(boundary, fields, fileName);
            _suffix = Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");
            _contentLength = checked((long)_prefix.Length + sourceLength + _suffix.Length);
            Headers.ContentType = new MediaTypeHeaderValue("multipart/form-data");
            Headers.ContentType.Parameters.Add(new NameValueHeaderValue("boundary", boundary));
            Headers.ContentLength = _contentLength;
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _contentLength;
            return true;
        }

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context) =>
            SerializeToStreamCoreAsync(stream, CancellationToken.None);

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context,
            CancellationToken cancellationToken) =>
            SerializeToStreamCoreAsync(stream, cancellationToken);

        private async Task SerializeToStreamCoreAsync(
            Stream destination,
            CancellationToken cancellationToken)
        {
            if (Interlocked.Exchange(ref _serializationStarted, 1) != 0)
            {
                throw new InvalidOperationException("upload.automatic_replay_blocked");
            }
            await destination.WriteAsync(_prefix, cancellationToken).ConfigureAwait(false);
            var buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
            try
            {
                long copied = 0;
                _progress?.Report(0);
                while (copied < _sourceLength)
                {
                    var requested = (int)Math.Min(BufferSize, _sourceLength - copied);
                    var read = await _source.ReadAsync(
                        buffer.AsMemory(0, requested),
                        cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        throw new EndOfStreamException("upload.source_shorter_than_declared");
                    }
                    await destination.WriteAsync(
                        buffer.AsMemory(0, read),
                        cancellationToken).ConfigureAwait(false);
                    copied += read;
                    _progress?.Report(copied);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
            await destination.WriteAsync(_suffix, cancellationToken).ConfigureAwait(false);
        }

        private static byte[] BuildPrefix(
            string boundary,
            IReadOnlyList<KeyValuePair<string, string>> fields,
            string fileName)
        {
            var builder = new StringBuilder();
            foreach (var (name, value) in fields)
            {
                builder.Append("--").Append(boundary).Append("\r\n")
                    .Append("Content-Disposition: form-data; name=\"")
                    .Append(name).Append("\"\r\n\r\n")
                    .Append(value).Append("\r\n");
            }
            var safeFileName = fileName.Replace('"', '\'');
            builder.Append("--").Append(boundary).Append("\r\n")
                .Append("Content-Disposition: form-data; name=\"file\"; filename=\"")
                .Append(safeFileName).Append("\"\r\n")
                .Append("Content-Type: application/octet-stream\r\n\r\n");
            return Encoding.UTF8.GetBytes(builder.ToString());
        }
    }
}

internal static class DsmApiResponseKeys
{
    public const string RootArray = "$root";
}
