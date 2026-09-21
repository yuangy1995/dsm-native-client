using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public enum QuickConnectEndpointKind
{
    Local,
    External,
    Relay,
}

public sealed record QuickConnectEndpoint(string Host, int Port, QuickConnectEndpointKind Kind);

/// <summary>
/// 受限使用 Synology QuickConnect 当前客户端契约。
/// get_server_info、request_tunnel 属于未公开的内部 API；登录前会限制官方域名并验证中继身份。
/// </summary>
public sealed class DsmQuickConnectResolver(HttpClient httpClient)
{
    private const int MaximumResponseBytes = 1024 * 1024;
    private readonly HttpClient _http = httpClient;
    private static readonly string[] ControlUrls =
    [
        "https://global.quickconnect.to/Serv.php",
        "https://global.quickconnect.cn/Serv.php",
    ];

    public async Task<IReadOnlyList<QuickConnectEndpoint>> ResolveAsync(
        string id,
        CancellationToken cancellationToken = default)
    {
        ValidateId(id);
        // 在线但没有直连候选时保留结果，让连接层继续中继，不能被另一区域的失败覆盖。
        return DecodeEndpoints(await QueryServerInfoAsync(id, cancellationToken).ConfigureAwait(false));
    }

    public async Task<QuickConnectEndpoint> RequestRelayAsync(
        string id,
        CancellationToken cancellationToken = default)
    {
        ValidateId(id);
        var controlUrl = await ResolveControlUrlAsync(id, cancellationToken).ConfigureAwait(false);
        DsmException? lastError = null;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                var descriptor = DecodeRelayDescriptor(await SendAsync(
                    "request_tunnel", true, id, controlUrl, cancellationToken).ConfigureAwait(false), id);
                await VerifyRelayAsync(descriptor, cancellationToken).ConfigureAwait(false);
                return descriptor.Endpoint;
            }
            catch (DsmException error) when (
                error.Kind is not DsmErrorKind.QuickConnectRelayDisabled and
                not DsmErrorKind.QuickConnectIdentityMismatch)
            {
                lastError = error;
                if (attempt < 2)
                {
                    await Task.Delay((attempt + 1) * 1000, cancellationToken).ConfigureAwait(false);
                }
            }
        }
        throw lastError ?? RelayUnavailable();
    }

    public static IReadOnlyList<QuickConnectEndpoint> DecodeEndpoints(JsonArray responses)
    {
        var response = SuccessfulResponse(responses);
        if (!string.Equals(response["server"]?["ds_state"]?.GetValue<string>(), "CONNECTED",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new DsmException(
                UserText.Key("WinSharede32c368700e2b141"),
                UserText.Key("WinSharede0abefcec6920022"),
                kind: DsmErrorKind.QuickConnectOffline);
        }
        var port = response["service"]?["port"]?.GetValue<int>() ?? 0;
        var smartDns = response["smartdns"] as JsonObject;
        if (port is < 1 or > 65535 || smartDns is null)
        {
            throw NoDirectRoute();
        }

        var endpoints = new List<QuickConnectEndpoint>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (smartDns["lan"] is JsonArray lan)
        {
            foreach (var value in lan)
            {
                var host = value is JsonObject item
                    ? item["host"]?.GetValue<string>()
                    : value?.GetValue<string>();
                AddTrustedDirect(endpoints, seen, host, port, QuickConnectEndpointKind.Local);
            }
        }
        AddTrustedDirect(
            endpoints,
            seen,
            smartDns["host"]?.GetValue<string>(),
            port,
            QuickConnectEndpointKind.External);
        return endpoints.Count > 0 ? endpoints : throw NoDirectRoute();
    }

    private async Task<string> ResolveControlUrlAsync(string id, CancellationToken cancellationToken)
    {
        var response = SuccessfulResponse(await QueryServerInfoAsync(id, cancellationToken).ConfigureAwait(false));
        var host = response["env"]?["control_host"]?.GetValue<string>()?.ToLowerInvariant();
        if (host is null || !IsTrustedControlHost(host)) throw InvalidResponse();
        return $"https://{host}/Serv.php";
    }

    private async Task<JsonArray> QueryServerInfoAsync(string id, CancellationToken cancellationToken)
    {
        DsmException? lastError = null;
        var pending = new Queue<string>(ControlUrls);
        var scheduled = new HashSet<string>(ControlUrls, StringComparer.OrdinalIgnoreCase);
        // 官方控制响应的 sites 是后续查询位置，不是设备不存在；限制域名、去重及总请求数。
        while (pending.TryDequeue(out var controlUrl))
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var responses = await SendAsync("get_server_info", false, id, controlUrl, cancellationToken).ConfigureAwait(false);
                if (responses.OfType<JsonObject>().Any(item => item["errno"]?.GetValue<int>() == 0)) return responses;
                foreach (var response in responses.OfType<JsonObject>())
                {
                    if (response["sites"] is not JsonArray sites) continue;
                    foreach (var site in sites)
                    {
                        if (site is not JsonValue value || !value.TryGetValue<string>(out var host) || !IsTrustedControlHost(host))
                            throw InvalidResponse();
                        var url = $"https://{host.ToLowerInvariant()}/Serv.php";
                        if (scheduled.Count < 8 && scheduled.Add(url)) pending.Enqueue(url);
                    }
                }
                _ = SuccessfulResponse(responses);
            }
            catch (DsmException error)
            {
                lastError = error;
            }
        }
        throw lastError ?? ServiceUnavailable();
    }

    private async Task<JsonArray> SendAsync(
        string command,
        bool stopWhenSuccess,
        string serverId,
        string controlUrl,
        CancellationToken cancellationToken)
    {
        var payload = new JsonArray
        {
            new JsonObject
            {
                ["version"] = 1,
                ["command"] = command,
                ["stop_when_error"] = false,
                ["stop_when_success"] = stopWhenSuccess,
                ["id"] = "mainapp_https",
                ["serverID"] = serverId,
                ["is_gofile"] = false,
                ["path"] = "",
            },
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, controlUrl)
        {
            Content = new StringContent(payload.ToJsonString(), Encoding.UTF8, "application/json"),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(command == "request_tunnel" ? TimeSpan.FromSeconds(30) : TimeSpan.FromSeconds(15));
        try
        {
            using var response = await _http.SendAsync(
                request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                throw ServiceUnavailable();
            }
            return await ReadJsonArrayAsync(response, timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw ServiceUnavailable();
        }
        catch (HttpRequestException)
        {
            throw ServiceUnavailable();
        }
    }

    private async Task VerifyRelayAsync(RelayDescriptor descriptor, CancellationToken cancellationToken)
    {
        if (!descriptor.PingPongPath.StartsWith('/') ||
            descriptor.PingPongPath.Length > 2048 ||
            descriptor.PingPongPath.Contains("://", StringComparison.Ordinal) ||
            descriptor.PingPongPath.Contains('#'))
        {
            throw InvalidResponse();
        }
        var expectedId = Convert.ToHexString(
            MD5.HashData(Encoding.UTF8.GetBytes(descriptor.ServerId))).ToLowerInvariant();
        var uri = new Uri($"https://{descriptor.Endpoint.Host}{descriptor.PingPongPath}");
        for (var attempt = 0; attempt < 6; attempt++)
        {
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, uri);
                request.Headers.Accept.ParseAdd("application/json");
                request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
                using var response = await _http.SendAsync(
                    request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    throw RelayUnavailable();
                }
                var json = await ReadJsonObjectAsync(response, cancellationToken).ConfigureAwait(false);
                if (!string.Equals(json["ezid"]?.GetValue<string>(), expectedId, StringComparison.OrdinalIgnoreCase))
                {
                    throw new DsmException(
                        UserText.Key("WinShared408b64a41c09d2a0"),
                        UserText.Key("WinShared51f93605004a3258"),
                        kind: DsmErrorKind.QuickConnectIdentityMismatch);
                }
                return;
            }
            catch (DsmException error) when (
                error.Kind != DsmErrorKind.QuickConnectIdentityMismatch && attempt < 5)
            {
                await Task.Delay(1000, cancellationToken).ConfigureAwait(false);
            }
            catch (HttpRequestException) when (attempt < 5)
            {
                await Task.Delay(1000, cancellationToken).ConfigureAwait(false);
            }
        }
        throw RelayUnavailable();
    }

    private static RelayDescriptor DecodeRelayDescriptor(JsonArray responses, string id)
    {
        if (responses.OfType<JsonObject>().Any(item => item["errno"]?.GetValue<int>() == 19))
        {
            throw new DsmException(
                UserText.Key("WinSharedd11595c8e583c9ea"),
                UserText.Key("WinShared6730f03f8272b1f9"),
                kind: DsmErrorKind.QuickConnectRelayDisabled);
        }
        var response = SuccessfulResponse(responses);
        var service = response["service"] as JsonObject;
        var server = response["server"] as JsonObject;
        var environment = response["env"] as JsonObject;
        var relayPort = service?["relay_port"]?.GetValue<int>() ?? 0;
        var serverId = server?["serverID"]?.GetValue<string>();
        var region = environment?["relay_region"]?.GetValue<string>()?.ToLowerInvariant();
        var controlHost = environment?["control_host"]?.GetValue<string>()?.ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(service?["relay_ip"]?.GetValue<string>()) ||
            relayPort is < 1 or > 65535 ||
            string.IsNullOrWhiteSpace(serverId) ||
            region is null || !IsValidHostLabel(region) ||
            controlHost is null || !IsTrustedControlHost(controlHost))
        {
            throw RelayUnavailable();
        }
        var topDomain = controlHost.EndsWith(".quickconnect.cn", StringComparison.Ordinal) ? "cn" : "to";
        var host = $"{id.ToLowerInvariant()}.{region}.quickconnect.{topDomain}";
        if (!IsTrustedRelayHost(host))
        {
            throw InvalidResponse();
        }
        return new(
            new QuickConnectEndpoint(host, 443, QuickConnectEndpointKind.Relay),
            serverId,
            server?["pingpong_path"]?.GetValue<string>()
                ?? "/webman/pingpong.cgi?action=cors&quickconnect=true");
    }

    public static bool IsTrustedRelayHost(string host)
    {
        var labels = host.ToLowerInvariant().Split('.');
        return labels.Length == 4 &&
            labels[2] == "quickconnect" &&
            labels[3] is "to" or "cn" &&
            IsValidHostLabel(labels[0]) &&
            IsValidHostLabel(labels[1]);
    }

    private static JsonObject SuccessfulResponse(JsonArray responses) =>
        responses.OfType<JsonObject>().FirstOrDefault(item => item["errno"]?.GetValue<int>() == 0)
        ?? throw new DsmException(
            UserText.Key("WinShared35964d160c6c4b32"),
            UserText.Key("WinShared36d42da6d6cea95f"),
            kind: DsmErrorKind.QuickConnectNotFound);

    private static void AddTrustedDirect(
        ICollection<QuickConnectEndpoint> endpoints,
        ISet<string> seen,
        string? rawHost,
        int port,
        QuickConnectEndpointKind kind)
    {
        var host = rawHost?.ToLowerInvariant();
        if (host is not null && IsTrustedDirectHost(host) && seen.Add(host))
        {
            endpoints.Add(new(host, port, kind));
        }
    }

    private static bool IsTrustedDirectHost(string host)
    {
        var labels = host.Split('.');
        return labels.Length >= 4 &&
            labels[^3] == "direct" &&
            labels[^2] == "quickconnect" &&
            labels[^1] is "to" or "cn" &&
            labels.All(IsValidHostLabel);
    }

    private static bool IsTrustedControlHost(string host) =>
        (host.EndsWith(".quickconnect.to", StringComparison.Ordinal) ||
         host.EndsWith(".quickconnect.cn", StringComparison.Ordinal)) &&
        host.Split('.').All(IsValidHostLabel);

    private static bool IsValidHostLabel(string value) =>
        value.Length is >= 1 and <= 63 &&
        value[0] != '-' &&
        value[^1] != '-' &&
        value.All(character =>
            character is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-');

    private static void ValidateId(string id)
    {
        if (!NasAddressParser.IsPotentialQuickConnectId(id))
        {
            throw new DsmException(
                UserText.Key("WinShared03b4e19bbedaaf48"),
                UserText.Key("WinShared89c44574bbf9988a"),
                kind: DsmErrorKind.InvalidQuickConnectId);
        }
    }

    private static async Task<JsonArray> ReadJsonArrayAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var node = await ReadJsonAsync(response, cancellationToken).ConfigureAwait(false);
        return node as JsonArray ?? throw InvalidResponse();
    }

    private static async Task<JsonObject> ReadJsonObjectAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var node = await ReadJsonAsync(response, cancellationToken).ConfigureAwait(false);
        return node as JsonObject ?? throw RelayUnavailable();
    }

    private static async Task<JsonNode?> ReadJsonAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.Content.Headers.ContentLength > MaximumResponseBytes)
        {
            throw InvalidResponse();
        }
        await using var source = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var memory = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0)
            {
                break;
            }
            if (memory.Length + count > MaximumResponseBytes)
            {
                throw InvalidResponse();
            }
            await memory.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
        }
        memory.Position = 0;
        return await JsonNode.ParseAsync(memory, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private static DsmException NoDirectRoute() => new(
        UserText.Key("WinShared2185bc1f61ec5011"),
        UserText.Key("WinSharedc157df0fa964b080"),
        kind: DsmErrorKind.QuickConnectDirectUnavailable);
    private static DsmException ServiceUnavailable() => new(
        UserText.Key("WinShared5634da8d0d5a2089"),
        UserText.Key("WinSharedefc81ced18eb3bb0"),
        kind: DsmErrorKind.QuickConnectServiceUnavailable);
    private static DsmException InvalidResponse() => new(
        UserText.Key("WinSharedda35e58bcad31766"),
        UserText.Key("WinSharedefc81ced18eb3bb0"),
        kind: DsmErrorKind.QuickConnectInvalidResponse);
    private static DsmException RelayUnavailable() => new(
        UserText.Key("WinShared165059223c7f83c1"),
        UserText.Key("WinSharedefc81ced18eb3bb0"),
        kind: DsmErrorKind.QuickConnectRelayUnavailable);

    private sealed record RelayDescriptor(
        QuickConnectEndpoint Endpoint,
        string ServerId,
        string PingPongPath);
}
