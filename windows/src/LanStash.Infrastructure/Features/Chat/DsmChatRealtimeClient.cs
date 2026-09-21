using System.Net.WebSockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using LanStash.Domain;

namespace LanStash.Infrastructure;

internal sealed record ChatRealtimeTiming(TimeSpan HandshakeTimeout, TimeSpan InitialRetry, TimeSpan MaximumRetry)
{
    public static ChatRealtimeTiming Default { get; } = new(TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(30));
}

/// <summary>已记录的内部只读 Socket.IO 通道；不解析、持久化或记录消息事件正文。</summary>
internal sealed class DsmChatRealtimeClient(Func<int, CancellationToken, Task<WebSocket>> connect, ChatRealtimeTiming? timing = null)
{
    internal const int MaximumFrameBytes = 1_048_576;
    private readonly ChatRealtimeTiming _timing = timing ?? ChatRealtimeTiming.Default;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public async IAsyncEnumerable<ChatRealtimeEvent> ObserveAsync([EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var events = Channel.CreateBounded<ChatRealtimeEvent>(new BoundedChannelOptions(8)
        { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.DropOldest });
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var run = RunAsync(events.Writer, lifetime.Token);
        try
        {
            await foreach (var item in events.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false)) yield return item;
        }
        finally { lifetime.Cancel(); await run.ConfigureAwait(false); }
    }

    private async Task RunAsync(ChannelWriter<ChatRealtimeEvent> events, CancellationToken token)
    {
        var preferredVersion = 4;
        var delay = _timing.InitialRetry;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var connected = false;
                foreach (var version in new[] { preferredVersion, preferredVersion == 4 ? 3 : 4 })
                {
                    if (token.IsCancellationRequested) break;
                    try
                    {
                        using var handshake = CancellationTokenSource.CreateLinkedTokenSource(token);
                        handshake.CancelAfter(_timing.HandshakeTimeout);
                        using var socket = await connect(version, handshake.Token).ConfigureAwait(false);
                        handshake.CancelAfter(Timeout.InfiniteTimeSpan);
                        using var abort = token.Register(socket.Abort);
                        await RunConnectionAsync(socket, version, value =>
                        {
                            if (value == ChatRealtimeEvent.Connected) { connected = true; preferredVersion = version; delay = _timing.InitialRetry; }
                            events.TryWrite(value);
                        }, token).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
                    catch { /* 连接/协议/信任失败只降级，不向日志或业务层暴露响应和秘密。 */ }
                    if (connected) break;
                }
                if (token.IsCancellationRequested) return;
                events.TryWrite(ChatRealtimeEvent.Disconnected);
                await Task.Delay(delay, token).ConfigureAwait(false);
                delay = TimeSpan.FromMilliseconds(Math.Min(delay.TotalMilliseconds * 2, _timing.MaximumRetry.TotalMilliseconds));
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally { events.TryComplete(); }
    }

    internal async Task RunConnectionAsync(WebSocket socket, int engineVersion, Action<ChatRealtimeEvent> emit, CancellationToken token)
    {
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(token);
        var opened = false;
        var ready = false;
        var waitingForPong = false;
        var pingInterval = TimeSpan.FromSeconds(25);
        var pingTimeout = TimeSpan.FromSeconds(20);
        var handshakeDeadline = DateTimeOffset.UtcNow + _timing.HandshakeTimeout;
        var heartbeatDeadline = handshakeDeadline;
        Task<string>? receive = null;
        try
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                receive ??= ReceiveFrameAsync(socket, connection.Token);
                var deadline = ready ? heartbeatDeadline : handshakeDeadline;
                var remaining = deadline - DateTimeOffset.UtcNow;
                if (remaining < TimeSpan.Zero) remaining = TimeSpan.Zero;
                using var timerCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
                var timer = Task.Delay(remaining, timerCancellation.Token);
                var winner = remaining <= TimeSpan.Zero ? timer : await Task.WhenAny(receive, timer).ConfigureAwait(false);
                if (winner == timer)
                {
                    token.ThrowIfCancellationRequested();
                    if (!ready || engineVersion != 3 || waitingForPong) throw new TimeoutException("chat.realtime.timeout");
                    await SendControlAsync(socket, "2", connection.Token).ConfigureAwait(false);
                    waitingForPong = true; heartbeatDeadline = DateTimeOffset.UtcNow + pingTimeout;
                    continue;
                }
                timerCancellation.Cancel();
                var frame = await receive.ConfigureAwait(false); receive = null;
                var changed = false;
                foreach (var packet in frame.Split('\x1e', StringSplitOptions.RemoveEmptyEntries))
                {
                    if (packet.StartsWith('0'))
                    {
                        if (opened) throw new InvalidDataException("chat.realtime.duplicate-open");
                        (pingInterval, pingTimeout) = ReadHandshake(packet);
                        opened = true;
                        heartbeatDeadline = DateTimeOffset.UtcNow + (engineVersion == 3 ? pingInterval : pingInterval + pingTimeout);
                        await SendControlAsync(socket, "40", connection.Token).ConfigureAwait(false);
                    }
                    else if (packet == "40" || packet.StartsWith("40{", StringComparison.Ordinal))
                    {
                        if (!opened) throw new InvalidDataException("chat.realtime.invalid-handshake");
                        if (!ready) { ready = true; emit(ChatRealtimeEvent.Connected); }
                    }
                    else if (packet == "2")
                    {
                        if (!opened) throw new InvalidDataException("chat.realtime.early-heartbeat");
                        await SendControlAsync(socket, "3", connection.Token).ConfigureAwait(false);
                        if (engineVersion == 4) heartbeatDeadline = DateTimeOffset.UtcNow + pingInterval + pingTimeout;
                    }
                    else if (packet == "3" && engineVersion == 3 && waitingForPong)
                    { waitingForPong = false; heartbeatDeadline = DateTimeOffset.UtcNow + pingInterval; }
                    else if (packet == "1" || packet.StartsWith("41", StringComparison.Ordinal) || packet.StartsWith("44", StringComparison.Ordinal))
                        throw new IOException("chat.realtime.disconnected");
                    else if (ready && packet.StartsWith("42", StringComparison.Ordinal)) changed = true;
                }
                if (changed) emit(ChatRealtimeEvent.ContentChanged);
            }
        }
        finally
        {
            connection.Cancel(); socket.Abort();
            if (receive is not null) { try { await receive.ConfigureAwait(false); } catch { } }
        }
    }

    private async Task SendControlAsync(WebSocket socket, string value, CancellationToken token)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(_timing.HandshakeTimeout);
        await socket.SendAsync(new ArraySegment<byte>(Encoding.ASCII.GetBytes(value)), WebSocketMessageType.Text, true, timeout.Token).ConfigureAwait(false);
    }

    internal static async Task<string> ReceiveFrameAsync(WebSocket socket, CancellationToken token)
    {
        var buffer = new byte[8192];
        using var output = new MemoryStream();
        WebSocketMessageType? type = null;
        while (true)
        {
            var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close) throw new IOException("chat.realtime.closed");
            if (type is not null && type != result.MessageType) throw new InvalidDataException("chat.realtime.mixed-frame");
            type = result.MessageType;
            if (output.Length + result.Count > MaximumFrameBytes) throw new InvalidDataException("chat.realtime.oversized-frame");
            output.Write(buffer, 0, result.Count);
            if (result.EndOfMessage) return StrictUtf8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
        }
    }

    internal static (TimeSpan Interval, TimeSpan Timeout) ReadHandshake(string packet)
    {
        using var json = JsonDocument.Parse(packet.AsMemory(1));
        var root = json.RootElement;
        if (!root.TryGetProperty("sid", out var sid) || sid.ValueKind != JsonValueKind.String || sid.GetString() is not { Length: > 0 and <= 512 })
            throw new InvalidDataException("chat.realtime.invalid-handshake");
        static TimeSpan Duration(JsonElement root, string key, int fallback)
        {
            var milliseconds = fallback;
            if (root.TryGetProperty(key, out var value) && !value.TryGetInt32(out milliseconds)) throw new InvalidDataException("chat.realtime.invalid-heartbeat");
            // 有界等待；不支持的心跳设置退回现有轮询，不永久占用连接。
            if (milliseconds is <= 0 or > 300_000) throw new InvalidDataException("chat.realtime.invalid-heartbeat");
            return TimeSpan.FromMilliseconds(milliseconds);
        }
        return (Duration(root, "pingInterval", 25_000), Duration(root, "pingTimeout", 20_000));
    }
}
