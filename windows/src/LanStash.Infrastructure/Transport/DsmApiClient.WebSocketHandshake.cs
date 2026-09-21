using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    // Chat 与控制台共用原 HttpClient；包装器不持有其释放权，不增加证书放行分支。
    private sealed class NasWebSocketHandshakeHandler(HttpClient client, NasProfile profile, DsmSession session, Uri origin, Uri socketUri) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var expected = new UriBuilder(socketUri) { Scheme = Uri.UriSchemeHttps, Port = socketUri.Port }.Uri;
            if (request.RequestUri != socketUri || request.Method != HttpMethod.Get)
                throw new InvalidOperationException("nas.websocket.foreign-handshake");
            request.RequestUri = expected;
            WindowsCertificateTrustHandler.SetConnectionContext(request, profile.Id, DsmConnectionSource.DirectAddress);
            request.Headers.TryAddWithoutValidation("Cookie", "id=" + session.Sid);
            if (!string.IsNullOrWhiteSpace(session.SynoToken)) request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
            request.Headers.TryAddWithoutValidation("Origin", origin.GetLeftPart(UriPartial.Authority));
            return client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
    }
}
