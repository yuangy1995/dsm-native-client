using System.Net;
using System.Net.WebSockets;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public bool CanConnectConsoleSocket => true;
    public async Task<WebSocket> ConnectConsoleSocketAsync(NasProfile profile, DsmSession session,
        VirtualMachineConsolePolicy policy, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(policy);
        var origin = GetBaseUri(profile);
        if (profile.Id == Guid.Empty || profile.Id != session.ProfileId || !policy.MatchesOrigin(origin) ||
            !VirtualMachineConsoleSession.ValidCookie(session.Sid) ||
            !string.IsNullOrWhiteSpace(session.SynoToken) && !VirtualMachineConsoleSession.ValidCookie(session.SynoToken))
            throw new InvalidOperationException("vm.console.session_origin");
        var socketUri = policy.SocketUri ?? throw new NotSupportedException("vm.console.socket_unavailable");
        cancellationToken.ThrowIfCancellationRequested();
        var socket = new ClientWebSocket();
        socket.Options.HttpVersion = HttpVersion.Version11;
        socket.Options.HttpVersionPolicy = HttpVersionPolicy.RequestVersionExact;
        socket.Options.AddSubProtocol("binary");
        using var invoker = new HttpMessageInvoker(new NasWebSocketHandshakeHandler(_http, profile, session, origin, socketUri));
        try { await socket.ConnectAsync(socketUri, invoker, cancellationToken).ConfigureAwait(false); return socket; }
        catch { socket.Dispose(); throw; }
    }
}
