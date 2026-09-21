using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineConsoleTests
{
    private static VirtualMachineSummary Machine => new("guest-a", "Demo & VM", VirtualMachineOperationalState.Running, null, null, null, null, null);
    private static VirtualMachineConsolePolicy Policy(string origin = "https://nas.invalid:5001") =>
        VirtualMachineConsolePolicy.Create(new(origin), Machine.Id, Machine.Name, "de-de", Guid.NewGuid());

    [Fact]
    public void PolicyEncodesMetadataPreservesAliasAndConstrainsEveryOriginComponent()
    {
        var policy = Policy("https://nas.invalid:5001/vmm-alias"); var query = Query(policy.NavigationUri.Query);
        Assert.Equal("/vmm-alias" + VirtualMachineConsolePolicy.ConsolePath, policy.NavigationUri.AbsolutePath);
        Assert.Equal("synovirtualization/ws/guest-a", query["path"]); Assert.Equal(Machine.Name, query["title"]);
        Assert.Equal("vmm-alias", query["app_alias"]); Assert.Equal("de-de", query["kb_layout"]); Assert.True(Guid.TryParse(query["app_id"], out _));
        Assert.DoesNotContain("_sid", query.Keys); Assert.DoesNotContain("SynoToken", query.Keys);
        Assert.True(policy.AllowsNavigation(policy.NavigationUri)); Assert.True(policy.AllowsResource(new("wss://nas.invalid:5001/synovirtualization/ws/guest-a")));
        Assert.Contains("connect-src https://nas.invalid:5001 wss://nas.invalid:5001", policy.ConnectionPolicy);
        Assert.Equal("{}", JsonSerializer.Serialize(policy)); Assert.Equal(nameof(VirtualMachineConsolePolicy), policy.ToString());
    }
    [Theory]
    [InlineData("http://nas.invalid:5001/resource")][InlineData("https://other.invalid:5001/resource")]
    [InlineData("https://nas.invalid/resource")][InlineData("https://nas.invalid.evil.invalid:5001/resource")]
    [InlineData("https://user@nas.invalid:5001/resource")][InlineData("file:///local/file")]
    [InlineData("ws://nas.invalid:5001/socket")][InlineData("javascript:alert(1)")]
    public void ResourcesCannotEscapeTheAuthenticatedOrigin(string candidate) => Assert.False(Policy().AllowsResource(new(candidate)));
    [Theory]
    [InlineData("http://nas.invalid")][InlineData("https://user@nas.invalid")][InlineData("https://nas.invalid/?_sid=secret")]
    [InlineData("https://nas.invalid/#fragment")][InlineData("https://nas.invalid/a/b")]
    public void UnsafeBaseUrisCannotProduceAConsoleAddress(string origin) => Assert.Throws<ArgumentException>(() => Policy(origin));
    [Theory]
    [InlineData("../guest")][InlineData("guest/other")][InlineData("guest?x")][InlineData("guest%2fother")][InlineData("guest\n")]
    public void GuestIdentifiersCannotBecomeRoutes(string id) => Assert.Throws<ArgumentException>(() =>
        VirtualMachineConsolePolicy.Create(new("https://nas.invalid"), id, "Demo", "en-us", Guid.NewGuid()));
    [Fact]
    public void NavigationCannotChangeDocumentOrQueryAndServerCspIsNotReplaced()
    {
        var policy = Policy();
        Assert.False(policy.AllowsNavigation(new("https://nas.invalid:5001/webman/index.cgi")));
        Assert.False(policy.AllowsNavigation(new(policy.NavigationUri.AbsoluteUri + "&_sid=forbidden")));
        Assert.False(policy.AllowsNavigation(new(policy.NavigationUri.AbsoluteUri + "#fragment")));
        using var document = new VirtualMachineConsoleDocument([1, 2], "default-src 'self'");
        Assert.Contains("default-src 'self', connect-src", document.ResponseHeaders(policy));
        Assert.Contains("Cache-Control: no-store", document.ResponseHeaders(policy)); Assert.Equal("{}", JsonSerializer.Serialize(document));
        using var invalid = new VirtualMachineConsoleDocument([1], "default-src 'self'\r\nInjected: true");
        Assert.Throws<InvalidOperationException>(() => invalid.ResponseHeaders(policy));
    }
    [Fact]
    public void CookieIsOneShotOriginBoundAndNeverSerialized()
    {
        var policy = Policy(); using var session = new VirtualMachineConsoleSession(Guid.NewGuid(), Machine.Id, Machine.Name, policy,
            "synthetic-private-session", _ => Task.FromResult(new VirtualMachineConsoleDocument([1], null)));
        Assert.Throws<InvalidOperationException>(() => session.InstallCookie(new("https://other.invalid/"), _ => Assert.Fail("不得释放凭据")));
        string? installed = null; session.InstallCookie(policy.NavigationUri, value => installed = value);
        Assert.Equal("synthetic-private-session", installed); Assert.Equal("{}", JsonSerializer.Serialize(session));
        Assert.Equal(nameof(VirtualMachineConsoleSession), session.ToString());
        Assert.Throws<InvalidOperationException>(() => session.InstallCookie(policy.NavigationUri, _ => Assert.Fail("不得重复注入")));
        session.Dispose(); Assert.Throws<ObjectDisposedException>(() => session.InstallCookie(policy.NavigationUri, _ => Assert.Fail("关闭后不得注入")));
    }
    [Theory]
    [InlineData("bad;cookie")][InlineData("bad\r\nheader")][InlineData("bad value")][InlineData("bad\\value")][InlineData("bad\"value")]
    public void CookieValidationRejectsHeaderAndCookieInjection(string cookie) => Assert.False(VirtualMachineConsoleSession.ValidCookie(cookie));
    [Fact]
    public async Task ClosingCancelsReadsAndDestroysLateDocumentContent()
    {
        var pending = new TaskCompletionSource<VirtualMachineConsoleDocument>(TaskCreationOptions.RunContinuationsAsynchronously); CancellationToken observed = default;
        var session = new VirtualMachineConsoleSession(Guid.NewGuid(), Machine.Id, Machine.Name, Policy(), "synthetic",
            token => { observed = token; return pending.Task; });
        var loading = session.LoadDocumentAsync(); session.Dispose(); Assert.True(observed.IsCancellationRequested);
        var bytes = new byte[] { 1, 2, 3 }; pending.SetResult(new(bytes, null));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => loading); Assert.All(bytes, value => Assert.Equal(0, value));
        await Assert.ThrowsAsync<ObjectDisposedException>(() => session.LoadDocumentAsync());
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task PreparationBindsFreshRunningGuestAndUsesRealDefaultKeyboard(string format)
    {
        using var f = new Fixture(format); using var session = await f.Repository.OpenConsoleAsync(Machine);
        Assert.Equal("de-de", Query(session.Policy.NavigationUri.Query)["kb_layout"]);
        Assert.Equal(3, f.ApiCalls.Count); Assert.All(f.ApiCalls, call => Assert.Equal("get", call["method"]));
        Assert.Equal("1", f.ApiCalls[0]["version"]); Assert.Equal("2", f.ApiCalls[1]["version"]); Assert.Equal("1", f.ApiCalls[2]["version"]);
        using var document = await session.LoadDocumentAsync(); var request = Assert.Single(f.Documents);
        Assert.DoesNotContain("synthetic-session", request.RequestUri!.AbsoluteUri); Assert.Contains("id=synthetic-session", request.Headers.GetValues("Cookie"));
        Assert.Contains("default-src 'self'", document.ResponseHeaders(session.Policy)); Assert.Contains("wss://nas.invalid:5001", document.ResponseHeaders(session.Policy));
        Assert.Equal("<html>synthetic</html>", Encoding.UTF8.GetString(document.Content));
    }
    [Fact]
    public async Task ManagedTransportNeverReleasesCookieAndChangedTargetsStillFail()
    {
        using var f = new Fixture(); var managed = f.Recreate(systemTrust: false); Assert.True(managed.CanOpenConsole);
        using var session = await managed.OpenConsoleAsync(Machine); Assert.True(session.UsesManagedTransport);
        Assert.Throws<InvalidOperationException>(() => session.InstallCookie(session.Policy.NavigationUri, _ => Assert.Fail("不得安装 Cookie")));
        f.Status = "shutdown"; await Assert.ThrowsAsync<DsmException>(() => f.Repository.OpenConsoleAsync(Machine));
        f.Status = "running"; f.Name = "Changed"; await Assert.ThrowsAsync<DsmException>(() => f.Repository.OpenConsoleAsync(Machine));
        Assert.Empty(f.Documents);
        f.Capabilities.Remove(Fixture.InternalGuest); Assert.False(f.Repository.CanOpenConsole);
    }
    [Fact]
    public async Task ManagedTransportSupportsSingleAliasWithoutAcceptingNestedPaths()
    {
        using var f = new Fixture(); var profile = f.Profile with { Host = "https://nas.invalid:5001/vmm-alias" };
        var repository = new DsmRepository(profile, f.Session, f.Api, f.Capabilities) { ConsoleUsesSystemTrust = false };
        Assert.True(repository.CanOpenConsole);
        using var session = await repository.OpenConsoleAsync(Machine);
        Assert.True(session.UsesManagedTransport); Assert.StartsWith("/vmm-alias/synovirtualization/ws/", session.Policy.SocketUri!.AbsolutePath);
        var nested = new DsmRepository(profile with { Host = "https://nas.invalid:5001/one/two" }, f.Session, f.Api, f.Capabilities);
        var before = f.ApiCalls.Count; Assert.False(nested.CanOpenConsole);
        await Assert.ThrowsAsync<DsmException>(() => nested.OpenConsoleAsync(Machine)); Assert.Equal(before, f.ApiCalls.Count);
    }
    [Theory]
    [InlineData("guest_id")][InlineData("name")][InlineData("is_online")][InlineData("kb_layout")]
    public async Task MissingInternalEvidenceCannotBecomeConsoleDefaults(string missing)
    {
        using var f = new Fixture { Missing = missing };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.OpenConsoleAsync(Machine)); Assert.Empty(f.Documents);
    }
    [Fact]
    public async Task ExplicitKeyboardDoesNotDependOnGeneralSettingAndPowerUnknownBlocksConsole()
    {
        using var f = new Fixture { Keyboard = "fr-fr" }; f.Capabilities.Remove(Fixture.General);
        using var session = await f.Repository.OpenConsoleAsync(Machine); Assert.Equal("fr-fr", Query(session.Policy.NavigationUri.Query)["kb_layout"]);
        Assert.Equal(2, f.ApiCalls.Count);
        await f.Repository.ControlPowerAsync(new(f.Profile.Id, Machine, VirtualMachinePowerAction.Shutdown, Guid.NewGuid(), true));
        var count = f.ApiCalls.Count; await Assert.ThrowsAsync<DsmException>(() => f.Repository.OpenConsoleAsync(Machine)); Assert.Equal(count, f.ApiCalls.Count);
    }
    [Theory]
    [InlineData(302)][InlineData(401)][InlineData(403)][InlineData(206)][InlineData(500)]
    public async Task HtmlResponsesCannotFollowRedirectsOrIgnoreAuthentication(int status)
    {
        using var f = new Fixture { DocumentStatus = (HttpStatusCode)status }; using var session = await f.Repository.OpenConsoleAsync(Machine);
        var error = await Assert.ThrowsAsync<DsmException>(() => session.LoadDocumentAsync()); Assert.Equal(status is 401 or 403, error.AuthenticationFailure);
        Assert.Single(f.Documents);
    }
    [Theory]
    [InlineData("application/json")][InlineData("text/html-extra")][InlineData("text/plain")]
    public async Task ConsoleDocumentRequiresExactHtmlMediaType(string type)
    {
        using var f = new Fixture { ContentType = type }; using var session = await f.Repository.OpenConsoleAsync(Machine);
        Assert.Equal(DsmBinaryResponseFailure.UnexpectedMediaType, (await Assert.ThrowsAsync<DsmBinaryResponseException>(() => session.LoadDocumentAsync())).Failure);
    }
    [Fact]
    public async Task ConsoleDocumentIsBoundedAndProfileOriginCannotBeChanged()
    {
        using var f = new Fixture { Body = new byte[DsmApiClient.MaximumConsoleDocumentBytes + 1] }; using var session = await f.Repository.OpenConsoleAsync(Machine);
        Assert.Equal(DsmBinaryResponseFailure.ResponseTooLarge, (await Assert.ThrowsAsync<DsmBinaryResponseException>(() => session.LoadDocumentAsync())).Failure);
        var count = f.Documents.Count;
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Api.ReadConsoleDocumentAsync(f.Profile, f.Session, Policy("https://other.invalid")));
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Api.ReadConsoleDocumentAsync(f.Profile, f.Session, Policy("https://nas.invalid:5001/other-alias")));
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Api.ReadConsoleDocumentAsync(f.Profile, f.Session with { ProfileId = Guid.NewGuid() }, Policy()));
        await Assert.ThrowsAsync<InvalidOperationException>(() => f.Api.ReadConsoleDocumentAsync(f.Profile, f.Session with { SynoToken = "synthetic\r\nheader" }, Policy()));
        Assert.Equal(count, f.Documents.Count);
    }
    private static Dictionary<string, string> Query(string query) => query.TrimStart('?').Split('&').Select(part => part.Split('=', 2))
        .ToDictionary(part => Uri.UnescapeDataString(part[0]), part => Uri.UnescapeDataString(part[1]));
    private sealed class Fixture : IDisposable
    {
        public const string InternalGuest = "SYNO.Virtualization.Guest", General = "SYNO.Virtualization.Setting.General";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        private readonly HttpClient _http;
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> ApiCalls { get; } = [];
        public List<HttpRequestMessage> Documents { get; } = [];
        public string Name = Machine.Name, Status = "running", Keyboard = "Default", ContentType = "text/html";
        public string? Missing;
        public HttpStatusCode DocumentStatus = HttpStatusCode.OK;
        public byte[] Body = Encoding.UTF8.GetBytes("<html>synthetic</html>");
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-session", null, null);
            foreach (var api in new[] { "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action", InternalGuest, General })
                Capabilities[api] = new(api, "console-synthetic.cgi", 1, api == InternalGuest ? 2 : 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(bool systemTrust = true) => new(Profile, Session, Api, Capabilities) { ConsoleUsesSystemTrust = systemTrust };
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                if (request.Method == HttpMethod.Get)
                {
                    owner.Documents.Add(request);
                    var response = new HttpResponseMessage(owner.DocumentStatus) { Content = new ByteArrayContent(owner.Body), RequestMessage = request };
                    response.Content.Headers.ContentType = new(owner.ContentType); response.Headers.Add("Content-Security-Policy", "default-src 'self'");
                    if ((int)owner.DocumentStatus == 302) response.Headers.Location = new("https://other.invalid/should-not-be-called");
                    return response;
                }
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = Query(await request.Content!.ReadAsStringAsync(token)); owner.ApiCalls.Add(call);
                if (call["api"].EndsWith(".Action", StringComparison.Ordinal)) throw new HttpRequestException("synthetic lost receipt");
                JsonObject data = call["api"] == General ? new() { ["kb_layout"] = "de-de" } : call["api"] == InternalGuest
                    ? new() { ["guest_id"] = Machine.Id, ["name"] = owner.Name, ["is_online"] = owner.Status == "running", ["kb_layout"] = owner.Keyboard }
                    : new() { ["guest_id"] = Machine.Id, ["guest_name"] = owner.Name, ["status"] = owner.Status };
                if (call["api"] == InternalGuest && owner.Missing is { } missing) data.Remove(missing);
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
