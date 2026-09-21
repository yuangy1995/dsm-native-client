using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineConsoleSocketTests
{
    [Fact]
    public void SocketPolicyBindsDocumentWindowAndDocumentedAliasPrefix()
    {
        var windowId = Guid.NewGuid();
        var policy = VirtualMachineConsolePolicy.Create(new("https://nas.invalid:5001"), "guest-a", "Demo", "en-us", windowId);
        Assert.Equal(new Uri("wss://nas.invalid:5001/synovirtualization/ws/guest-a?app_id=" + windowId.ToString("D")), policy.SocketUri);
        Assert.Equal("{}", System.Text.Json.JsonSerializer.Serialize(policy));
        var alias = VirtualMachineConsolePolicy.Create(new("https://nas.invalid/alias"), "guest-a", "Demo", "en-us", windowId);
        Assert.True(alias.SupportsManagedSocket); Assert.Equal(new Uri("wss://nas.invalid/alias/synovirtualization/ws/guest-a?app_id=" + windowId.ToString("D")), alias.SocketUri);
    }

    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task PinnedTlsHandshakeExchangesBinaryDataAndLeavesSharedClientAlive(bool alias)
    {
        using var server = new TlsPeer();
        var profile = Profile(server.Port);
        if (alias) profile = profile with { Host = "https://127.0.0.1/vmm-alias" };
        using var http = new HttpClient(new WindowsCertificateTrustHandler(profile.Id, server.Fingerprint));
        var api = new DsmApiClient(http);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        WebSocket connected;
        var policy = Policy(api, profile);
        try { connected = await api.ConnectConsoleSocketAsync(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), policy, timeout.Token); }
        catch (Exception error) { throw new InvalidOperationException("合成 TLS 对端握手失败。", server.HandshakeFailure ?? error); }
        using var socket = connected;
        await socket.SendAsync(new byte[] { 1, 2, 3 }, WebSocketMessageType.Binary, true, timeout.Token);
        var buffer = new byte[16];
        var result = await socket.ReceiveAsync(buffer, timeout.Token);
        Assert.Equal(WebSocketMessageType.Binary, result.MessageType);
        Assert.Equal(new byte[] { 9, 8, 7 }, buffer[..result.Count]);
        await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, null, timeout.Token);
        await server.Completion.WaitAsync(timeout.Token);
        Assert.Contains("GET " + policy.SocketUri!.PathAndQuery + " HTTP/1.1", server.Headers);
        Assert.Contains("?app_id=", policy.SocketUri.Query);
        Assert.Contains("Cookie: id=synthetic-sid", server.Headers);
        Assert.Contains("X-SYNO-TOKEN: synthetic-token", server.Headers);
        Assert.Contains($"Origin: https://127.0.0.1:{server.Port}", server.Headers);
        Assert.DoesNotContain("_sid=", server.Headers);
        Assert.Equal(new byte[] { 1, 2, 3 }, server.Received);
        // 包装器不能释放共用客户端；已关闭的测试监听地址应是连接失败，而非对象已释放。
        var failure = await Record.ExceptionAsync(() => http.GetAsync($"https://127.0.0.1:{server.Port}/", timeout.Token));
        Assert.IsNotType<ObjectDisposedException>(failure);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnapprovedOrChangedCertificateIsRejectedBeforeCredentials(bool changed)
    {
        using var server = new TlsPeer(); var profile = Profile(server.Port);
        var pin = changed ? new CertificateFingerprint(new string('A', 64)) : null;
        using var http = new HttpClient(new WindowsCertificateTrustHandler(profile.Id, pin)); var api = new DsmApiClient(http);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var error = await Record.ExceptionAsync(async () => { using var socket = await api.ConnectConsoleSocketAsync(profile, new(profile.Id, "synthetic-sid", null, null), Policy(api, profile), timeout.Token); });
        Assert.NotNull(error);
        Assert.Contains(ExceptionChain(error), item => item is CertificateTrustChallengeException);
        await server.Completion.WaitAsync(timeout.Token);
        Assert.Null(server.Headers); Assert.Null(server.Received);
    }

    [Theory]
    [InlineData("profile")]
    [InlineData("origin")]
    [InlineData("cookie")]
    [InlineData("token")]
    [InlineData("alias")]
    public async Task InvalidBindingsNeverReachTheTransport(string invalid)
    {
        var calls = 0; using var http = new HttpClient(new Handler((_, _) => { calls++; return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)); }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", invalid == "alias" ? "https://nas.invalid/alias" : "nas.invalid", 5001, "synthetic");
        var api = new DsmApiClient(http);
        var policy = VirtualMachineConsolePolicy.Create(invalid == "origin" ? new Uri("https://other.invalid") : invalid == "alias" ? new Uri("https://nas.invalid:5001/other-alias") : api.GetBaseUri(profile), "guest-a", "Demo", "en-us", Guid.NewGuid());
        var session = new DsmSession(invalid == "profile" ? Guid.NewGuid() : profile.Id,
            invalid == "cookie" ? "bad;cookie" : "synthetic", invalid == "token" ? "bad\r\nheader" : null, null);
        await Assert.ThrowsAnyAsync<Exception>(() => api.ConnectConsoleSocketAsync(profile, session, policy));
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task CancellationAbortsHandshakeWithoutReplacingCertificateContext()
    {
        var reached = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var http = new HttpClient(new Handler(async (request, token) =>
        {
            Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(request, out var id, out var source));
            Assert.NotEqual(Guid.Empty, id); Assert.Equal(DsmConnectionSource.DirectAddress, source);
            reached.SetResult(); await Task.Delay(Timeout.Infinite, token);
            return new(HttpStatusCode.Unauthorized);
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic"); var api = new DsmApiClient(http);
        using var cancellation = new CancellationTokenSource();
        var connecting = api.ConnectConsoleSocketAsync(profile, new(profile.Id, "synthetic", null, null), Policy(api, profile), cancellation.Token);
        await reached.Task.WaitAsync(TimeSpan.FromSeconds(3)); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => connecting);
    }

    private static NasProfile Profile(int port) => new(Guid.NewGuid(), "Synthetic", "127.0.0.1", port, "synthetic");
    private static VirtualMachineConsolePolicy Policy(DsmApiClient api, NasProfile profile) => VirtualMachineConsolePolicy.Create(api.GetBaseUri(profile), "guest-a", "Demo", "en-us", Guid.NewGuid());
    private static IEnumerable<Exception> ExceptionChain(Exception error) { for (Exception? current = error; current is not null; current = current.InnerException) yield return current; }

    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> callback) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        => callback(request, token);
    }

    private sealed class TlsPeer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _lifetime = new(TimeSpan.FromSeconds(10));
        private readonly X509Certificate2 _certificate;
        public int Port { get; }
        public CertificateFingerprint Fingerprint { get; }
        public string? Headers { get; private set; }
        public byte[]? Received { get; private set; }
        public Exception? HandshakeFailure { get; private set; }
        public Task Completion { get; }
        public TlsPeer()
        {
            using var key = RSA.Create(2048);
            var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, true));
            var names = new SubjectAlternativeNameBuilder(); names.AddIpAddress(IPAddress.Loopback); names.AddDnsName("localhost"); request.CertificateExtensions.Add(names.Build());
            using var temporary = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddHours(1));
            // Windows Schannel 不接受纯内存私钥；默认导入创建由证书 Dispose 清理的临时密钥。
            // 不使用 PersistKeySet，不加入任何证书存储或信任列表，也不保存 PFX 文件。
            var encoded = temporary.Export(X509ContentType.Pfx);
            try { _certificate = X509CertificateLoader.LoadPkcs12(encoded, null, X509KeyStorageFlags.DefaultKeySet); }
            finally { CryptographicOperations.ZeroMemory(encoded); }
            Fingerprint = new(Convert.ToHexString(SHA256.HashData(_certificate.RawData)));
            _listener.Start(); Port = ((IPEndPoint)_listener.LocalEndpoint).Port; Completion = RunAsync();
        }
        private async Task RunAsync()
        {
            var token = _lifetime.Token;
            try
            {
                using var client = await _listener.AcceptTcpClientAsync(token);
                await using var tls = new SslStream(client.GetStream(), false);
                try { await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = _certificate, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 }, token); }
                catch (Exception error) when (error is AuthenticationException or IOException) { HandshakeFailure = error; return; }
                var bytes = new List<byte>(); var one = new byte[1];
                try
                {
                    while (bytes.Count < 16384)
                    {
                        if (await tls.ReadAsync(one, token) == 0) return;
                        bytes.Add(one[0]);
                        if (bytes.Count >= 4 && bytes[^4..].SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                    }
                }
                catch (IOException) { return; }
                Headers = Encoding.ASCII.GetString(bytes.ToArray());
                var websocketKey = Headers.Split("\r\n").Single(line => line.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)).Split(':', 2)[1].Trim();
                var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(websocketKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                await tls.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: binary\r\n\r\n"), token);
                using var socket = WebSocket.CreateFromStream(tls, true, "binary", Timeout.InfiniteTimeSpan);
                var buffer = new byte[16]; var read = await socket.ReceiveAsync(buffer, token); Received = buffer[..read.Count];
                await socket.SendAsync(new byte[] { 9, 8, 7 }, WebSocketMessageType.Binary, true, token);
                read = await socket.ReceiveAsync(buffer, token);
                if (read.MessageType == WebSocketMessageType.Close) await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, token);
            }
            finally { _listener.Stop(); }
        }
        public void Dispose() { _lifetime.Cancel(); _listener.Stop(); _certificate.Dispose(); _lifetime.Dispose(); }
    }
}
