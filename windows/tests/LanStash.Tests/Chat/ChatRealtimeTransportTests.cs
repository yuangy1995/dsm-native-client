using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatRealtimeTransportTests
{
    [Fact]
    public async Task SuccessfulNativeHandshakeReadsFramesAndCancellationDisposesOnlySocketStream()
    {
        using var stream = new DuplexMemoryStream();
        stream.EnqueueText("0{\"sid\":\"synthetic\",\"pingInterval\":25000,\"pingTimeout\":20000}");
        stream.EnqueueText("40"); stream.EnqueueText("42[\"synthetic-update\",{}]");
        var calls = 0;
        using var http = new HttpClient(new Handler(request =>
        {
            calls++;
            if (!request.Headers.Contains("Sec-WebSocket-Key")) return new(HttpStatusCode.OK);
            var key = request.Headers.GetValues("Sec-WebSocket-Key").Single();
            var response = new HttpResponseMessage(HttpStatusCode.SwitchingProtocols) { Content = new DuplexContent(stream) };
            response.Headers.TryAddWithoutValidation("Connection", "Upgrade"); response.Headers.TryAddWithoutValidation("Upgrade", "websocket");
            response.Headers.TryAddWithoutValidation("Sec-WebSocket-Accept", Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))));
            return response;
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        var api = new DsmApiClient(http); var events = new List<ChatRealtimeEvent>();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await foreach (var value in api.ObserveChatRealtimeAsync(profile, new(profile.Id, "synthetic", null, null), timeout.Token))
        {
            events.Add(value);
            if (value == ChatRealtimeEvent.ContentChanged) break;
        }
        Assert.Equal(new[] { ChatRealtimeEvent.Connected, ChatRealtimeEvent.ContentChanged }, events);
        Assert.True(stream.Disposed); Assert.True(stream.WrittenBytes > 0); Assert.Equal(1, calls);
        using var stillUsable = await http.GetAsync("https://nas.invalid/");
        Assert.Equal(HttpStatusCode.OK, stillUsable.StatusCode);
    }

    [Theory]
    [InlineData(3)]
    [InlineData(4)]
    public async Task NativeHandshakeUsesExistingClientAndHeadersWithProfileContext(int version)
    {
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "https://nas.invalid/base", 5001, "synthetic");
        var session = new DsmSession(profile.Id, "synthetic-sid", "synthetic-token", null);
        var calls = 0;
        HttpRequestMessage? captured = null;
        using var http = new HttpClient(new Handler(request =>
        {
            calls++; captured = request;
            return new(HttpStatusCode.Unauthorized);
        }));
        var api = new DsmApiClient(http);
        var failure = await Record.ExceptionAsync(async () => { using var socket = await api.ConnectChatSocketAsync(profile, session, api.GetBaseUri(profile), version, CancellationToken.None); });
        Assert.NotNull(failure); Assert.True(calls == 1, failure.ToString());
        Assert.NotNull(captured);
        Assert.Equal(new Uri($"https://nas.invalid:5001/base/sc/socket.io/?EIO={version}&transport=websocket"), captured.RequestUri);
        Assert.Equal("id=synthetic-sid", Assert.Single(captured.Headers.GetValues("Cookie")));
        Assert.Equal("synthetic-token", Assert.Single(captured.Headers.GetValues("X-SYNO-TOKEN")));
        Assert.Equal("https://nas.invalid:5001", Assert.Single(captured.Headers.GetValues("Origin")));
        Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(captured, out var id, out _));
        Assert.Equal(profile.Id, id);
        Assert.DoesNotContain("synthetic", captured.RequestUri!.AbsoluteUri);
        // 握手包装器的释放不能释放共享 HttpClient。
        using var response = await http.GetAsync("https://nas.invalid:5001/base/sc/socket.io/?EIO=" + version + "&transport=websocket");
    }

    [Theory]
    [InlineData("http://nas.invalid")]
    [InlineData("https://user:password@nas.invalid")]
    [InlineData("https://nas.invalid/?untrusted=value")]
    [InlineData("https://nas.invalid/#fragment")]
    public void RejectsUnsafeEndpointsBeforeOpeningSocket(string address) =>
        Assert.Throws<ArgumentException>(() => DsmApiClient.ChatSocketUri(new Uri(address), 4));

    [Fact]
    public async Task ForeignSessionOrHeaderInjectionNeverReachesTransport()
    {
        using var http = new HttpClient(new Handler(_ => throw new InvalidOperationException("Transport must not be called.")));
        var api = new DsmApiClient(http);
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        foreach (var session in new[] { new DsmSession(Guid.NewGuid(), "synthetic", null, null),
                     new DsmSession(profile.Id, "invalid;cookie", null, null), new DsmSession(profile.Id, "synthetic", "invalid\r\nheader", null) })
            await Assert.ThrowsAsync<ArgumentException>(() => api.ConnectChatSocketAsync(profile, session, api.GetBaseUri(profile), 4, CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(() => api.ConnectChatSocketAsync(profile,
            new(profile.Id, "synthetic", null, null), new Uri("https://elsewhere.invalid"), 4, CancellationToken.None));
    }

    [Fact]
    public async Task RedirectDoesNotStartSecondAuthenticatedHandshake()
    {
        var calls = 0;
        using var http = new HttpClient(new Handler(_ =>
        {
            calls++; var response = new HttpResponseMessage(HttpStatusCode.Redirect);
            response.Headers.Location = new Uri("https://elsewhere.invalid/"); return response;
        }));
        var api = new DsmApiClient(http);
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        await Assert.ThrowsAnyAsync<Exception>(() => api.ConnectChatSocketAsync(profile, new(profile.Id, "synthetic", null, null), api.GetBaseUri(profile), 4, CancellationToken.None));
        Assert.Equal(1, calls);
    }

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(response(request));
    }

    private sealed class DuplexContent(Stream stream) : HttpContent
    {
        protected override Stream CreateContentReadStream(CancellationToken cancellationToken) => stream;
        protected override Task<Stream> CreateContentReadStreamAsync() => Task.FromResult(stream);
        protected override Task<Stream> CreateContentReadStreamAsync(CancellationToken cancellationToken) => Task.FromResult(stream);
        protected override Task SerializeToStreamAsync(Stream target, TransportContext? context) => throw new NotSupportedException();
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
        protected override void Dispose(bool disposing) { if (disposing) stream.Dispose(); base.Dispose(disposing); }
    }

    private sealed class DuplexMemoryStream : Stream
    {
        private readonly Channel<byte[]> _frames = Channel.CreateUnbounded<byte[]>();
        private byte[]? _current;
        private int _offset;
        public bool Disposed { get; private set; }
        public int WrittenBytes { get; private set; }
        public void EnqueueText(string text)
        {
            var payload = Encoding.UTF8.GetBytes(text); Assert.True(payload.Length < 126);
            _frames.Writer.TryWrite([0x81, (byte)payload.Length, .. payload]);
        }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) => ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_current is null)
            {
                if (!await _frames.Reader.WaitToReadAsync(cancellationToken)) return 0;
                _current = await _frames.Reader.ReadAsync(cancellationToken); _offset = 0;
            }
            var length = Math.Min(buffer.Length, _current.Length - _offset);
            _current.AsMemory(_offset, length).CopyTo(buffer); _offset += length;
            if (_offset == _current.Length) _current = null;
            return length;
        }
        public override void Write(byte[] buffer, int offset, int count) => WrittenBytes += count;
        public override Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) { WrittenBytes += count; return Task.CompletedTask; }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) { WrittenBytes += buffer.Length; return ValueTask.CompletedTask; }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) { Disposed = true; _frames.Writer.TryComplete(); base.Dispose(disposing); }
    }
}
