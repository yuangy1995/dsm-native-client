using System.Net;
using System.Net.Http.Headers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineConsoleAssetTests
{
    [Theory]
    [InlineData("app/locale/zh.json", "application/json")]
    [InlineData("app/locale/pt_BR.json", "application/json")]
    [InlineData("app/sounds/bell.oga", "audio/ogg")]
    [InlineData("../images/VirtualManagement_32.png", "image/png")]
    public void DocumentedAssetsAreAliasBound(string relative, string mediaType)
    {
        var policy = VirtualMachineConsolePolicy.Create(new("https://nas.invalid/vmm-alias"), "guest-a", "Demo", "en-us", Guid.NewGuid());
        var target = new Uri(policy.NavigationUri, relative);
        Assert.Equal(mediaType, policy.ManagedAssetMediaType(target));
        Assert.Null(policy.ManagedAssetMediaType(new(target.AbsoluteUri.Replace("/vmm-alias/", "/another/", StringComparison.Ordinal))));
        Assert.Null(policy.ManagedAssetMediaType(new(target.AbsoluteUri.Replace("/vmm-alias/", "/", StringComparison.Ordinal))));
    }
    [Theory]
    [InlineData("app/config.json")][InlineData("app/locale/config.json")][InlineData("app/locale/en/private.json")]
    [InlineData("app/locale/zh.json?api=SYNO.API.Auth")][InlineData("app/sounds/other.oga")]
    [InlineData("../images/private.png")][InlineData("../images/VirtualManagement_512.png")]
    public void AdditionalSupportDoesNotPermitGeneralJsonAudioOrPackageImages(string relative)
    {
        var policy = VirtualMachineConsolePolicy.Create(new("https://nas.invalid/vmm-alias"), "guest-a", "Demo", "en-us", Guid.NewGuid());
        Assert.Null(policy.ManagedAssetMediaType(new(policy.NavigationUri, relative)));
    }
    [Theory]
    [InlineData("app/locale/zh.json", "application/json")]
    [InlineData("app/sounds/bell.oga", "application/octet-stream")]
    [InlineData("app/sounds/bell.oga", "audio/ogg")]
    public async Task LocaleAndKnownBellUseTheSameAuthenticatedTransport(string relative, string contentType)
    {
        var profile = Profile() with { Host = "https://nas.invalid/vmm-alias" };
        using var http = new HttpClient(new Handler(request =>
        {
            Assert.StartsWith("/vmm-alias/webman/3rdparty/Virtualization/noVNC/", request.RequestUri!.AbsolutePath);
            Assert.Equal("id=synthetic", Assert.Single(request.Headers.GetValues("Cookie")));
            var result = new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent([1, 2, 3]) };
            result.Content.Headers.ContentType = new(contentType); return result;
        }));
        var api = new DsmApiClient(http); var policy = Policy(api, profile);
        using var result = await api.ReadConsoleAssetAsync(profile, Session(profile), policy, new(policy.NavigationUri, relative));
        Assert.Equal(contentType, result.ContentType); Assert.Equal(new byte[] { 1, 2, 3 }, result.Content);
        Assert.Contains("connect-src 'none'", result.ResponseHeaders(policy, true));
        Assert.DoesNotContain("connect-src 'self'", result.ResponseHeaders(policy, true));
    }
    [Theory]
    [InlineData("https://other.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js")]
    [InlineData("http://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js")]
    [InlineData("https://nas.invalid/webapi/entry.cgi?method=delete")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/entry.cgi.js")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js?_sid=forbidden")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js?v=1&method=delete")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js#fragment")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/%2fwebapi.js")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/../../secret.js")]
    [InlineData("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/vnc.html")]
    public async Task UntrustedAssetTargetsNeverReceiveCredentials(string address)
    {
        var calls = 0; using var http = new HttpClient(new Handler(_ => { calls++; return new(HttpStatusCode.OK); }));
        var api = new DsmApiClient(http); var profile = Profile();
        await Assert.ThrowsAsync<InvalidOperationException>(() => api.ReadConsoleAssetAsync(profile, Session(profile), Policy(api, profile), new(address)));
        Assert.Equal(0, calls);
    }

    [Theory]
    [InlineData("text/javascript")]
    [InlineData("application/javascript")]
    public async Task ScriptsUseExistingProfileContextAndDoNotForwardResponseCookies(string contentType)
    {
        var profile = Profile(); var disposed = false;
        using var http = new HttpClient(new Handler(request =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(request, out var id, out var source));
            Assert.Equal(profile.Id, id); Assert.Equal(DsmConnectionSource.DirectAddress, source);
            Assert.Equal("id=synthetic", Assert.Single(request.Headers.GetValues("Cookie")));
            var response = new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new StringContent("window.synthetic = true;") };
            response.Content.Headers.ContentType = new(contentType); response.Headers.TryAddWithoutValidation("Set-Cookie", "forbidden=synthetic"); return response;
        }, () => disposed = true));
        var api = new DsmApiClient(http); var policy = Policy(api, profile);
        using var asset = await api.ReadConsoleAssetAsync(profile, Session(profile), policy, new("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js?v=1"));
        Assert.NotEmpty(asset.Content); Assert.DoesNotContain("Set-Cookie", asset.ResponseHeaders(policy, managedTransport: true));
        Assert.Contains(policy.ManagedConnectionPolicy, asset.ResponseHeaders(policy, managedTransport: true));
        Assert.DoesNotContain("wss:", policy.ManagedConnectionPolicy); Assert.Contains("connect-src 'none'", policy.ManagedConnectionPolicy); Assert.False(disposed);
    }

    [Fact]
    public async Task HtmlAndOversizedRepliesCannotBeLoadedAsScripts()
    {
        var profile = Profile();
        foreach (var oversized in new[] { false, true })
        {
            using var http = new HttpClient(new Handler(request =>
            {
                var response = new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent([1]) };
                response.Content.Headers.ContentType = new(oversized ? "text/javascript" : "text/html");
                if (oversized) response.Content.Headers.ContentLength = DsmApiClient.MaximumConsoleAssetBytes + 1L;
                return response;
            }));
            var api = new DsmApiClient(http);
            await Assert.ThrowsAsync<DsmBinaryResponseException>(() => api.ReadConsoleAssetAsync(profile, Session(profile), Policy(api, profile), new("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js")));
        }
    }

    [Fact]
    public async Task RedirectDoesNotBecomeAnAssetResponse()
    {
        var profile = Profile(); using var http = new HttpClient(new Handler(request =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.Redirect) { RequestMessage = request };
            response.Headers.Location = new("https://other.invalid/"); return response;
        }));
        var api = new DsmApiClient(http);
        await Assert.ThrowsAsync<DsmException>(() => api.ReadConsoleAssetAsync(profile, Session(profile), Policy(api, profile), new("https://nas.invalid/webman/3rdparty/Virtualization/noVNC/app/ui.js")));
    }
    [Fact]
    public async Task LocaleLimitIsCheckedBeforeReadingAnOversizedResponse()
    {
        var profile = Profile(); using var http = new HttpClient(new Handler(request =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request, Content = new ByteArrayContent([1]) };
            response.Content.Headers.ContentType = new("application/json"); response.Content.Headers.ContentLength = VirtualMachineConsolePolicy.MaximumLocaleBytes + 1L; return response;
        }));
        var api = new DsmApiClient(http); var policy = Policy(api, profile);
        var error = await Assert.ThrowsAsync<DsmBinaryResponseException>(() => api.ReadConsoleAssetAsync(profile, Session(profile), policy, new(policy.NavigationUri, "app/locale/zh.json")));
        Assert.Equal(DsmBinaryResponseFailure.ResponseTooLarge, error.Failure);
    }

    private static NasProfile Profile() => new(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
    private static DsmSession Session(NasProfile profile) => new(profile.Id, "synthetic", null, null);
    private static VirtualMachineConsolePolicy Policy(DsmApiClient api, NasProfile profile) => VirtualMachineConsolePolicy.Create(api.GetBaseUri(profile), "guest-a", "Demo", "en-us", Guid.NewGuid());
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response, Action? disposed = null) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => Task.FromResult(response(request));
        protected override void Dispose(bool disposing) { disposed?.Invoke(); base.Dispose(disposing); }
    }
}
