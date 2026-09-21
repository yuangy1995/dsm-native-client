using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

// 仅接受固定 VM 的二进制消息及同源语言文件；不是通用网络代理或原生操作入口。
internal sealed class VirtualMachineConsoleBridge(VirtualMachineConsoleSession session, Func<string, Task> post, Action<Exception>? localeFailure = null) : IDisposable
{
    internal const int MaximumMessageBytes = 1024 * 1024;
    private readonly object _sync = new();
    private readonly string _context = Guid.NewGuid().ToString("N");
    private Peer? _peer;
    private int _lastId;
    private bool _disposed;
    private readonly CancellationTokenSource _localeLifetime = new();
    private int _localeReads, _lastLocaleId;
    internal string Script => VirtualMachineConsoleBridgeScript.Create(session.Policy.SocketUri ?? throw new InvalidOperationException(), _context);

    internal async Task AcceptAsync(Uri source, string message)
    {
        if (!session.UsesManagedTransport || !session.Policy.AllowsNavigation(source) || message.Length > MaximumMessageBytes * 2) return;
        int id; string kind; string? encoded = null;
        try
        {
            using var document = JsonDocument.Parse(message, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("context", out var context) || context.GetString() != _context ||
                !root.TryGetProperty("id", out var number) || !number.TryGetInt32(out id) || id <= 0 ||
                !root.TryGetProperty("kind", out var type) || type.ValueKind != JsonValueKind.String) return;
            kind = type.GetString()!;
            var keys = root.EnumerateObject().Select(item => item.Name).ToArray();
            if (keys.Distinct(StringComparer.Ordinal).Count() != keys.Length ||
                keys.Any(key => key is not ("context" or "id" or "kind" or "data"))) return;
            if (kind is "send" or "locale")
            {
                if (keys.Length != 4 || root.GetProperty("data").ValueKind != JsonValueKind.String) return;
                encoded = root.GetProperty("data").GetString();
            }
            else if (keys.Length != 3 || kind is not ("open" or "close")) return;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException) { return; }
        if (kind == "locale") { await LoadLocaleAsync(id, encoded!).ConfigureAwait(false); return; }
        if (kind == "open") { await OpenAsync(id).ConfigureAwait(false); return; }
        Peer? peer; lock (_sync) { peer = !_disposed && _peer?.Id == id ? _peer : null; }
        if (peer is null) return;
        if (kind == "close") { await FinishAsync(peer, false).ConfigureAwait(false); return; }
        byte[] data;
        try { data = Convert.FromBase64String(encoded ?? ""); }
        catch (FormatException) { await FinishAsync(peer, true).ConfigureAwait(false); return; }
        try
        {
            var allowed = false;
            lock (_sync)
            {
                if (!_disposed && !peer.Closed && peer.Socket?.State == WebSocketState.Open && data.Length <= MaximumMessageBytes &&
                    peer.PendingBytes + data.Length <= MaximumMessageBytes * 4 && peer.PendingMessages < 256)
                { peer.PendingBytes += data.Length; peer.PendingMessages++; allowed = true; }
            }
            if (!allowed) { await FinishAsync(peer, true).ConfigureAwait(false); return; }
            try
            {
                await peer.SendGate.WaitAsync(peer.Token).ConfigureAwait(false);
                try { await peer.Socket!.SendAsync(data.AsMemory(), WebSocketMessageType.Binary, true, peer.Token).ConfigureAwait(false); }
                finally { peer.SendGate.Release(); }
                await EmitAsync(peer, "sent", bytes: data.Length).ConfigureAwait(false);
            }
            catch { await FinishAsync(peer, true).ConfigureAwait(false); }
            finally { lock (_sync) { peer.PendingBytes -= data.Length; peer.PendingMessages--; } }
        }
        finally { Array.Clear(data); }
    }

    private async Task LoadLocaleAsync(int id, string address)
    {
        CancellationToken token;
        lock (_sync)
        {
            if (_disposed || id <= _lastLocaleId) return;
            _lastLocaleId = id;
            if (_localeReads >= 4) { _ = PostAsync(new { context = _context, id, kind = "locale", status = 429, body = "" }); return; }
            _localeReads++; token = _localeLifetime.Token;
        }
        var status = 403; var body = ""; Exception? failure = null;
        try
        {
            if (Uri.TryCreate(address, UriKind.Absolute, out var uri) && session.Policy.ManagedAssetMediaType(uri) == "application/json")
            {
                using var document = await session.LoadAssetAsync(uri, token).ConfigureAwait(false);
                if (document.Content.Length > VirtualMachineConsolePolicy.MaximumLocaleBytes) { status = 413; failure = new InvalidDataException("vm.console.locale_too_large"); }
                else { body = Encoding.UTF8.GetString(document.Content); status = 200; }
            }
        }
        catch (Exception error) { status = 502; failure = error; }
        Task posted;
        lock (_sync)
        {
            _localeReads--;
            posted = _disposed ? Task.CompletedTask : PostAsync(new { context = _context, id, kind = "locale", status, body });
        }
        await posted.ConfigureAwait(false);
        lock (_sync) if (!_disposed && failure is not null) localeFailure?.Invoke(failure);
    }
    private async Task OpenAsync(int id)
    {
        Peer peer;
        Task? rejected = null;
        lock (_sync)
        {
            if (_disposed || id <= _lastId) return;
            if (_peer is not null)
            {
                _lastId = id;
                rejected = PostAsync(new { context = _context, id, kind = "close", failed = true });
            }
            if (rejected is not null) { peer = null!; }
            else { _lastId = id; _peer = peer = new(id); }
        }
        if (rejected is not null) { await rejected.ConfigureAwait(false); return; }
        try
        {
            var socket = await session.ConnectManagedSocketAsync(peer.Token).ConfigureAwait(false);
            lock (_sync)
            {
                if (_disposed || peer.Closed || !ReferenceEquals(_peer, peer)) { socket.Dispose(); return; }
                peer.Socket = socket;
            }
            await EmitAsync(peer, "open").ConfigureAwait(false);
            _ = ReceiveAsync(peer);
        }
        catch { await FinishAsync(peer, true).ConfigureAwait(false); }
    }

    private async Task ReceiveAsync(Peer peer)
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (!peer.Token.IsCancellationRequested)
            {
                var received = await peer.Socket!.ReceiveAsync(buffer.AsMemory(), peer.Token).ConfigureAwait(false);
                if (received.MessageType == WebSocketMessageType.Close) { await FinishAsync(peer, false).ConfigureAwait(false); return; }
                if (received.MessageType != WebSocketMessageType.Binary) { await FinishAsync(peer, true).ConfigureAwait(false); return; }
                // noVNC 消费 RFB 字节流；逐块交付，不能按画面/消息累计大小拒绝高分辨率更新。
                await EmitAsync(peer, "data", Convert.ToBase64String(buffer, 0, received.Count)).ConfigureAwait(false);
            }
        }
        catch { await FinishAsync(peer, true).ConfigureAwait(false); }
        finally { Array.Clear(buffer); }
    }

    private Task EmitAsync(Peer peer, string kind, string? data = null, int? bytes = null)
    {
        lock (_sync)
        {
            if (_disposed || peer.Closed || !ReferenceEquals(_peer, peer)) return Task.CompletedTask;
            return PostAsync(new { context = _context, id = peer.Id, kind, data, bytes });
        }
    }
    private async Task PostAsync(object message)
    {
        try { await post(JsonSerializer.Serialize(message)).ConfigureAwait(false); }
        catch { Dispose(); } // 窗口已无法接收时终止连接，避免后台继续收发。
    }
    private Task FinishAsync(Peer peer, bool failed)
    {
        lock (_sync)
        {
            if (peer.Closed) return Task.CompletedTask;
            peer.Closed = true; if (ReferenceEquals(_peer, peer)) _peer = null;
            peer.Cancellation.Cancel(); peer.Socket?.Abort(); peer.Socket?.Dispose(); peer.Cancellation.Dispose();
            return !_disposed ? PostAsync(new { context = _context, id = peer.Id, kind = "close", failed }) : Task.CompletedTask;
        }
    }
    public void Dispose()
    {
        Peer? peer; lock (_sync) { if (_disposed) return; _disposed = true; peer = _peer; }
        _localeLifetime.Cancel(); _localeLifetime.Dispose();
        if (peer is not null) _ = FinishAsync(peer, false);
    }
    private sealed class Peer
    {
        public int Id { get; }
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken Token { get; }
        public SemaphoreSlim SendGate { get; } = new(1, 1);
        public WebSocket? Socket;
        public bool Closed;
        public int PendingBytes;
        public int PendingMessages;
        public Peer(int id) { Id = id; Token = Cancellation.Token; }
    }
}
