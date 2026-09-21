using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineConsoleBridgeTests
{
    [Fact]
    public async Task BinaryExchangePreservesByteOrderAndClosingReleasesSocket()
    {
        using var f = new Fixture();
        await f.Send("open"); Assert.Equal("open", (await f.Read())["kind"]!.GetValue<string>());
        await f.Send("send", data: Convert.ToBase64String([0, 128, 255]));
        Assert.Equal(new byte[] { 0, 128, 255 }, Assert.Single(f.Socket.Sent));
        Assert.Equal(3, (await f.Read())["bytes"]!.GetValue<int>());
        f.Socket.Queue([1, 2], end: false); f.Socket.Queue([3]);
        Assert.Equal("AQI=", (await f.Read())["data"]!.GetValue<string>());
        Assert.Equal("Aw==", (await f.Read())["data"]!.GetValue<string>());
        await f.Send("close"); Assert.False((await f.Read())["failed"]!.GetValue<bool>());
        Assert.True(f.Socket.Disposed);
        await f.Send("send", data: "AQ=="); Assert.Single(f.Socket.Sent); Assert.False(f.Messages.Reader.TryRead(out _));
    }

    [Theory]
    [InlineData("foreign-origin")][InlineData("different-document")][InlineData("wrong-context")]
    [InlineData("extra-url")][InlineData("duplicate-key")][InlineData("bad-id")]
    [InlineData("numeric-context")][InlineData("malformed")]
    public async Task UntrustedMessagesNeverConnect(string variant)
    {
        using var f = new Fixture(); var source = f.Policy.NavigationUri;
        var message = f.Message("open");
        switch (variant)
        {
            case "foreign-origin": source = new("https://other.invalid/"); break;
            case "different-document": source = new("https://nas.invalid/webman/index.cgi"); break;
            case "wrong-context": message["context"] = "foreign"; break;
            case "extra-url": message["url"] = "https://other.invalid/"; break;
            case "bad-id": message["id"] = -1; break;
            case "numeric-context": message["context"] = 2; break;
        }
        var json = variant == "malformed" ? "{" : message.ToJsonString();
        if (variant == "duplicate-key") json = json[..^1] + ",\"id\":2}";
        await f.Bridge.AcceptAsync(source, json);
        Assert.Equal(0, f.Connects); Assert.False(f.Messages.Reader.TryRead(out _));
    }

    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task ClosingDuringConnectCancelsAndDisposesLateSocket(bool dispose)
    {
        var pending = new TaskCompletionSource<WebSocket>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var f = new Fixture(pending.Task); var opening = f.Send("open");
        Assert.True(f.ConnectToken.CanBeCanceled);
        if (dispose) f.Bridge.Dispose(); else await f.Send("close");
        Assert.True(f.ConnectToken.IsCancellationRequested);
        pending.SetResult(f.Socket); await opening.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(f.Socket.Disposed);
        if (!dispose) Assert.Equal("close", (await f.Read())["kind"]!.GetValue<string>());
        Assert.False(f.Messages.Reader.TryRead(out _));
    }

    [Fact]
    public async Task SecondConnectionIsRejectedWithoutReplacingFirstAndStaleIdsCannotReopen()
    {
        using var f = new Fixture(); await f.Send("open"); await f.Read();
        await f.Send("open", id: 2); var rejected = await f.Read();
        Assert.Equal(2, rejected["id"]!.GetValue<int>()); Assert.True(rejected["failed"]!.GetValue<bool>());
        Assert.Equal(1, f.Connects); Assert.False(f.Socket.Disposed);
        await f.Send("close"); await f.Read(); await f.Send("open"); await f.Send("open", id: 2);
        Assert.Equal(1, f.Connects); Assert.False(f.Messages.Reader.TryRead(out _));
    }

    [Theory]
    [InlineData("invalid-base64")][InlineData("oversize")][InlineData("text-receive")]
    public async Task InvalidPayloadClosesWithoutForwarding(string kind)
    {
        using var f = new Fixture(); await f.Send("open"); await f.Read();
        if (kind == "text-receive") f.Socket.Queue([1], type: WebSocketMessageType.Text);
        else await f.Send("send", data: kind == "oversize" ? Convert.ToBase64String(new byte[VirtualMachineConsoleBridge.MaximumMessageBytes + 1]) : "!invalid");
        var result = await f.Read(); Assert.Equal("close", result["kind"]!.GetValue<string>()); Assert.True(result["failed"]!.GetValue<bool>());
        Assert.Empty(f.Socket.Sent); Assert.True(f.Socket.Disposed);
    }
    [Fact]
    public async Task LargeDisplayUpdateIsStreamedWithoutAccumulatingWholeMessage()
    {
        using var f = new Fixture(); await f.Send("open"); await f.Read();
        for (var i = 0; i < 32; i++)
        {
            var bytes = Enumerable.Repeat((byte)i, 65536).ToArray(); f.Socket.Queue(bytes, end: i == 31);
            var chunk = await f.Read(); Assert.Equal("data", chunk["kind"]!.GetValue<string>());
            Assert.Equal(bytes, Convert.FromBase64String(chunk["data"]!.GetValue<string>()));
        }
        Assert.False(f.Socket.Disposed);
    }

    [Fact]
    public async Task DisposalCancelsPendingSendAndReceiveWithoutLateMessages()
    {
        using var f = new Fixture(); f.Socket.BlockSends = true;
        await f.Send("open"); await f.Read();
        var sending = f.Send("send", data: "AQ==");
        await f.Socket.SendStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        f.Bridge.Dispose(); await sending.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True(f.Socket.SendToken.IsCancellationRequested); Assert.True(f.Socket.Disposed);
        Assert.False(f.Messages.Reader.TryRead(out _));
    }

    [Fact]
    public async Task ManagedSessionNeverInstallsCookieAndRejectsForeignAssets()
    {
        using var f = new Fixture();
        Assert.Throws<InvalidOperationException>(() => f.Session.InstallCookie(f.Policy.NavigationUri, _ => Assert.Fail("不能向网页释放凭据")));
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Session.LoadAssetAsync(new("https://other.invalid/core.js")));
        Assert.Equal("{}", JsonSerializer.Serialize(f.Session)); Assert.DoesNotContain("synthetic-cookie", f.Bridge.Script);
        Assert.Contains(f.Policy.ManagedConnectionPolicy, new VirtualMachineConsoleDocument([], null).ResponseHeaders(f.Policy, true));
        Assert.DoesNotContain("wss:", f.Policy.ManagedConnectionPolicy);
    }

    [Fact]
    public async Task FailingBrowserPostReleasesSocket()
    {
        using var f = new Fixture(failPosts: true); await f.Send("open");
        Assert.True(f.Socket.Disposed);
    }

    [Fact]
    public async Task LocaleReadUsesOnlyTheBoundStaticDirectoryAndDoesNotOpenSocket()
    {
        using var f = new Fixture();
        await f.Send("locale", data: new Uri(f.Policy.NavigationUri, "app/locale/zh.json").AbsoluteUri);
        var result = await f.Read(); Assert.Equal("locale", result["kind"]!.GetValue<string>()); Assert.Equal(200, result["status"]!.GetValue<int>());
        Assert.Equal("{\"ready\":true}", result["body"]!.GetValue<string>()); Assert.Equal(1, f.AssetReads); Assert.Equal(0, f.Connects);
        await f.Send("locale", data: new Uri(f.Policy.NavigationUri, "app/locale/zh.json").AbsoluteUri);
        Assert.Equal(1, f.AssetReads); Assert.False(f.Messages.Reader.TryRead(out _));
    }
    [Theory]
    [InlineData("https://other.invalid/webman/3rdparty/Virtualization/noVNC/app/locale/zh.json")]
    [InlineData("https://nas.invalid/webapi/entry.cgi")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/locale/config.json")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/locale/zh.json?_sid=forbidden")]
    public async Task LocaleBridgeIsNotAnAuthenticatedGeneralProxy(string address)
    {
        using var f = new Fixture(); await f.Send("locale", data: address);
        Assert.Equal(403, (await f.Read())["status"]!.GetValue<int>()); Assert.Equal(0, f.AssetReads); Assert.Equal(0, f.Connects);
    }
    [Fact]
    public async Task LocaleCloseCancelsAndDestroysLateBytesWithoutPosting()
    {
        var pending = new TaskCompletionSource<VirtualMachineConsoleDocument>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var f = new Fixture(locale: pending.Task); var reading = f.Send("locale", data: new Uri(f.Policy.NavigationUri, "app/locale/zh.json").AbsoluteUri);
        f.Bridge.Dispose(); Assert.True(f.AssetToken.IsCancellationRequested);
        var bytes = new byte[] { 1, 2, 3 }; pending.SetResult(new(bytes, null, "application/json")); await reading;
        Assert.All(bytes, value => Assert.Equal(0, value)); Assert.False(f.Messages.Reader.TryRead(out _)); Assert.Equal(0, f.LocaleFailures);
    }
    [Fact]
    public async Task LocaleFailuresNotifyTheWindowWithoutReleasingRawErrors()
    {
        using var f = new Fixture(locale: Task.FromException<VirtualMachineConsoleDocument>(new IOException("synthetic sensitive detail")));
        await f.Send("locale", data: new Uri(f.Policy.NavigationUri, "app/locale/zh.json").AbsoluteUri);
        var reply = await f.Read(); Assert.Equal(502, reply["status"]!.GetValue<int>()); Assert.Equal("", reply["body"]!.GetValue<string>()); Assert.Equal(1, f.LocaleFailures);
    }
    [Fact]
    public async Task LocaleConcurrencyIsBoundedAndCloseCancelsEveryRead()
    {
        var pending = new TaskCompletionSource<VirtualMachineConsoleDocument>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var f = new Fixture(locale: pending.Task); var address = new Uri(f.Policy.NavigationUri, "app/locale/zh.json").AbsoluteUri;
        var reads = Enumerable.Range(1, 4).Select(id => f.Send("locale", id, address)).ToArray();
        await f.Send("locale", 5, address); Assert.Equal(429, (await f.Read())["status"]!.GetValue<int>()); Assert.Equal(4, f.AssetReads);
        f.Bridge.Dispose(); pending.SetCanceled(); await Task.WhenAll(reads); Assert.False(f.Messages.Reader.TryRead(out _));
    }
    private sealed class Fixture : IDisposable
    {
        public VirtualMachineConsolePolicy Policy { get; } = VirtualMachineConsolePolicy.Create(new("https://nas.invalid"), "guest-a", "Synthetic", "en-us", Guid.NewGuid());
        public Socket Socket { get; } = new();
        public Channel<JsonObject> Messages { get; } = Channel.CreateUnbounded<JsonObject>();
        public VirtualMachineConsoleSession Session { get; }
        public VirtualMachineConsoleBridge Bridge { get; }
        public int Connects;
        public CancellationToken ConnectToken;
        public int AssetReads, LocaleFailures;
        public CancellationToken AssetToken;
        private readonly string _context;
        public Fixture(Task<WebSocket>? connecting = null, bool failPosts = false, Task<VirtualMachineConsoleDocument>? locale = null)
        {
            Session = new(Guid.NewGuid(), "guest-a", "Synthetic", Policy, "synthetic-cookie",
                _ => Task.FromResult(new VirtualMachineConsoleDocument([], null)),
                (_, token) => { AssetReads++; AssetToken = token; return locale ?? Task.FromResult(new VirtualMachineConsoleDocument(System.Text.Encoding.UTF8.GetBytes("{\"ready\":true}"), null, "application/json")); },
                token => { Connects++; ConnectToken = token; return connecting ?? Task.FromResult<WebSocket>(Socket); });
            Bridge = new(Session, value =>
            {
                if (failPosts) throw new InvalidOperationException("synthetic closed browser");
                Messages.Writer.TryWrite(JsonNode.Parse(value)!.AsObject()); return Task.CompletedTask;
            }, _ => LocaleFailures++);
            _context = JsonSerializer.Deserialize<string>(Bridge.Script.Split("const context = ")[1].Split(';')[0])!;
        }
        public JsonObject Message(string kind, int id = 1, string? data = null)
        {
            var message = new JsonObject { ["context"] = _context, ["id"] = id, ["kind"] = kind };
            if (data is not null) message["data"] = data; return message;
        }
        public Task Send(string kind, int id = 1, string? data = null) => Bridge.AcceptAsync(Policy.NavigationUri, Message(kind, id, data).ToJsonString());
        public async Task<JsonObject> Read() => await Messages.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        public void Dispose() { Bridge.Dispose(); Session.Dispose(); Socket.Dispose(); }
    }

    private sealed class Socket : WebSocket
    {
        private readonly Channel<(byte[] Data, WebSocketMessageType Type, bool End)> _incoming = Channel.CreateUnbounded<(byte[], WebSocketMessageType, bool)>();
        public List<byte[]> Sent { get; } = [];
        public bool Disposed, BlockSends;
        public CancellationToken SendToken;
        public TaskCompletionSource SendStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Queue(byte[] data, bool end = true, WebSocketMessageType type = WebSocketMessageType.Binary) => _incoming.Writer.TryWrite((data, type, end));
        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override WebSocketState State => Disposed ? WebSocketState.Aborted : WebSocketState.Open;
        public override string? SubProtocol => "binary";
        public override void Abort() { Disposed = true; _incoming.Writer.TryComplete(); }
        public override void Dispose() => Abort();
        public override Task CloseAsync(WebSocketCloseStatus status, string? description, CancellationToken token) { Abort(); return Task.CompletedTask; }
        public override Task CloseOutputAsync(WebSocketCloseStatus status, string? description, CancellationToken token) => CloseAsync(status, description, token);
        public override async Task SendAsync(ArraySegment<byte> data, WebSocketMessageType type, bool end, CancellationToken token)
        {
            Assert.Equal(WebSocketMessageType.Binary, type); Assert.True(end); SendToken = token; SendStarted.TrySetResult();
            if (BlockSends) await Task.Delay(Timeout.Infinite, token);
            token.ThrowIfCancellationRequested(); Sent.Add(data.ToArray());
        }
        public override async Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken token)
        {
            var item = await _incoming.Reader.ReadAsync(token); item.Data.CopyTo(buffer.AsSpan());
            return new(item.Data.Length, item.Type, item.End);
        }
    }
}
