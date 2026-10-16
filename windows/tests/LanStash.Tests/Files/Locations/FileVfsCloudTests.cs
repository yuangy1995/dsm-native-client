using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class FileVfsCloudTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task CloudCreationUsesOfficialStartAndTwoWritesWithoutRetainingTokens(string format)
    {
        using var server = new CloudServer(format);
        var request = await server.Repository.PrepareVfsCloudAsync("google");
        Assert.Equal("synooauth.synology.com", request.LoginUri.Host);
        Assert.Equal("?major=7&minor=2&type=google", request.LoginUri.Query);
        Assert.DoesNotContain("nas.invalid", request.LoginUri.AbsoluteUri);
        using var authorization = Authorization(request);
        var change = Change(server);
        var result = await server.Repository.AuthorizeVfsAsync(change, authorization);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        Assert.Equal(2, server.Writes.Count);
        Assert.All(server.Writes, values =>
        {
            Assert.Equal("create", values["method"]); Assert.Equal("1", values["version"]);
            Assert.Equal(format == "JSON" ? "\"synthetic-access\"" : "synthetic-access", values["access_token"]);
            Assert.Equal("3600", values["expires_in"]); Assert.False(values.ContainsKey("password"));
            Assert.Equal(format == "JSON" ? "\"\"" : "", values["hostname"]);
        });
        Assert.Equal("false", server.Writes[0]["force"]); Assert.False(server.Writes[1].ContainsKey("force"));
        Assert.DoesNotContain(server.Requests, v => v["method"] == "get");
        Assert.DoesNotContain("synthetic-access", JsonSerializer.Serialize(result));
        Assert.DoesNotContain("synthetic-access", JsonSerializer.Serialize(authorization));
        Assert.DoesNotContain("synthetic-refresh", authorization.ToString());
        Assert.False((await server.Repository.AuthorizeVfsAsync(change, authorization)).Outcome.Submitted);
        Assert.Equal(2, server.Writes.Count);
    }

    [Theory]
    [InlineData("account")]
    [InlineData("protocol")]
    [InlineData("profile")]
    [InlineData("request")]
    [InlineData("confirmation")]
    [InlineData("cancelled")]
    [InlineData("replaced")]
    [InlineData("foreign-repository")]
    public async Task AuthorizationMustBelongToOriginalAttemptAndIdentity(string kind)
    {
        using var server = new CloudServer();
        var request = await server.Repository.PrepareVfsCloudAsync("google"); var change = Change(server);
        using var authorization = new FileVfsCloudAuthorization(kind == "request" ? Guid.NewGuid() : request.RequestId,
            kind == "profile" ? Guid.NewGuid() : request.ProfileId, kind == "protocol" ? "box" : "google",
            kind == "account" ? "other" : "sample", "synthetic-access");
        if (kind == "confirmation") change = change with { Confirmed = false };
        if (kind == "cancelled") server.Repository.CancelVfsCloud(request.RequestId);
        if (kind == "replaced") await server.Repository.PrepareVfsCloudAsync("google");
        server.Requests.Clear();
        var result = await (kind == "foreign-repository" ? server.NewRepository("another") : server.Repository).AuthorizeVfsAsync(change, authorization);
        Assert.False(result.Outcome.Submitted); Assert.Empty(server.Requests); Assert.Empty(server.Writes);
    }

    [Theory]
    [InlineData("account")]
    [InlineData("uri")]
    [InlineData("id")]
    [InlineData("state")]
    public async Task ReauthorizationRemainsBoundToOriginalProfileAndAccount(string changed)
    {
        using var server = new CloudServer(); server.Seed(); var original = server.Profile!;
        var request = await server.Repository.PrepareVfsCloudAsync("google", original);
        using var authorization = Authorization(request, changed == "account" ? "another" : "sample");
        if (changed == "uri") server.Profile = original with { Uri = "google://different" };
        if (changed == "id") server.Profile = original with { Id = "different" };
        if (changed == "state") server.Profile = original with { State = FileVfsState.Unknown };
        var result = await server.Repository.AuthorizeVfsAsync(Change(server, original), authorization);
        Assert.False(result.Outcome.Submitted); Assert.Empty(server.Writes);
    }

    [Fact]
    public async Task ReauthorizationSendsOriginalOpaqueIdAndOnlyCredentialFields()
    {
        using var server = new CloudServer(); server.Seed(); var original = server.Profile!;
        var request = await server.Repository.PrepareVfsCloudAsync("google", original);
        using var authorization = Authorization(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.AuthorizeVfsAsync(Change(server, original), authorization)).Outcome.Status);
        Assert.All(server.Writes, row => { Assert.Equal("set", row["method"]); Assert.Equal(original.Id, row["id"]);
            Assert.False(row.ContainsKey("alias")); Assert.False(row.ContainsKey("protocol")); Assert.False(row.ContainsKey("hostname")); });
    }

    [Theory]
    [InlineData("connection-lost", 1)]
    [InlineData("profile-lost", 2)]
    [InlineData("profile-rejected", 2)]
    [InlineData("readback", 2)]
    public async Task UnknownStepsDoNotReplayOrPersistCredentials(string failure, int count)
    {
        using var server = new CloudServer(); var request = await server.Repository.PrepareVfsCloudAsync("google");
        server.Failure = failure; using var authorization = Authorization(request); var change = Change(server);
        var result = await server.Repository.AuthorizeVfsAsync(change, authorization);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status); Assert.Equal(count, server.Writes.Count);
        Assert.Equal(failure == "profile-rejected" || failure == "profile-lost" ? FileVfsNotice.Partial : FileVfsNotice.None, result.Notice);
        Assert.DoesNotContain("synthetic-access", JsonSerializer.Serialize(await server.Repository.GetVfsOperationsAsync()));
        server.Failure = null;
        var recovered = await server.NewRepository().ReviewVfsAsync(change.RequestId);
        Assert.Equal(failure == "readback" ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, recovered!.Outcome.Status);
        var another = await server.Repository.PrepareVfsCloudAsync("google"); using var anotherAuthorization = Authorization(another);
        var next = await server.Repository.AuthorizeVfsAsync(Change(server) with { CloudIdentity = new("google", "Different alias", "sample") }, anotherAuthorization);
        Assert.False(next.Outcome.Submitted); Assert.Equal(count, server.Writes.Count);
    }

    [Theory]
    [InlineData("permission")]
    [InlineData("protocol")]
    [InlineData("duplicate")]
    [InlineData("changed-permission")]
    public async Task FreshAccessProtocolAndInventoryAreRequired(string failure)
    {
        using var server = new CloudServer(); var request = await server.Repository.PrepareVfsCloudAsync("google");
        server.Failure = failure; if (failure == "duplicate") server.Seed();
        using var authorization = Authorization(request);
        var result = await server.Repository.AuthorizeVfsAsync(Change(server), authorization);
        Assert.False(result.Outcome.Submitted); Assert.Empty(server.Writes);
    }

    [Fact]
    public async Task ExplicitIdentityRejectionNeverForcesAndDisposesAuthorizationReferences()
    {
        using var server = new CloudServer(); var request = await server.Repository.PrepareVfsCloudAsync("google");
        var authorization = Authorization(request); server.Failure = "identity";
        var result = await server.Repository.AuthorizeVfsAsync(Change(server), authorization);
        Assert.Equal(FileVfsNotice.IdentityWarning, result.Notice); Assert.Single(server.Writes);
        Assert.Equal("false", server.Writes[0]["force"]); Assert.Empty(await server.Repository.GetVfsOperationsAsync());
        authorization.Dispose(); Assert.Empty(authorization.AccessToken); Assert.Null(authorization.RefreshToken); Assert.Null(authorization.ClientId);
    }

    [Theory]
    [InlineData("get")]
    [InlineData("form")]
    [InlineData("json")]
    [InlineData("data")]
    public async Task RealLoopbackCallbackAcceptsDocumentedEnvelopesAndCloses(string format)
    {
        var request = LocalRequest(); using var session = new FileVfsCloudSession(request, "Complete", "Failed");
        using var client = new HttpClient();
        var query = Query(session.LoginUri); var callback = query["callback"];
        Assert.Equal(session.CallbackUri.AbsoluteUri, query["host"]); Assert.StartsWith("_lanstash_", callback);
        var fields = new Dictionary<string, string> { ["callback"] = callback, ["account"] = "sample+中文", ["access_token"] = "synthetic-access", ["expires_in"] = "3600" };
        HttpResponseMessage response;
        if (format == "get") response = await client.GetAsync(session.CallbackUri + "?" + await new FormUrlEncodedContent(fields).ReadAsStringAsync());
        else
        {
            HttpContent content = format switch
            {
                "json" => new StringContent(JsonSerializer.Serialize(fields), Encoding.UTF8, "application/json"),
                "data" => new FormUrlEncodedContent(new Dictionary<string, string> { ["data"] = JsonSerializer.Serialize(fields) }),
                _ => new FormUrlEncodedContent(fields),
            };
            response = await client.PostAsync(session.CallbackUri, content);
        }
        using (response)
        {
            Assert.Equal(HttpStatusCode.OK, response.StatusCode); Assert.True(response.Headers.CacheControl!.NoStore);
            var html = await response.Content.ReadAsStringAsync(); Assert.DoesNotContain("synthetic-access", html); Assert.Contains("history.replaceState", html);
        }
        using var result = await session.Completion.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(request.RequestId, result.RequestId); Assert.Equal("sample+中文", result.Account); Assert.Equal(3600, result.ExpiresIn);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.GetAsync(session.CallbackUri));
    }

    [Theory]
    [InlineData("host")]
    [InlineData("path")]
    [InlineData("callback")]
    [InlineData("missing")]
    public async Task UnrelatedCallbackCannotCompleteAttempt(string wrong)
    {
        using var session = new FileVfsCloudSession(LocalRequest(), "Complete", "Failed"); using var client = new HttpClient();
        var fields = new Dictionary<string, string> { ["callback"] = wrong == "callback" ? "wrong" : Query(session.LoginUri)["callback"], ["account"] = "sample", ["access_token"] = "synthetic" };
        if (wrong == "missing") fields.Remove("access_token");
        using var message = new HttpRequestMessage(HttpMethod.Post, wrong == "path" ? new Uri(session.CallbackUri, "/wrong") : session.CallbackUri) { Content = new FormUrlEncodedContent(fields) };
        if (wrong == "host") message.Headers.Host = "localhost:" + session.CallbackUri.Port;
        using var response = await client.SendAsync(message); Assert.False(response.IsSuccessStatusCode); Assert.False(session.Completion.IsCompleted);
        session.Dispose(); await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await session.Completion);
    }

    [Fact]
    public async Task TimeoutClosesListenerAndPartialTcpReadsAreHandled()
    {
        using (var expired = new FileVfsCloudSession(LocalRequest(), "Complete", "Failed", TimeSpan.FromMilliseconds(30)))
            await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await expired.Completion.WaitAsync(TimeSpan.FromSeconds(3)));
        using var session = new FileVfsCloudSession(LocalRequest(), "Complete", "Failed");
        using var tcp = new TcpClient(); await tcp.ConnectAsync(IPAddress.Loopback, session.CallbackUri.Port); using var stream = tcp.GetStream();
        var query = "callback=" + Query(session.LoginUri)["callback"] + "&account=sample&access_token=synthetic";
        var raw = Encoding.ASCII.GetBytes($"GET {session.CallbackUri.AbsolutePath}?{query} HTTP/1.1\r\nHost: {session.CallbackUri.Authority}\r\n\r\n");
        await stream.WriteAsync(raw.AsMemory(0, 8)); Assert.False(session.Completion.IsCompleted);
        await stream.WriteAsync(raw.AsMemory(8)); using var result = await session.Completion.WaitAsync(TimeSpan.FromSeconds(3)); Assert.Equal("sample", result.Account);
    }

    [Theory]
    [InlineData("GET //external/path HTTP/1.1\r\nHost: h\r\n\r\n")]
    [InlineData("GET /path#fragment HTTP/1.1\r\nHost: h\r\n\r\n")]
    [InlineData("GET /path HTTP/1.1\r\nHost: h\r\nHost: h\r\n\r\n")]
    [InlineData("POST /path HTTP/1.1\r\nHost: h\r\n\r\n")]
    [InlineData("POST /path HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n")]
    [InlineData("POST /path HTTP/1.1\r\nHost: h\r\nContent-Length: -1\r\n\r\n")]
    [InlineData("GET /path HTTP/1.1\r\nHost: h\r\n\r\nextra")]
    public void MalformedHttpFramingIsRejected(string request) => Assert.Throws<InvalidDataException>(() => FileVfsCloudCallback.Decode(Encoding.UTF8.GetBytes(request)));

    [Theory]
    [InlineData("{\"callback\":\"c\",\"account\":\"a\",\"access_token\":\"s\",\"expires_in\":true}")]
    [InlineData("{\"callback\":\"c\",\"account\":\"a\",\"access_token\":\"s\",\"expires_in\":-1}")]
    [InlineData("{\"callback\":\"c\",\"account\":\"a\",\"access_token\":\"s\",\"expires_in\":1.2}")]
    [InlineData("{\"callback\":\"c\",\"account\":\"a\",\"access_token\":\"s\",\"access_token\":\"x\"}")]
    public void InvalidJsonTypesAndDuplicateCredentialsAreRejected(string json) =>
        Assert.Throws<InvalidDataException>(() => new FileVfsCloudCallback.Request("h", "/", "", "application/json", Encoding.UTF8.GetBytes(json)).Authorization(LocalRequest(), "c"));

    [Theory]
    [InlineData("callback=c&callback=c&account=a&access_token=s")]
    [InlineData("callback=c&account=a&access_token=%FF")]
    [InlineData("callback=c&account=a&access_token=%zz")]
    public void AmbiguousOrMalformedFormIsRejected(string query) =>
        Assert.Throws<InvalidDataException>(() => new FileVfsCloudCallback.Request("h", "/", query, null, []).Authorization(LocalRequest(), "c"));

    [Fact]
    public void CallbackLimitsAndConflictingEnvelopesAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => FileVfsCloudCallback.Decode(new byte[131073]));
        Assert.Throws<InvalidDataException>(() => FileVfsCloudCallback.Decode(Encoding.ASCII.GetBytes(new string('a', 16385))));
        var body = Encoding.UTF8.GetBytes("{\"callback\":\"c\",\"account\":\"a\",\"access_token\":\"synthetic\"}");
        Assert.Throws<InvalidDataException>(() => new FileVfsCloudCallback.Request("h", "/", "callback=c", "application/json", body).Authorization(LocalRequest(), "c"));
        Assert.Throws<InvalidDataException>(() => new FileVfsCloudSession(LocalRequest() with { LoginUri = new("https://untrusted.invalid/") }, "Complete", "Failed"));
        Assert.Throws<InvalidDataException>(() => new FileVfsCloudSession(LocalRequest() with { ExpiresAt = DateTimeOffset.UtcNow.AddSeconds(-1) }, "Complete", "Failed"));
    }

    [Fact]
    public async Task ViewModelRequiresExplicitSaveAndDropsCancelledLateAuthorization()
    {
        using var server = new CloudServer(); using var model = new FileVfsViewModel(server.Repository); await model.LoadAsync(); model.NewCloud(); model.UpdateCloudAlias("Cloud");
        using var client = new HttpClient();
        await model.AuthorizeCloudAsync(async uri => { var q = Query(uri); using var response = await client.PostAsync(q["host"], new FormUrlEncodedContent(new Dictionary<string, string>
            { ["callback"] = q["callback"], ["account"] = "sample", ["access_token"] = "synthetic-access" })); return response.IsSuccessStatusCode; });
        Assert.True(model.CanSave); Assert.Empty(server.Writes); Assert.Equal("sample", model.CloudAccount);
        await model.SaveAsync(null); Assert.Equal(2, server.Writes.Count); Assert.False(model.HasCloudAuthorization);
        model.NewCloud(); var launched = new TaskCompletionSource<Uri>(); var wait = new TaskCompletionSource<bool>();
        var task = model.AuthorizeCloudAsync(uri => { launched.SetResult(uri); return wait.Task; }); var login = await launched.Task;
        model.CancelCloud(); wait.SetResult(true); await task;
        Assert.False(model.CanSave); Assert.False(model.IsBusy); Assert.False(model.HasCloudAuthorization);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.GetAsync(Query(login)["host"]));
    }

    [Fact]
    public async Task RefreshFailureClearsAuthorizedAccountAndShowsLoadRecovery()
    {
        using var server = new CloudServer(); using var model = new FileVfsViewModel(server.Repository);
        await model.LoadAsync(); model.NewCloud(); model.UpdateCloudAlias("Cloud"); using var client = new HttpClient();
        await model.AuthorizeCloudAsync(async uri =>
        {
            var query = Query(uri); using var response = await client.PostAsync(query["host"], new FormUrlEncodedContent(new Dictionary<string, string>
            { ["callback"] = query["callback"], ["account"] = "sample", ["access_token"] = "synthetic" })); return response.IsSuccessStatusCode;
        });
        Assert.True(model.HasCloudAuthorization); server.Failure = "load"; await model.LoadAsync();
        Assert.False(model.HasCloudAuthorization); Assert.False(model.CanSave); Assert.Equal("VfsLoadFailed", model.MessageKey); Assert.Empty(server.Writes);
    }

    private static FileVfsCloudRequest LocalRequest() => new(Guid.NewGuid(), Guid.NewGuid(), "google", new("https://synooauth.synology.com/FileStation/Cloud/login.php?major=7&minor=2&type=google"), DateTimeOffset.UtcNow.AddMinutes(10));
    private static FileVfsCloudAuthorization Authorization(FileVfsCloudRequest request, string account = "sample") => new(request.RequestId, request.ProfileId, request.Protocol, account, "synthetic-access", "synthetic-client", "synthetic-refresh", 3600);
    private static FileVfsChange Change(CloudServer server, FileVfsProfile? profile = null) => new(server.Repository.ProfileId, Guid.NewGuid(), profile is null ? FileVfsAction.CreateCloud : FileVfsAction.Reauthorize,
        profile, Confirmed: true, CloudIdentity: new("google", profile?.Alias ?? "Cloud", "sample"));
    internal static Dictionary<string, string> Query(Uri uri) => uri.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => Uri.UnescapeDataString(p[0]), p => Uri.UnescapeDataString(p[1].Replace('+', ' ')));

    private sealed class CloudServer(string format = "FORM") : HttpMessageHandler
    {
        private readonly Guid _id = Guid.NewGuid(); private DsmApiClient? _api; private DsmRepository? _repository; private int _access;
        public DsmRepository Repository => _repository ??= NewRepository();
        public FileVfsProfile? Profile;
        public string? Failure;
        public List<Dictionary<string, string>> Requests { get; } = [];
        public List<Dictionary<string, string>> Writes { get; } = [];
        public DsmRepository NewRepository(string user = "sample") => new(new(_id, "Synthetic", "nas.invalid", 5001, user), new(_id, "synthetic-sid", "synthetic-token", null),
            _api ??= new(new HttpClient(this)), new[] { "SYNO.Core.System", "SYNO.Core.Desktop.Initdata", "SYNO.FileStation.VFS.Protocol", "SYNO.FileStation.VFS.Profile", "SYNO.FileStation.VFS.Connection" }
                .Select(name => new ApiCapability(name, "entry.cgi", 1, 9, format)).ToDictionary(c => c.Name));
        public void Seed() => Profile = new(_id, "opaque-cloud", "google", "Cloud", "google://opaque-root", "", null, "Cloud", "sample", null, FileVfsState.Connected);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var values = request.Method == HttpMethod.Get ? Query(request.RequestUri!) : Query(new Uri("https://synthetic.invalid/?" + await request.Content!.ReadAsStringAsync(cancellationToken)));
            Requests.Add(values); var api = values["api"]; var method = values["method"]; JsonObject data;
            string Scalar(string key) => format == "JSON" ? JsonSerializer.Deserialize<string>(values[key])! : values[key];
            if (api == "SYNO.Core.System") data = new() { ["firmware_ver"] = "DSM 7.2.1" };
            else if (api == "SYNO.Core.Desktop.Initdata")
            { _access++; data = new() { ["Session"] = new JsonObject { ["isLogined"] = true, ["is_admin"] = false }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = Failure != "permission" && !(Failure == "changed-permission" && _access > 2) } }; }
            else if (api.EndsWith("Protocol", StringComparison.Ordinal)) data = new() { ["protocols"] = Failure == "protocol" ? new JsonArray() : new JsonArray(new JsonObject { ["protocol"] = "google", ["name"] = "Cloud", ["default_port"] = 0, ["has_server"] = false }) };
            else if (method == "list")
            {
                if (Failure == "load" || Failure == "readback" && Writes.Count > 0) throw new HttpRequestException();
                var rows = new JsonArray(); if (Profile is { } p) rows.Add(new JsonObject { ["id"] = p.Id, ["protocol"] = p.Protocol, ["protocol_name"] = p.ProtocolName, ["uri"] = p.Uri, ["hostname"] = p.Hostname, ["port"] = p.Port,
                    ["alias"] = p.Alias, ["account"] = p.Account, ["codepage"] = p.Codepage, ["connect_status"] = p.State == FileVfsState.Connected ? 1 : p.State == FileVfsState.Disconnected ? 0 : 7 });
                data = new() { ["profiles"] = rows, ["total"] = rows.Count };
            }
            else
            {
                Writes.Add(values);
                if (Failure == "identity" || Failure == "profile-rejected" && api.EndsWith("Profile", StringComparison.Ordinal)) return Reply(new() { ["success"] = false, ["error"] = new JsonObject { ["code"] = Failure == "identity" ? 2107 : 105 } });
                if (Profile is null) { Seed(); Profile = Profile! with { Account = Scalar("account"), Alias = Scalar("alias") }; }
                if (Failure == "connection-lost" && api.EndsWith("Connection", StringComparison.Ordinal) || Failure == "profile-lost" && api.EndsWith("Profile", StringComparison.Ordinal)) throw new HttpRequestException();
                data = new();
            }
            return Reply(new() { ["success"] = true, ["data"] = data });
        }
        private static HttpResponseMessage Reply(JsonObject value) => new(HttpStatusCode.OK) { Content = new StringContent(value.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
