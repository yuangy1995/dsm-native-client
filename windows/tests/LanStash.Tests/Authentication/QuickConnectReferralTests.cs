using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Authentication;

public sealed class QuickConnectReferralTests
{
    private const string Online = """[{"errno":0,"server":{"ds_state":"CONNECTED"},"service":{"port":5001},"smartdns":{"host":"sample.direct.quickconnect.to"}}]""";

    [Fact]
    public async Task RegionalReferralIsFollowedBeforeReportingNotFound()
    {
        using var handler = new Handler(request => request.RequestUri!.Host == "region.quickconnect.to"
            ? Online : """[{"errno":4,"suberrno":0,"sites":["region.quickconnect.to"]}]""");
        using var http = new HttpClient(handler);
        var endpoints = await new DsmQuickConnectResolver(http).ResolveAsync("sample");
        Assert.Single(endpoints);
        Assert.Equal("sample.direct.quickconnect.to", endpoints[0].Host);
        Assert.Equal(3, handler.Hosts.Count);
        Assert.All(handler.Bodies, body => { Assert.DoesNotContain("passwd", body); Assert.DoesNotContain("account", body); });
    }

    [Theory]
    [InlineData("attacker.invalid")]
    [InlineData("global.quickconnect.to.attacker.invalid")]
    [InlineData("global.quickconnect.to/path")]
    [InlineData("user@global.quickconnect.to")]
    public async Task ReferralsCannotSendRequestsOutsideOfficialHosts(string site)
    {
        using var handler = new Handler(_ => "[{\"errno\":4,\"sites\":[\"" + site + "\"]}]");
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<DsmException>(() => new DsmQuickConnectResolver(http).ResolveAsync("sample"));
        Assert.Equal(DsmErrorKind.QuickConnectInvalidResponse, error.Kind);
        Assert.Equal(2, handler.Hosts.Count);
        Assert.DoesNotContain(site, handler.Hosts);
    }

    [Fact]
    public async Task ReferralCyclesAndUnboundedListsAreBounded()
    {
        using var handler = new Handler(_ => "[{\"errno\":4,\"sites\":[" + string.Join(',',
            Enumerable.Range(0, 30).Select(i => $"\"region-{i}.quickconnect.to\"")) + "]}]");
        using var http = new HttpClient(handler);
        await Assert.ThrowsAsync<DsmException>(() => new DsmQuickConnectResolver(http).ResolveAsync("sample"));
        Assert.Equal(8, handler.Hosts.Count);
        Assert.Equal(handler.Hosts.Count, handler.Hosts.Distinct().Count());
    }

    [Fact]
    public async Task OnlineWithoutDirectRouteIsPreservedForRelay()
    {
        using var handler = new Handler(_ => """[{"errno":0,"server":{"ds_state":"CONNECTED"}}]""");
        using var http = new HttpClient(handler);
        var error = await Assert.ThrowsAsync<DsmException>(() => new DsmQuickConnectResolver(http).ResolveAsync("sample"));
        Assert.Equal(DsmErrorKind.QuickConnectDirectUnavailable, error.Kind);
        Assert.Single(handler.Hosts);
    }

    [Fact]
    public async Task CancellationStopsBeforeQueryingAnyServer()
    {
        using var handler = new Handler(_ => Online);
        using var http = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => new DsmQuickConnectResolver(http).ResolveAsync("sample", new CancellationToken(true)));
        Assert.Empty(handler.Hosts);
    }

    private sealed class Handler(Func<HttpRequestMessage, string> response) : HttpMessageHandler
    {
        public List<string> Hosts { get; } = [];
        public List<string> Bodies { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Hosts.Add(request.RequestUri!.Host);
            Bodies.Add(await request.Content!.ReadAsStringAsync(cancellationToken));
            return new(HttpStatusCode.OK) { Content = new StringContent(response(request), Encoding.UTF8, "application/json") };
        }
    }
}
