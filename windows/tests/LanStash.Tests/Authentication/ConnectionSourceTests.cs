using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class ConnectionSourceTests
{
    [Theory]
    [InlineData(QuickConnectEndpointKind.Local, DsmConnectionSource.QuickConnectLan)]
    [InlineData(QuickConnectEndpointKind.External, DsmConnectionSource.QuickConnectExternal)]
    [InlineData(QuickConnectEndpointKind.Relay, DsmConnectionSource.QuickConnectRelay)]
    public void QuickConnectEndpointKindsHaveStableSources(
        QuickConnectEndpointKind endpoint,
        DsmConnectionSource expected)
    {
        Assert.Equal(expected, DsmConnectionResolver.ConnectionSourceFor(endpoint));
    }

    [Fact]
    public async Task DirectDiscoveryPublishesDirectSourceWithoutLogin()
    {
        var api = new SourceCapturingApiClient();
        using var http = new HttpClient(new RejectingHandler());
        var resolver = new DsmConnectionResolver(api, new DsmQuickConnectResolver(http));
        var profile = new NasProfile(
            Guid.NewGuid(),
            "Synthetic NAS",
            "nas.example.invalid",
            null,
            "unused-account");

        var result = await resolver.DiscoverAsync(profile);

        Assert.Equal(DsmConnectionSource.DirectAddress, result.Source);
        Assert.Equal(DsmConnectionSource.DirectAddress, api.Source);
        Assert.Equal(0, api.LoginCount);
    }

    [Fact]
    public async Task SourceAwareDiscoverySendsNoCredentials()
    {
        var handler = new CapturingHandler();
        using var http = new HttpClient(handler);
        var api = new DsmApiClient(http);
        var profile = new NasProfile(
            Guid.NewGuid(),
            "Synthetic NAS",
            "nas.example.invalid",
            null,
            "private-account");

        _ = await api.DiscoverAsync(
            profile,
            DsmConnectionSource.QuickConnectLan);

        Assert.Contains("api=SYNO.API.Info", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("private-account", handler.Body, StringComparison.Ordinal);
        Assert.DoesNotContain("account=", handler.Body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("passwd", handler.Body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("otp", handler.Body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("_sid", handler.Body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("token", handler.Body, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("did", handler.Body, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class SourceCapturingApiClient : IDsmApiClient
    {
        public DsmConnectionSource? Source { get; private set; }
        public int LoginCount { get; private set; }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.example.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) =>
            DiscoverAsync(profile, DsmConnectionSource.DirectAddress, cancellationToken);

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            DsmConnectionSource source,
            CancellationToken cancellationToken = default)
        {
            Source = source;
            return Task.FromResult<IReadOnlyDictionary<string, ApiCapability>>(
                new Dictionary<string, ApiCapability>());
        }

        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default)
        {
            LoginCount++;
            throw new InvalidOperationException("Login must not run during discovery.");
        }

        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed class RejectingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Direct discovery must not use QuickConnect.");
    }

    private sealed class CapturingHandler : HttpMessageHandler
    {
        public string Body { get; private set; } = string.Empty;

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Body = request.Content is null
                ? string.Empty
                : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"success":true,"data":{}}""",
                    System.Text.Encoding.UTF8,
                    "application/json"),
            };
        }
    }

}
