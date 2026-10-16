using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

internal enum PhotoPreviewEventFailure { InvalidState, InvalidFrame, Disconnected, ConnectionRejected, TimedOut }
internal sealed class PhotoPreviewEventException(PhotoPreviewEventFailure failure) : Exception("photos.preview.events." + failure)
{
    public PhotoPreviewEventFailure Failure { get; } = failure;
}
internal enum PhotoPreviewPacketKind { Opened, Connected, Ping, Completed, Ignored }
internal readonly record struct PhotoPreviewPacket(PhotoPreviewPacketKind Kind, long UnitId = 0, bool Success = false)
{
    internal static PhotoPreviewPacket Decode(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > SynologyPhotoPreviewEvents.MaximumFrameBytes) throw Invalid();
        if (text == "2") return new(PhotoPreviewPacketKind.Ping);
        if (text.StartsWith("44", StringComparison.Ordinal)) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.ConnectionRejected);
        if (text == "1" || text.StartsWith("41", StringComparison.Ordinal)) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.Disconnected);
        try
        {
            if (text.StartsWith('0'))
            {
                using var json = JsonDocument.Parse(text.AsMemory(1)); var root = json.RootElement;
                if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("sid", out var sid) || sid.ValueKind != JsonValueKind.String ||
                    string.IsNullOrEmpty(sid.GetString()) || !root.TryGetProperty("pingInterval", out var interval) ||
                    !interval.TryGetInt32(out var milliseconds) || milliseconds <= 0 ||
                    !root.TryGetProperty("pingTimeout", out var timeout) || !timeout.TryGetInt32(out milliseconds) || milliseconds <= 0) throw Invalid();
                return new(PhotoPreviewPacketKind.Opened);
            }
            if (text.StartsWith("40", StringComparison.Ordinal))
            {
                if (text != "40")
                {
                    using var json = JsonDocument.Parse(text.AsMemory(2)); var root = json.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("sid", out var sid) || sid.ValueKind != JsonValueKind.String ||
                        string.IsNullOrEmpty(sid.GetString())) throw Invalid();
                }
                return new(PhotoPreviewPacketKind.Connected);
            }
            if (!text.StartsWith("42", StringComparison.Ordinal)) return new(PhotoPreviewPacketKind.Ignored);
            using var payload = JsonDocument.Parse(text.AsMemory(2)); var array = payload.RootElement;
            if (array.ValueKind != JsonValueKind.Array || array.GetArrayLength() == 0 || array[0].ValueKind != JsonValueKind.String) throw Invalid();
            if (array[0].GetString() != "regenerate-preview") return new(PhotoPreviewPacketKind.Ignored);
            if (array.GetArrayLength() != 2 || array[1].ValueKind != JsonValueKind.Object || !array[1].TryGetProperty("data", out var data) ||
                data.ValueKind != JsonValueKind.Object || !data.TryGetProperty("idUnit", out var id) || !id.TryGetInt64(out var unitId) || unitId <= 0 ||
                !data.TryGetProperty("success", out var success) || success.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw Invalid();
            return new(PhotoPreviewPacketKind.Completed, unitId, success.GetBoolean());
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or FormatException) { throw Invalid(); }
    }
    internal static string Registration(long unitId) => unitId > 0
        ? "42" + JsonSerializer.Serialize(new object[] { "regenerate-preview", new { idUnit = unitId, operation = "register" } })
        : throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidState);
    private static PhotoPreviewEventException Invalid() => new(PhotoPreviewEventFailure.InvalidFrame);
}

/// <summary>内部 EIO4 通知。重连仅注册原单元，绝不标记、重建或上传。</summary>
internal sealed class SynologyPhotoPreviewEvents(Func<CancellationToken, Task<WebSocket>> connect,
    TimeSpan? timeout = null, Func<TimeSpan, CancellationToken, Task>? delay = null) : ISynologyPhotoPreviewCompletion
{
    internal const int MaximumFrameBytes = 1_048_576;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly CancellationTokenSource _closed = new();
    private readonly TimeSpan _timeout = timeout ?? TimeSpan.FromSeconds(600);
    private readonly Func<TimeSpan, CancellationToken, Task> _delay = delay ?? Task.Delay;
    private WebSocket? _socket;
    private long _unitId;
    private int _phase; // 0 未启动；1 建连；2 已订阅；3 等待；4 关闭。

    internal async Task SubscribeAsync(long unitId, CancellationToken token)
    {
        if (unitId <= 0 || Interlocked.CompareExchange(ref _phase, 1, 0) != 0) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidState);
        _unitId = unitId;
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, _closed.Token);
        try
        {
            await RegisterAsync(lifetime.Token).ConfigureAwait(false);
            lifetime.Token.ThrowIfCancellationRequested();
            if (Interlocked.CompareExchange(ref _phase, 2, 1) != 1) throw new OperationCanceledException(lifetime.Token);
        }
        catch { await DisposeAsync().ConfigureAwait(false); throw; }
    }

    public async Task<bool> CompletionAsync(CancellationToken cancellationToken = default)
    {
        if (Interlocked.CompareExchange(ref _phase, 3, 2) != 2) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidState);
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closed.Token);
        lifetime.CancelAfter(_timeout); var token = lifetime.Token; var retries = 0; var needsRegistration = false;
        try
        {
            while (true)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    if (needsRegistration) { await RegisterAsync(token).ConfigureAwait(false); needsRegistration = false; }
                    using var abort = token.Register(() => _socket?.Abort());
                    while (true)
                    {
                        var packet = PhotoPreviewPacket.Decode(await ReceiveAsync(_socket!, token).ConfigureAwait(false));
                        token.ThrowIfCancellationRequested();
                        if (packet.Kind == PhotoPreviewPacketKind.Completed && packet.UnitId == _unitId) return packet.Success;
                        if (packet.Kind == PhotoPreviewPacketKind.Ping) await SendAsync(_socket!, "3", token).ConfigureAwait(false);
                        if (packet.Kind is PhotoPreviewPacketKind.Opened or PhotoPreviewPacketKind.Connected)
                            throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame);
                    }
                }
                catch (PhotoPreviewEventException error) when (error.Failure == PhotoPreviewEventFailure.Disconnected && retries < 3)
                {
                    token.ThrowIfCancellationRequested(); CloseSocket();
                    await _delay(TimeSpan.FromSeconds(++retries), token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested(); needsRegistration = true;
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && !_closed.IsCancellationRequested)
        { throw new PhotoPreviewEventException(PhotoPreviewEventFailure.TimedOut); }
        finally { await DisposeAsync().ConfigureAwait(false); }
    }

    private async Task RegisterAsync(CancellationToken token)
    {
        using var handshake = CancellationTokenSource.CreateLinkedTokenSource(token);
        handshake.CancelAfter(TimeSpan.FromSeconds(Math.Min(20, _timeout.TotalSeconds)));
        var bounded = handshake.Token;
        try
        {
            _socket = await connect(bounded).ConfigureAwait(false);
            using var abort = bounded.Register(() => _socket?.Abort()); var opened = false;
            while (true)
            {
                var packet = PhotoPreviewPacket.Decode(await ReceiveAsync(_socket, bounded).ConfigureAwait(false));
                bounded.ThrowIfCancellationRequested();
                switch (packet.Kind)
                {
                    case PhotoPreviewPacketKind.Opened:
                        if (opened) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame);
                        opened = true; await SendAsync(_socket, "40", bounded).ConfigureAwait(false); break;
                    case PhotoPreviewPacketKind.Connected:
                        if (!opened) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame);
                        await SendAsync(_socket, PhotoPreviewPacket.Registration(_unitId), bounded).ConfigureAwait(false); return;
                    case PhotoPreviewPacketKind.Ping: await SendAsync(_socket, "3", bounded).ConfigureAwait(false); break;
                    case PhotoPreviewPacketKind.Completed: throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame);
                }
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new PhotoPreviewEventException(PhotoPreviewEventFailure.TimedOut); }
    }

    private static async Task SendAsync(WebSocket socket, string text, CancellationToken token)
    {
        try { await socket.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)), WebSocketMessageType.Text, true, token).ConfigureAwait(false); }
        catch (Exception error) when (error is WebSocketException or IOException or ObjectDisposedException)
        { token.ThrowIfCancellationRequested(); throw new PhotoPreviewEventException(PhotoPreviewEventFailure.Disconnected); }
    }
    internal static async Task<string> ReceiveAsync(WebSocket socket, CancellationToken token)
    {
        var buffer = new byte[8192]; using var output = new MemoryStream();
        try
        {
            while (true)
            {
                var result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close) throw new PhotoPreviewEventException(PhotoPreviewEventFailure.Disconnected);
                if (result.MessageType != WebSocketMessageType.Text || output.Length + result.Count > MaximumFrameBytes)
                    throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame);
                output.Write(buffer, 0, result.Count);
                if (result.EndOfMessage) return StrictUtf8.GetString(output.GetBuffer(), 0, checked((int)output.Length));
            }
        }
        catch (DecoderFallbackException) { throw new PhotoPreviewEventException(PhotoPreviewEventFailure.InvalidFrame); }
        catch (Exception error) when (error is WebSocketException or IOException or ObjectDisposedException)
        { token.ThrowIfCancellationRequested(); throw new PhotoPreviewEventException(PhotoPreviewEventFailure.Disconnected); }
    }
    private void CloseSocket() { var socket = Interlocked.Exchange(ref _socket, null); socket?.Abort(); socket?.Dispose(); }
    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _phase, 4) != 4) _closed.Cancel();
        CloseSocket(); return ValueTask.CompletedTask;
    }
}
