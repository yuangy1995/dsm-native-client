using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FilePresenceTests
{
    private const string Path = "/synthetic & space/item.txt";

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task MissingRequiresExactPerItem408AndUsesFixedReadContract(string format)
    {
        using var fixture = new Fixture(format, new() { ["files"] = new JsonArray(new JsonObject { ["path"] = Path, ["code"] = 408 }) });
        Assert.Equal(FilePresence.Missing, await fixture.Repository.ProbeFilePresenceAsync(Path));
        var call = Assert.Single(fixture.Calls);
        Assert.Equal("SYNO.FileStation.List", call["api"]); Assert.Equal("2", call["version"]); Assert.Equal("getinfo", call["method"]);
        Assert.Equal(new[] { Path }, JsonSerializer.Deserialize<string[]>(call["path"]));
        Assert.False(call.ContainsKey("additional"));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ExistingFilesAndDirectoriesAreNotRemovalCandidates(bool directory)
    {
        using var fixture = new Fixture("JSON", new() { ["files"] = new JsonArray(new JsonObject
            { ["path"] = Path, ["name"] = "item.txt", ["isdir"] = directory }) });
        Assert.Equal(FilePresence.Present, await fixture.Repository.ProbeFilePresenceAsync(Path));
    }

    [Theory]
    [InlineData(105, false)]
    [InlineData(106, true)]
    [InlineData(107, true)]
    [InlineData(119, true)]
    [InlineData(407, false)]
    [InlineData(411, false)]
    public async Task RejectedLookupIsNotAbsence(int code, bool authentication)
    {
        using var fixture = new Fixture("FORM", new() { ["files"] = new JsonArray(new JsonObject { ["path"] = Path, ["code"] = code }) });
        var error = await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ProbeFilePresenceAsync(Path));
        Assert.Equal(code, error.Code); Assert.Equal(authentication, error.AuthenticationFailure);
    }

    [Theory]
    [InlineData("{\"files\":[]}")]
    [InlineData("{}")]
    [InlineData("{\"files\":[{\"path\":\"/other/item.txt\",\"code\":408}]}")]
    [InlineData("{\"files\":[{\"path\":\"/synthetic & space/item.txt\",\"code\":\"408\"}]}")]
    [InlineData("{\"files\":[{\"path\":\"/synthetic & space/item.txt\",\"code\":0}]}")]
    [InlineData("{\"files\":[{\"path\":\"/synthetic & space/item.txt\",\"code\":408},{\"path\":\"/other\",\"code\":408}]}")]
    public async Task MalformedOrIncompleteLookupCannotAuthorizeRemoval(string data)
    {
        using var fixture = new Fixture("JSON", JsonNode.Parse(data)!.AsObject());
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Repository.ProbeFilePresenceAsync(Path));
    }

    [Fact]
    public async Task UnsupportedVersionAndInvalidPathPerformNoHttpCalls()
    {
        using var fixture = new Fixture("FORM", new(), minimumVersion: 3);
        await Assert.ThrowsAsync<NotSupportedException>(() => fixture.Repository.ProbeFilePresenceAsync(Path));
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Repository.ProbeFilePresenceAsync("/share/../target"));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task MetadataUsesRecordedFieldsAndPreservesBoundaryInformation()
    {
        using var fixture = new Fixture("JSON", new() { ["files"] = new JsonArray(new JsonObject
        {
            ["path"] = Path, ["name"] = "item.txt", ["isdir"] = false,
            ["additional"] = new JsonObject { ["size"] = 0, ["time"] = new JsonObject { ["mtime"] = 123 },
                ["type"] = "file", ["mount_point_type"] = "normal",
                ["perm"] = new JsonObject { ["is_acl_mode"] = true, ["acl"] = new JsonObject { ["write"] = true, ["del"] = false } } }
        }) });
        var metadata = await fixture.Repository.ReadFileMetadataAsync(Path);
        Assert.NotNull(metadata); Assert.Equal(0, metadata.Item.Size);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(123), metadata.Item.ModifiedAt);
        Assert.True(metadata.Item.CanWrite); Assert.False(metadata.Item.CanDelete);
        Assert.Equal("file", metadata.Type); Assert.Equal("normal", metadata.MountPointType);
        var fields = JsonSerializer.Deserialize<string[]>(Assert.Single(fixture.Calls)["additional"]);
        Assert.Equal(new[] { "size", "time", "perm", "type", "mount_point_type" }, fields);
    }

    [Fact]
    public async Task MissingMetadataIsNotAnEmptyFile()
    {
        using var fixture = new Fixture("FORM", new() { ["files"] = new JsonArray(new JsonObject { ["path"] = Path, ["code"] = 408 }) });
        Assert.Null(await fixture.Repository.ReadFileMetadataAsync(Path));
    }

    [Fact]
    public async Task FixedReadAlsoAllowsRecordedDetailFieldsForExistingOperationPreflights()
    {
        using var fixture = new Fixture("JSON", new() { ["files"] = new JsonArray() });
        var parameters = new Dictionary<string, string> { ["path"] = "[\"/synthetic\"]", ["additional"] = "[\"size\",\"time\",\"perm\",\"owner\"]" };
        await fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session, new("SYNO.FileStation.List", "entry.cgi", 1, 9, "JSON"), 2, "getinfo", parameters);
        Assert.Equal(parameters["additional"], Assert.Single(fixture.Calls)["additional"]);
    }

    [Theory]
    [InlineData("SYNO.FileStation.List", 3, "[\"/synthetic\"]", null)]
    [InlineData("SYNO.Other.API", 2, "[\"/synthetic\"]", null)]
    [InlineData("SYNO.FileStation.List", 2, "[]", null)]
    [InlineData("SYNO.FileStation.List", 2, "[123]", null)]
    [InlineData("SYNO.FileStation.List", 2, "[\"/share/../outside\"]", null)]
    [InlineData("SYNO.FileStation.List", 2, "[\"/synthetic\"]", "[\"volume_status\"]")]
    public async Task NewReadExceptionIsLimitedToTheRecordedContract(string api, int version, string paths, string? additional)
    {
        using var fixture = new Fixture("FORM", new());
        var parameters = new Dictionary<string, string> { ["path"] = paths };
        if (additional is not null) parameters["additional"] = additional;
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session,
            new(api, "entry.cgi", 1, 9, "FORM"), version, "getinfo", parameters));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task GlobalError408IsNotConvertedToPerItemMissing()
    {
        using var fixture = new Fixture("FORM", new(), globalError: 408);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ProbeFilePresenceAsync(Path));
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        internal readonly DsmRepository Repository;
        internal readonly NasProfile Profile;
        internal readonly DsmSession Session;
        internal readonly DsmApiClient Api;
        internal List<Dictionary<string, string>> Calls { get; } = [];
        internal Fixture(string format, JsonObject data, int minimumVersion = 1, int? globalError = null)
        {
            _http = new(new Handler(this, data, globalError));
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            Profile = profile; Session = new(profile.Id, "synthetic-sid", "synthetic-token", null); Api = new DsmApiClient(_http);
            Repository = new(profile, Session, Api,
                new Dictionary<string, ApiCapability>
                { ["SYNO.FileStation.List"] = new("SYNO.FileStation.List", "entry.cgi", minimumVersion, 9, format) });
        }
        private sealed class Handler(Fixture owner, JsonObject data, int? error) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                Assert.Equal(HttpMethod.Post, request.Method);
                var body = await request.Content!.ReadAsStringAsync(token);
                owner.Calls.Add(body.Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])));
                var response = error is not null ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = error.Value } }
                    : new JsonObject { ["success"] = true, ["data"] = data.DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
