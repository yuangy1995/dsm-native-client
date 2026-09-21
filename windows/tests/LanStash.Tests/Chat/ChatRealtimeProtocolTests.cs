using System.Net.WebSockets;
using System.Text;
using System.Threading.Channels;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatRealtimeProtocolTests
{
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(3);
    private static readonly ChatRealtimeTiming Timing = new(TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(5), TimeSpan.FromMilliseconds(10));
    private static DsmChatRealtimeClient Client() => new((_, _) => throw new NotSupportedException(), Timing);
    private static string Open(int interval = 1000, int timeout = 1000) => $"0{{\"sid\":\"synthetic\",\"pingInterval\":{interval},\"pingTimeout\":{timeout}}}";

    [Fact]
    public async Task EventsBeforeNamespaceAreIgnoredAndCompoundContentFramesAreCoalesced()
    {
        using var socket = new FakeSocket(); using var cancellation = new CancellationTokenSource();
        socket.Queue(Open()); socket.Queue("42[\"ignored\",{}]"); socket.Queue("40\u001e42[\"one\",{\"message\":\"synthetic\"}]\u001e42[\"two\",{}]"); socket.Queue("2");
        var events = new List<ChatRealtimeEvent>();
        var run = Client().RunConnectionAsync(socket, 4, events.Add, cancellation.Token);
        Assert.Equal("40", await socket.Sent.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        Assert.Equal("3", await socket.Sent.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
        Assert.Equal(new[] { ChatRealtimeEvent.Connected, ChatRealtimeEvent.ContentChanged }, events);
        Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task EngineThreeSendsPingAndWaitsForPong()
    {
        using var socket = new FakeSocket(); using var cancellation = new CancellationTokenSource();
        socket.Queue(Open(15, 500)); socket.Queue("40");
        var run = Client().RunConnectionAsync(socket, 3, _ => { }, cancellation.Token);
        Assert.Equal("40", await socket.Sent.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        Assert.Equal("2", await socket.Sent.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        socket.Queue("3");
        Assert.Equal("2", await socket.Sent.Reader.ReadAsync().AsTask().WaitAsync(TestTimeout));
        cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
    }

    [Theory]
    [InlineData(3)]
    [InlineData(4)]
    public async Task MissingHeartbeatTerminatesConnection(int version)
    {
        using var socket = new FakeSocket(); socket.Queue(Open(10, 10)); socket.Queue("40");
        await Assert.ThrowsAsync<TimeoutException>(() => Client().RunConnectionAsync(socket, version, _ => { }, CancellationToken.None).WaitAsync(TestTimeout));
        Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task StalledNamespaceHandshakeTimesOutAndAbortsReceive()
    {
        using var socket = new FakeSocket(); socket.Queue(Open());
        await Assert.ThrowsAsync<TimeoutException>(() => Client().RunConnectionAsync(socket, 4, _ => { }, CancellationToken.None).WaitAsync(TestTimeout));
        Assert.True(socket.Aborted);
    }

    [Fact]
    public async Task NamespaceBeforeEngineHandshakeIsRejected()
    {
        using var socket = new FakeSocket(); socket.Queue("40");
        await Assert.ThrowsAsync<InvalidDataException>(() => Client().RunConnectionAsync(socket, 4, _ => { }, CancellationToken.None));
        Assert.True(socket.Aborted);
    }

    [Theory]
    [InlineData("0{}")]
    [InlineData("0{\"sid\":\"\"}")]
    [InlineData("0{\"sid\":\"synthetic\",\"pingInterval\":0}")]
    [InlineData("0{\"sid\":\"synthetic\",\"pingTimeout\":300001}")]
    public void InvalidHandshakeCannotEstablishConnection(string packet) =>
        Assert.Throws<InvalidDataException>(() => DsmChatRealtimeClient.ReadHandshake(packet));

    [Fact]
    public async Task FragmentedUtf8IsDecodedOnlyAfterCompletionAndOversizedFramesAreRejected()
    {
        using var socket = new FakeSocket();
        var bytes = Encoding.UTF8.GetBytes("42[\"合成\"]");
        socket.Queue(bytes[..5], false); socket.Queue(bytes[5..], true);
        Assert.Equal("42[\"合成\"]", await DsmChatRealtimeClient.ReceiveFrameAsync(socket, CancellationToken.None));
        socket.Queue(new byte[DsmChatRealtimeClient.MaximumFrameBytes], false); socket.Queue([1], true);
        await Assert.ThrowsAsync<InvalidDataException>(() => DsmChatRealtimeClient.ReceiveFrameAsync(socket, CancellationToken.None));
    }

    [Fact]
    public async Task InvalidUtf8NeverBecomesAnEvent()
    {
        using var socket = new FakeSocket(); socket.Queue([0xff], true);
        await Assert.ThrowsAsync<DecoderFallbackException>(() => DsmChatRealtimeClient.ReceiveFrameAsync(socket, CancellationToken.None));
    }

    [Fact]
    public async Task ReconnectFallsBackThenPrefersTheSuccessfulEngineVersion()
    {
        using var cancellation = new CancellationTokenSource(); var versions = new List<int>(); var sockets = new List<FakeSocket>();
        var observedDisconnect = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var client = new DsmChatRealtimeClient(async (version, token) =>
        {
            versions.Add(version);
            if (versions.Count == 3)
            {
                // 先观察前次已发出的事件再取消，避免取消枚举本身丢弃缓冲造成测试竞态。
                await observedDisconnect.Task.WaitAsync(TestTimeout, token);
                cancellation.Cancel(); throw new OperationCanceledException(cancellation.Token);
            }
            var socket = new FakeSocket(); sockets.Add(socket);
            if (version == 4) socket.Queue("40");
            else { socket.Queue(Open()); socket.Queue("40"); socket.Queue("1"); }
            return socket;
        }, Timing);
        var events = new List<ChatRealtimeEvent>();
        try
        {
            await foreach (var value in client.ObserveAsync(cancellation.Token))
            { events.Add(value); if (value == ChatRealtimeEvent.Disconnected) observedDisconnect.TrySetResult(); }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        Assert.Equal(new[] { 4, 3, 3 }, versions);
        Assert.Contains(ChatRealtimeEvent.Connected, events); Assert.Contains(ChatRealtimeEvent.Disconnected, events);
        Assert.All(sockets, socket => Assert.True(socket.Aborted));
    }

    internal sealed class FakeSocket : WebSocket
    {
        private readonly Channel<(byte[] Bytes, bool End)> _incoming = Channel.CreateUnbounded<(byte[], bool)>();
        private (byte[] Bytes, bool End)? _current;
        private int _offset;
        public Channel<string> Sent { get; } = Channel.CreateUnbounded<string>();
        public bool Aborted { get; private set; }
        public void Queue(string value) => Queue(Encoding.UTF8.GetBytes(value), true);
        public void Queue(byte[] bytes, bool end) => _incoming.Writer.TryWrite((bytes, end));
        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override WebSocketState State => Aborted ? WebSocketState.Aborted : WebSocketState.Open;
        public override string? SubProtocol => null;
        public override void Abort() { Aborted = true; _incoming.Writer.TryComplete(); }
        public override void Dispose() => Abort();
        public override Task CloseAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) { Abort(); return Task.CompletedTask; }
        public override Task CloseOutputAsync(WebSocketCloseStatus closeStatus, string? statusDescription, CancellationToken cancellationToken) { Abort(); return Task.CompletedTask; }
        public override Task SendAsync(ArraySegment<byte> buffer, WebSocketMessageType messageType, bool endOfMessage, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); Sent.Writer.TryWrite(Encoding.ASCII.GetString(buffer)); return Task.CompletedTask; }
        public override async Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken cancellationToken)
        {
            if (_current is null) { _current = await _incoming.Reader.ReadAsync(cancellationToken); _offset = 0; }
            var current = _current.Value; var length = Math.Min(buffer.Count, current.Bytes.Length - _offset);
            current.Bytes.AsSpan(_offset, length).CopyTo(buffer.AsSpan()); _offset += length;
            var finished = _offset == current.Bytes.Length;
            if (finished) _current = null;
            return new(length, WebSocketMessageType.Text, finished && current.End);
        }
    }
}
