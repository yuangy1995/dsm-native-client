using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Photos;

public sealed class SynologyPhotoPreviewEventsTests
{
    private const string Open = "0{\"sid\":\"synthetic\",\"pingInterval\":25000,\"pingTimeout\":20000}";
    private static string Completion(long unit, bool success) => "42" + JsonSerializer.Serialize(new object[]
        { "regenerate-preview", new { data = new { idUnit = unit, success } } });
    private static FakeSocket Ready()
    { var socket = new FakeSocket(); socket.Queue(Open); socket.Queue("40"); return socket; }
    private static SynologyPhotoPreviewEvents Events(FakeSocket socket) => new(_ => Task.FromResult<WebSocket>(socket), TimeSpan.FromSeconds(2));

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task SubscriptionPrecedesCompletionAndOnlyExactTargetHasAResult(bool success)
    {
        using var socket = Ready(); await using var events = Events(socket);
        await events.SubscribeAsync(7, CancellationToken.None);
        Assert.Equal("40", socket.Sent[0]); Assert.Equal(PhotoPreviewPacket.Registration(7), socket.Sent[1]);
        socket.Queue("2"); socket.Queue(Completion(8, !success)); socket.Queue("42[\"unrelated\",{}]"); socket.Queue(Completion(7, success));
        Assert.Equal(success, await events.CompletionAsync());
        Assert.Equal("3", socket.Sent[2]); Assert.Equal(3, socket.Sent.Count); Assert.True(socket.Aborted);
        Assert.DoesNotContain(socket.Sent, text => text.Contains("regenerate_preview_by_nas") || text.Contains("set_regenerating"));
    }

    [Theory]
    [InlineData("0{}")]
    [InlineData("0{\"sid\":\"synthetic\",\"pingInterval\":0,\"pingTimeout\":20}")]
    [InlineData("0{\"sid\":\"synthetic\",\"pingInterval\":10}")]
    [InlineData("40{}")]
    [InlineData("42[]")]
    [InlineData("42[\"regenerate-preview\",{}]")]
    [InlineData("42[\"regenerate-preview\",{\"data\":{\"idUnit\":7,\"success\":1}}]")]
    [InlineData("42[\"regenerate-preview\",{\"data\":{\"idUnit\":\"7\",\"success\":true}}]")]
    [InlineData("42[\"regenerate-preview\",{\"data\":{\"idUnit\":0,\"success\":true}}]")]
    [InlineData("42[\"regenerate-preview\",{\"data\":{\"idUnit\":7,\"success\":true}},{}]")]
    public void InvalidPacketsCannotBecomeResults(string packet) =>
        Assert.Equal(PhotoPreviewEventFailure.InvalidFrame, Assert.Throws<PhotoPreviewEventException>(() => PhotoPreviewPacket.Decode(packet)).Failure);

    [Theory]
    [InlineData("40")]
    [InlineData("42[\"regenerate-preview\",{\"data\":{\"idUnit\":7,\"success\":true}}]")]
    [InlineData("0{\"sid\":\"a\",\"pingInterval\":1,\"pingTimeout\":1}")]
    public async Task InvalidHandshakeOrderClosesTheSocket(string packet)
    {
        using var socket = new FakeSocket();
        if (packet.StartsWith('0')) socket.Queue(Open);
        socket.Queue(packet); await using var events = Events(socket);
        Assert.Equal(PhotoPreviewEventFailure.InvalidFrame,
            (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.SubscribeAsync(7, CancellationToken.None))).Failure);
        Assert.True(socket.Aborted);
    }

    [Theory]
    [InlineData("44{\"message\":\"synthetic\"}", (int)PhotoPreviewEventFailure.ConnectionRejected)]
    [InlineData("40", (int)PhotoPreviewEventFailure.InvalidFrame)]
    [InlineData("42[\"regenerate-preview\",{}]", (int)PhotoPreviewEventFailure.InvalidFrame)]
    public async Task ProtocolRejectionDoesNotReconnect(string packet, int expected)
    {
        using var socket = Ready(); var calls = 0;
        await using var events = new SynologyPhotoPreviewEvents(_ => { calls++; return Task.FromResult<WebSocket>(socket); });
        await events.SubscribeAsync(7, CancellationToken.None); socket.Queue(packet);
        Assert.Equal((PhotoPreviewEventFailure)expected, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.CompletionAsync())).Failure);
        Assert.Equal(1, calls); Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task DisconnectOnlyReregistersOriginalUnitAndBackoffStopsAfterThreeAttempts()
    {
        var sockets = new List<FakeSocket>(); var delays = new List<TimeSpan>();
        await using var events = new SynologyPhotoPreviewEvents(_ =>
        {
            var socket = Ready(); socket.Queue("1"); sockets.Add(socket); return Task.FromResult<WebSocket>(socket);
        }, delay: (delay, _) => { delays.Add(delay); return Task.CompletedTask; });
        await events.SubscribeAsync(7, CancellationToken.None);
        Assert.Equal(PhotoPreviewEventFailure.Disconnected, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.CompletionAsync())).Failure);
        Assert.Equal(4, sockets.Count); Assert.Equal(new[] { 1d, 2d, 3d }, delays.Select(item => item.TotalSeconds));
        Assert.All(sockets, socket => { Assert.Equal(new[] { "40", PhotoPreviewPacket.Registration(7) }, socket.Sent); Assert.True(socket.Aborted); });
    }

    [Fact]
    public async Task ReconnectionCanFinishAndTransientRegistrationDisconnectUsesTheSameBudget()
    {
        var calls = 0; var sockets = new List<FakeSocket>();
        await using var events = new SynologyPhotoPreviewEvents(_ =>
        {
            var socket = ++calls == 2 ? new FakeSocket() : Ready(); sockets.Add(socket);
            socket.Queue(calls < 3 ? "1" : Completion(7, true)); return Task.FromResult<WebSocket>(socket);
        }, delay: (_, _) => Task.CompletedTask);
        await events.SubscribeAsync(7, CancellationToken.None);
        Assert.True(await events.CompletionAsync()); Assert.Equal(3, calls); Assert.All(sockets, socket => Assert.True(socket.Aborted));
    }

    [Fact]
    public async Task TotalTimeoutIsNotRestartedByReconnect()
    {
        using var socket = Ready(); socket.Queue("1"); var calls = 0;
        await using var events = new SynologyPhotoPreviewEvents(_ => { calls++; return Task.FromResult<WebSocket>(socket); },
            TimeSpan.FromMilliseconds(80), (delay, token) => Task.Delay(TimeSpan.FromSeconds(2), token));
        await events.SubscribeAsync(7, CancellationToken.None);
        Assert.Equal(PhotoPreviewEventFailure.TimedOut, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.CompletionAsync())).Failure);
        Assert.Equal(1, calls); Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task HandshakeTimeoutClosesAndDoesNotRegister()
    {
        using var socket = new FakeSocket();
        await using var events = new SynologyPhotoPreviewEvents(_ => Task.FromResult<WebSocket>(socket), TimeSpan.FromMilliseconds(60));
        Assert.Equal(PhotoPreviewEventFailure.TimedOut, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.SubscribeAsync(7, CancellationToken.None))).Failure);
        Assert.Empty(socket.Sent); Assert.True(socket.Aborted);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CancellationOrExplicitCloseStopsWaitingWithoutReconnect(bool close)
    {
        using var socket = Ready(); var calls = 0; using var cancellation = new CancellationTokenSource();
        await using var events = new SynologyPhotoPreviewEvents(_ => { calls++; return Task.FromResult<WebSocket>(socket); });
        await events.SubscribeAsync(7, cancellation.Token); var wait = events.CompletionAsync(cancellation.Token);
        if (close) await events.DisposeAsync(); else cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => wait);
        Assert.Equal(1, calls); Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task DuplicateSubscribeOrWaitCannotCreateAnotherConnection()
    {
        using var socket = Ready(); await using var events = Events(socket);
        await events.SubscribeAsync(7, CancellationToken.None);
        Assert.Equal(PhotoPreviewEventFailure.InvalidState, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.SubscribeAsync(8, CancellationToken.None))).Failure);
        socket.Queue(Completion(7, true)); Assert.True(await events.CompletionAsync());
        Assert.Equal(PhotoPreviewEventFailure.InvalidState, (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => events.CompletionAsync())).Failure);
    }

    [Fact]
    public async Task FragmentedUtf8WorksButBinaryOversizedAndInvalidUtf8DoNot()
    {
        using var socket = new FakeSocket(); var bytes = Encoding.UTF8.GetBytes("42[\"合成\"]");
        socket.Queue(bytes[..5], false); socket.Queue(bytes[5..], true);
        Assert.Equal("42[\"合成\"]", await SynologyPhotoPreviewEvents.ReceiveAsync(socket, CancellationToken.None));
        foreach (var (data, type) in new[] { (new byte[] { 0xff }, WebSocketMessageType.Text),
                     (Encoding.UTF8.GetBytes(Completion(7, true)), WebSocketMessageType.Binary),
                     (new byte[SynologyPhotoPreviewEvents.MaximumFrameBytes + 1], WebSocketMessageType.Text) })
        {
            using var rejected = new FakeSocket(); rejected.Queue(data, true, type);
            Assert.Equal(PhotoPreviewEventFailure.InvalidFrame,
                (await Assert.ThrowsAsync<PhotoPreviewEventException>(() => SynologyPhotoPreviewEvents.ReceiveAsync(rejected, CancellationToken.None))).Failure);
        }
    }

    [Theory]
    [InlineData("http://nas.invalid")]
    [InlineData("https://user:password@nas.invalid")]
    [InlineData("https://nas.invalid/?other=value")]
    [InlineData("https://nas.invalid/#fragment")]
    public void UnsafeOriginsNeverReachTransport(string endpoint) =>
        Assert.Throws<ArgumentException>(() => DsmApiClient.PhotoPreviewSocketUri(new Uri(endpoint), "synthetic"));

    [Theory]
    [InlineData(401)]
    [InlineData(302)]
    public async Task NativeHandshakeKeepsOriginCertificateContextAndEscapedTokenButHidesItFromErrors(int status)
    {
        HttpRequestMessage? captured = null; var calls = 0;
        using var http = new HttpClient(new Handler(request =>
        {
            captured = request; calls++; var response = new HttpResponseMessage((HttpStatusCode)status);
            response.Headers.Location = new Uri("https://elsewhere.invalid/"); return response;
        }));
        var api = new DsmApiClient(http); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "https://nas.invalid/proxy", 5001, "synthetic");
        var session = new DsmSession(profile.Id, "synthetic-sid", "synthetic&+token", null);
        var error = await Assert.ThrowsAsync<PhotoPreviewEventException>(() => api.ConnectPhotoPreviewSocketAsync(profile, session, api.GetBaseUri(profile), CancellationToken.None));
        Assert.Equal(PhotoPreviewEventFailure.ConnectionRejected, error.Failure); Assert.Equal(1, calls);
        Assert.NotNull(captured); Assert.Equal("/proxy/FotoSocketIo/socket.io/", captured.RequestUri!.AbsolutePath);
        Assert.Equal("?EIO=4&transport=websocket&SynoToken=synthetic%26%2Btoken", captured.RequestUri.Query);
        Assert.Equal("id=synthetic-sid", Assert.Single(captured.Headers.GetValues("Cookie")));
        Assert.Equal("https://nas.invalid:5001", Assert.Single(captured.Headers.GetValues("Origin")));
        Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(captured, out var owner, out _)); Assert.Equal(profile.Id, owner);
        Assert.DoesNotContain("synthetic", error.ToString()); Assert.DoesNotContain("nas.invalid", error.ToString()); Assert.Null(error.InnerException);
        using var usable = await http.GetAsync("https://nas.invalid/"); Assert.Equal(2, calls);
    }

    [Fact]
    public async Task ForeignOwnerOriginAndInjectedHeadersAreRejectedBeforeConnecting()
    {
        using var http = new HttpClient(new Handler(_ => throw new InvalidOperationException())); var api = new DsmApiClient(http);
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        foreach (var session in new[] { new DsmSession(Guid.NewGuid(), "synthetic", null, null), new DsmSession(profile.Id, "bad;cookie", null, null),
                     new DsmSession(profile.Id, "synthetic", "bad\r\nheader", null) })
            await Assert.ThrowsAsync<ArgumentException>(() => api.ConnectPhotoPreviewSocketAsync(profile, session, api.GetBaseUri(profile), CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() => api.ConnectPhotoPreviewSocketAsync(profile, new(profile.Id, "synthetic", null, null), new Uri("https://elsewhere.invalid/"), CancellationToken.None));
    }

    [Theory]
    [InlineData(HttpRequestError.ConnectionError, true)]
    [InlineData(HttpRequestError.NameResolutionError, true)]
    [InlineData(HttpRequestError.SecureConnectionError, false)]
    [InlineData(HttpRequestError.UserAuthenticationError, false)]
    public async Task NativeConnectionFailuresDistinguishTransientNetworkFromTrustAndAuthentication(HttpRequestError failure, bool retryable)
    {
        using var http = new HttpClient(new Handler(_ => throw new HttpRequestException(failure, "https://nas.invalid/?SynoToken=synthetic-token")));
        var api = new DsmApiClient(http); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        var error = await Assert.ThrowsAsync<PhotoPreviewEventException>(() => api.ConnectPhotoPreviewSocketAsync(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), api.GetBaseUri(profile), CancellationToken.None));
        Assert.Equal(retryable ? PhotoPreviewEventFailure.Disconnected : PhotoPreviewEventFailure.ConnectionRejected, error.Failure);
        Assert.Null(error.InnerException); Assert.DoesNotContain("synthetic", error.ToString()); Assert.DoesNotContain("nas.invalid", error.ToString());
    }

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response(request)); }
    private sealed class FakeSocket : WebSocket
    {
        private readonly Channel<(byte[] Bytes, bool End, WebSocketMessageType Type)> _incoming = Channel.CreateUnbounded<(byte[], bool, WebSocketMessageType)>();
        private (byte[] Bytes, bool End, WebSocketMessageType Type)? _current; private int _offset;
        public List<string> Sent { get; } = []; public bool Aborted { get; private set; }
        public void Queue(string value) => Queue(Encoding.UTF8.GetBytes(value), true);
        public void Queue(byte[] bytes, bool end, WebSocketMessageType type = WebSocketMessageType.Text) => _incoming.Writer.TryWrite((bytes, end, type));
        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override WebSocketState State => Aborted ? WebSocketState.Aborted : WebSocketState.Open;
        public override string? SubProtocol => null;
        public override void Abort() { Aborted = true; }
        public override void Dispose() => Abort();
        public override Task CloseAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) { Abort(); return Task.CompletedTask; }
        public override Task CloseOutputAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) { Abort(); return Task.CompletedTask; }
        public override Task SendAsync(ArraySegment<byte> buffer, WebSocketMessageType messageType, bool endOfMessage, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Sent.Add(Encoding.UTF8.GetString(buffer)); return Task.CompletedTask; }
        public override async Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken cancellationToken)
        {
            if (_current is null) { _current = await _incoming.Reader.ReadAsync(cancellationToken); _offset = 0; }
            var current = _current.Value; var length = Math.Min(buffer.Count, current.Bytes.Length - _offset);
            current.Bytes.AsSpan(_offset, length).CopyTo(buffer.AsSpan()); _offset += length;
            var finished = _offset == current.Bytes.Length; if (finished) _current = null;
            return new(length, current.Type, finished && current.End);
        }
    }
}
