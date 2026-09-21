using System.Net;
using System.Net.WebSockets;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public IAsyncEnumerable<ChatRealtimeEvent> ObserveChatRealtimeAsync(NasProfile profile, DsmSession session,
        CancellationToken cancellationToken = default)
    {
        var baseUri = GetBaseUri(profile);
        ValidateRealtimeSession(profile, session, baseUri);
        return new DsmChatRealtimeClient((version, token) => ConnectChatSocketAsync(profile, session, baseUri, version, token))
            .ObserveAsync(cancellationToken);
    }

    internal static Uri ChatSocketUri(Uri baseUri, int engineVersion)
    {
        if (!baseUri.IsAbsoluteUri || baseUri.Scheme != Uri.UriSchemeHttps || string.IsNullOrEmpty(baseUri.Host) ||
            baseUri.UserInfo.Length != 0 || baseUri.Query.Length != 0 || baseUri.Fragment.Length != 0 || engineVersion is not (3 or 4))
            throw new ArgumentException("chat.realtime.invalid-endpoint");
        return new UriBuilder(baseUri)
        {
            Scheme = "wss", Port = baseUri.Port, Path = baseUri.AbsolutePath.TrimEnd('/') + "/sc/socket.io/",
            Query = $"EIO={engineVersion}&transport=websocket", Fragment = "",
        }.Uri;
    }

    private static void ValidateRealtimeSession(NasProfile profile, DsmSession session, Uri baseUri)
    {
        _ = ChatSocketUri(baseUri, 4);
        if (profile.Id == Guid.Empty || session.ProfileId != profile.Id || string.IsNullOrWhiteSpace(session.Sid) ||
            session.Sid.Any(character => char.IsControl(character) || char.IsWhiteSpace(character) || character is ';' or ',') ||
            session.SynoToken?.Any(char.IsControl) == true)
            throw new ArgumentException("chat.realtime.invalid-session");
    }

    internal async Task<WebSocket> ConnectChatSocketAsync(NasProfile profile, DsmSession session, Uri baseUri,
        int engineVersion, CancellationToken token)
    {
        ValidateRealtimeSession(profile, session, baseUri);
        if (baseUri != GetBaseUri(profile)) throw new ArgumentException("chat.realtime.foreign-origin");
        var uri = ChatSocketUri(baseUri, engineVersion);
        var socket = new ClientWebSocket();
        socket.Options.HttpVersion = HttpVersion.Version11;
        socket.Options.HttpVersionPolicy = HttpVersionPolicy.RequestVersionExact;
        socket.Options.KeepAliveInterval = Timeout.InfiniteTimeSpan;
        // 握手使用原 HttpClient，保留 profile 证书钉扎和 QuickConnect 的系统信任约束。
        using var invoker = new HttpMessageInvoker(new NasWebSocketHandshakeHandler(_http, profile, session, baseUri, uri));
        try { await socket.ConnectAsync(uri, invoker, token).ConfigureAwait(false); return socket; }
        catch { socket.Dispose(); throw; }
    }

}
