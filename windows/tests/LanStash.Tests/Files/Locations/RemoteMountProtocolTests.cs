using System.Net;
using System.Text;
using System.Text.Json;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class RemoteMountProtocolTests
{
    [Theory]
    [InlineData("FORM", FileRemoteProtocol.Cifs)]
    [InlineData("JSON", FileRemoteProtocol.Cifs)]
    [InlineData("FORM", FileRemoteProtocol.Nfs)]
    [InlineData("JSON", FileRemoteProtocol.Nfs)]
    public async Task OfficialConnectFieldsHaveExactTypesAndNoAliasParameters(string format, FileRemoteProtocol protocol)
    {
        var draft = Draft(protocol);
        Assert.True(RemoteMountProtocol.TryBuildConnect(draft, out var parameters, out var issue)); Assert.Equal(RemoteMountInputIssue.None, issue);
        using var handler = new Handler(); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        var result = await client.SendFileLocationMutationAsync(Profile, Session, Capability("SYNO.FileStation.Mount", format),
            new(FileLocationMutationKind.CreateRemoteMount, "mount_remote", parameters));
        Assert.Equal(FileLocationMutationTransportStatus.ResponseReceived, result.Status);
        var form = Assert.Single(handler.Calls);
        Assert.Equal("1", form["version"]); Assert.Equal("mount_remote", form["method"]);
        Assert.Equal("true", form["user_set"]); Assert.Equal("false", form["auto_mount"]);
        string Value(string name) => format == "JSON" ? JsonSerializer.Deserialize<string>(form[name])! : form[name];
        Assert.Equal(protocol == FileRemoteProtocol.Cifs ? "CIFS" : "NFS", Value("mount_type"));
        Assert.Equal(protocol == FileRemoteProtocol.Cifs ? "//server.invalid/share/folder" : "server.invalid:/share/folder", Value("server_ip"));
        Assert.Equal("/share/mount", Value("mount_point"));
        if (protocol == FileRemoteProtocol.Cifs) { Assert.Equal("DOMAIN\\user", Value("account")); Assert.Equal(" synthetic secret ", Value("passwd")); }
        else { Assert.Equal("3", Value("nfs_version")); Assert.Equal("tcp", Value("protocol")); }
        Assert.DoesNotContain("read_only", form.Keys); Assert.DoesNotContain("domain", form.Keys); Assert.DoesNotContain("username", form.Keys);
        Assert.DoesNotContain("remote_path", form.Keys); Assert.DoesNotContain("src_folder", form.Keys); Assert.DoesNotContain("dst_folder", form.Keys);
        Assert.DoesNotContain("synthetic secret", draft.ToString());
        AssertFixture(form, protocol == FileRemoteProtocol.Cifs ? "mount-cifs" : "mount-nfs", format);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task DisconnectUsesMountListAndArrayWithoutDirectoryDeletion(string format)
    {
        using var handler = new Handler(); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        var result = await client.SendFileLocationMutationAsync(Profile, Session, Capability("SYNO.FileStation.Mount.List", format),
            new(FileLocationMutationKind.DeleteRemoteMount, "unmount", new Dictionary<string, string> { ["mount_point"] = "[\"/share/mount\"]" }));
        Assert.Equal(FileLocationMutationTransportStatus.ResponseReceived, result.Status);
        var form = Assert.Single(handler.Calls);
        Assert.Equal("SYNO.FileStation.Mount.List", form["api"]); Assert.Equal("unmount", form["method"]);
        Assert.Equal(new[] { "/share/mount" }, JsonSerializer.Deserialize<string[]>(form["mount_point"]));
        Assert.DoesNotContain("path", form.Keys); Assert.DoesNotContain("folder_path", form.Keys);
        AssertFixture(form, "unmount-remote", format);
    }

    [Theory]
    [InlineData("create")]
    [InlineData("update")]
    [InlineData("delete")]
    public async Task OldGuessedMethodsRemainRejected(string method)
    {
        using var handler = new Handler(); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        Assert.True(RemoteMountProtocol.TryBuildConnect(Draft(FileRemoteProtocol.Cifs), out var parameters, out _));
        var result = await client.SendFileLocationMutationAsync(Profile, Session, Capability("SYNO.FileStation.Mount", "JSON"),
            new(FileLocationMutationKind.CreateRemoteMount, method, parameters));
        Assert.Equal(FileLocationMutationTransportStatus.Unsupported, result.Status); Assert.Empty(handler.Calls);
    }

    [Theory]
    [InlineData("read_only")]
    [InlineData("_sid")]
    [InlineData("domain")]
    [InlineData("username")]
    public async Task ExtraParametersCannotBeInjected(string key)
    {
        using var handler = new Handler(); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        Assert.True(RemoteMountProtocol.TryBuildConnect(Draft(FileRemoteProtocol.Cifs), out var parameters, out _));
        var changed = parameters.ToDictionary(pair => pair.Key, pair => pair.Value); changed[key] = "unexpected";
        var result = await client.SendFileLocationMutationAsync(Profile, Session, Capability("SYNO.FileStation.Mount", "JSON"),
            new(FileLocationMutationKind.CreateRemoteMount, "mount_remote", changed));
        Assert.Equal(FileLocationMutationTransportStatus.Unsupported, result.Status); Assert.Empty(handler.Calls);
    }

    [Theory]
    [InlineData("[\"/share/../mount\"]")]
    [InlineData("[\"/share/mount\",\"/share/mount\"]")]
    [InlineData("[]")]
    [InlineData("\"/share/mount\"")]
    public async Task InvalidDisconnectTargetsSendNothing(string paths)
    {
        using var handler = new Handler(); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        var result = await client.SendFileLocationMutationAsync(Profile, Session, Capability("SYNO.FileStation.Mount.List", "FORM"),
            new(FileLocationMutationKind.DeleteRemoteMount, "unmount", new Dictionary<string, string> { ["mount_point"] = paths }));
        Assert.Equal(FileLocationMutationTransportStatus.Unsupported, result.Status); Assert.Empty(handler.Calls);
    }

    [Fact]
    public void ReadOnlyGuaranteeAndNfs4UdpCannotBeSilentlyIgnored()
    {
        var readOnly = new RemoteMountDraft("server.invalid", "share", "/share/mount", null, null, null, true, FileRemoteProtocol.Cifs);
        Assert.False(RemoteMountProtocol.TryBuildConnect(readOnly, out _, out var issue)); Assert.Equal(RemoteMountInputIssue.ReadOnlyNotSupported, issue);
        var invalidNfs = new RemoteMountDraft("server.invalid", "/export", "/share/mount", null, null, null, false, FileRemoteProtocol.Nfs,
            nfsVersion: RemoteMountNfsVersion.V4, nfsTransport: RemoteMountNfsTransport.Udp);
        Assert.False(RemoteMountProtocol.TryBuildConnect(invalidNfs, out _, out issue)); Assert.Equal(RemoteMountInputIssue.InvalidNfsOptions, issue);
    }

    [Theory]
    [InlineData(RemoteMountNfsVersion.V3, RemoteMountNfsTransport.Udp, "3", "udp")]
    [InlineData(RemoteMountNfsVersion.V4, RemoteMountNfsTransport.Tcp, "4", "tcp")]
    public void NfsOptionsUseRecordedValues(RemoteMountNfsVersion version, RemoteMountNfsTransport transport, string expectedVersion, string expectedTransport)
    {
        var draft = new RemoteMountDraft("server.invalid", "share/folder", "/share/mount", null, null, null, false, FileRemoteProtocol.Nfs,
            nfsVersion: version, nfsTransport: transport);
        Assert.True(RemoteMountProtocol.TryBuildConnect(draft, out var values, out _));
        Assert.Equal(expectedVersion, values["nfs_version"]); Assert.Equal(expectedTransport, values["protocol"]);
    }

    [Theory]
    [InlineData("/share/../secret")]
    [InlineData("//different/share")]
    [InlineData("share\n")]
    public void UnsafeRemotePathsAreRejected(string path) =>
        Assert.False(RemoteMountProtocol.TryBuildConnect(new("server.invalid", path, "/share/mount", null, null, null, false, FileRemoteProtocol.Cifs), out _, out _));

    [Fact]
    public async Task InventoryReadsStrictRowsAndRetainsUnknownAutomaticFlag()
    {
        using var handler = new Handler("""{"success":true,"data":{"mountConfig":{"enable_remote_mount":true},"remoteList":[{"type":"CIFS","source":"\\\\SERVER.invalid\\share","mount_point":"/share/mount"}]}}""");
        using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        var repository = new DsmRepository(Profile, Session, client, new Dictionary<string, ApiCapability> { ["SYNO.FileStation.Mount.List"] = Capability("SYNO.FileStation.Mount.List", "JSON") });
        var snapshot = await repository.LoadRemoteMountInventoryAsync();
        Assert.True(snapshot.RemoteMountingEnabled); var item = Assert.Single(snapshot.Items);
        Assert.Equal("//server.invalid/share", item.RemoteSource); Assert.Equal(FileRemoteProtocol.Cifs, item.Protocol); Assert.Null(item.AutomaticMount);
        Assert.Equal("get", Assert.Single(handler.Calls)["method"]);
        AssertFixture(handler.Calls.Single(), "list-remote-mounts", "JSON");
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"mountConfig\":{\"enable_remote_mount\":\"true\"},\"remoteList\":[]}")]
    [InlineData("{\"mountConfig\":{\"enable_remote_mount\":true},\"remoteList\":[{}]}")]
    [InlineData("{\"mountConfig\":{\"enable_remote_mount\":true},\"remoteList\":[{\"type\":\"CIFS\",\"source\":\"//server.invalid/share\",\"mount_point\":\"/share/mount\",\"auto_mount\":\"false\"}]}")]
    [InlineData("{\"mountConfig\":{\"enable_remote_mount\":true},\"remoteList\":[{\"type\":\"CIFS\",\"source\":\"//server.invalid/share\",\"mount_point\":\"/share/mount\"},{\"type\":\"CIFS\",\"source\":\"//server.invalid/other\",\"mount_point\":\"/share/mount\"}]}")]
    public async Task MissingOrMalformedInventoryIsNotEmptySuccess(string data)
    {
        using var handler = new Handler("{\"success\":true,\"data\":" + data + "}"); using var http = new HttpClient(handler); var client = new DsmApiClient(http);
        var repository = new DsmRepository(Profile, Session, client, new Dictionary<string, ApiCapability> { ["SYNO.FileStation.Mount.List"] = Capability("SYNO.FileStation.Mount.List", "JSON") });
        await Assert.ThrowsAsync<InvalidDataException>(() => repository.LoadRemoteMountInventoryAsync());
    }

    private static RemoteMountDraft Draft(FileRemoteProtocol protocol) => new("server.invalid", "share/folder", "/share/mount",
        protocol == FileRemoteProtocol.Cifs ? "user" : null, protocol == FileRemoteProtocol.Cifs ? " synthetic secret " : null,
        protocol == FileRemoteProtocol.Cifs ? "DOMAIN" : null, false, protocol);

    private static void AssertFixture(Dictionary<string, string> actual, string operation, string format)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, $"contracts/request-fixtures/file-station/{operation}/synthetic-location/request.json");
            if (!File.Exists(path)) continue;
            using var sample = JsonDocument.Parse(File.ReadAllText(path)); var root = sample.RootElement;
            Assert.Equal(root.GetProperty("api").GetProperty("name").GetString(), actual["api"]);
            Assert.Equal(root.GetProperty("api").GetProperty("method").GetString(), actual["method"]);
            foreach (var parameter in root.GetProperty("parameters").EnumerateArray())
            {
                var name = parameter.GetProperty("name").GetString()!; Assert.Contains(name, actual.Keys);
                if (parameter.TryGetProperty("redacted", out var redacted) && redacted.GetBoolean()) continue;
                var expected = parameter.GetProperty("encodedValue").GetString()!.Replace("<synthetic-mount-point>", "/share/mount", StringComparison.Ordinal);
                if (format == "JSON" && parameter.GetProperty("valueType").GetString() == "string") expected = JsonSerializer.Serialize(expected);
                Assert.Equal(expected, actual[name]);
            }
            return;
        }
        throw new FileNotFoundException("缺少挂载请求样例。");
    }
    private static readonly NasProfile Profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
    private static DsmSession Session => new(Profile.Id, "synthetic-sid", "synthetic-token", null);
    private static ApiCapability Capability(string name, string format) => new(name, "entry.cgi", 1, 1, format);
    private sealed class Handler(string response = "{\"success\":true,\"data\":{}}") : HttpMessageHandler
    {
        public List<Dictionary<string, string>> Calls { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
            Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(request, out var id, out _)); Assert.Equal(Profile.Id, id);
            var body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Calls.Add(body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])));
            return new(HttpStatusCode.OK) { Content = new StringContent(response, Encoding.UTF8, "application/json") };
        }
    }
}
