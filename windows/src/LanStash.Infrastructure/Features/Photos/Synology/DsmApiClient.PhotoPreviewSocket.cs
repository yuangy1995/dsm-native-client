using System.Net;
using System.Net.WebSockets;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<ISynologyPhotoPreviewCompletion> SubscribePhotoPreviewAsync(NasProfile profile, DsmSession session,
        long unitId, CancellationToken cancellationToken = default)
    {
        var origin = GetBaseUri(profile);
        ValidateRealtimeSession(profile, session, origin);
        var events = new SynologyPhotoPreviewEvents(token => ConnectPhotoPreviewSocketAsync(profile, session, origin, token));
        await events.SubscribeAsync(unitId, cancellationToken).ConfigureAwait(false);
        return events;
    }

    internal static Uri PhotoPreviewSocketUri(Uri applicationBase, string? token)
    {
        // 配置基址保留反向代理目录；Photos 页面与已验证基址同源，不接受响应提供的新地址。
        if (!applicationBase.IsAbsoluteUri || applicationBase.Scheme != Uri.UriSchemeHttps ||
            string.IsNullOrEmpty(applicationBase.Host) || applicationBase.UserInfo.Length != 0 ||
            applicationBase.Query.Length != 0 || applicationBase.Fragment.Length != 0 || token?.Any(char.IsControl) == true)
            throw new ArgumentException("photos.preview.invalid-endpoint");
        return new UriBuilder(applicationBase)
        {
            Scheme = "wss", Port = applicationBase.Port,
            Path = applicationBase.AbsolutePath.TrimEnd('/') + "/FotoSocketIo/socket.io/",
            Query = "EIO=4&transport=websocket" + (string.IsNullOrEmpty(token) ? "" : "&SynoToken=" + Uri.EscapeDataString(token)),
        }.Uri;
    }

    internal async Task<WebSocket> ConnectPhotoPreviewSocketAsync(NasProfile profile, DsmSession session, Uri origin, CancellationToken token)
    {
        ValidateRealtimeSession(profile, session, origin);
        if (origin != GetBaseUri(profile)) throw new ArgumentException("photos.preview.foreign-origin");
        var uri = PhotoPreviewSocketUri(origin, session.SynoToken);
        var socket = new ClientWebSocket();
        socket.Options.HttpVersion = HttpVersion.Version11;
        socket.Options.HttpVersionPolicy = HttpVersionPolicy.RequestVersionExact;
        socket.Options.KeepAliveInterval = Timeout.InfiniteTimeSpan;
        // 复用原证书/会话握手；官方查询令牌例外只驻内存，不向外传播含 URL 的底层错误。
        using var invoker = new HttpMessageInvoker(new NasWebSocketHandshakeHandler(_http, profile, session, origin, uri));
        try { await socket.ConnectAsync(uri, invoker, token).ConfigureAwait(false); return socket; }
        catch (OperationCanceledException) { socket.Dispose(); throw new OperationCanceledException(token); }
        catch (WebSocketException error) when (error.InnerException is HttpRequestException
            { HttpRequestError: HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError })
        { socket.Dispose(); throw new PhotoPreviewEventException(PhotoPreviewEventFailure.Disconnected); }
        catch { socket.Dispose(); throw new PhotoPreviewEventException(PhotoPreviewEventFailure.ConnectionRejected); }
    }
}
