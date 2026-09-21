using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileStationPermissionTests
{
    [Theory]
    [InlineData("{\"is_acl_mode\":true,\"acl\":{\"read\":true,\"write\":true,\"del\":true}}", true, true)]
    [InlineData("{\"adv_right\":{\"download\":true,\"upload\":true,\"delete\":true}}", true, true)]
    [InlineData("{\"is_acl_mode\":true,\"acl\":{\"write\":false,\"del\":false},\"adv_right\":{\"write\":true,\"delete\":true},\"write\":true,\"delete\":true}", false, false)]
    [InlineData("{\"is_acl_mode\":false,\"acl\":{\"write\":true,\"del\":true},\"adv_right\":{\"write\":false,\"delete\":false}}", false, false)]
    [InlineData("{\"is_acl_mode\":true,\"acl\":{\"read\":true},\"write\":true,\"delete\":true}", false, false)]
    [InlineData("{\"write\":true,\"delete\":false}", true, false)]
    [InlineData("{}", false, false)]
    public async Task RealBrowseTransportPreservesRecordedPermissionMeaning(string permission, bool write, bool delete)
    {
        using var http = new HttpClient(new Handler(permission));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        var repository = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(http),
            new Dictionary<string, ApiCapability> { ["SYNO.FileStation.List"] = new("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM") });
        var page = await repository.ListFilesAsync("/synthetic", 0, 10);
        var item = Assert.Single(page.Items);
        Assert.Equal(write, item.CanWrite); Assert.Equal(delete, item.CanDelete);
    }

    [Fact]
    public void ExplicitDenialsHavePriorityOverPositiveAliases()
    {
        var permission = FileStationPermissions.Parse(JsonNode.Parse("""
            {"adv_right":{"read":false,"download":true,"write":false,"upload":true,"delete":false}}
            """));
        Assert.False(permission.Read); Assert.False(permission.Write); Assert.False(permission.Delete);
        var acl = FileStationPermissions.Parse(JsonNode.Parse("""
            {"is_acl_mode":true,"acl":{"read":false},"adv_right":{"read":true,"write":true,"delete":false}}
            """));
        Assert.False(acl.Read); Assert.True(acl.Write); Assert.False(acl.Delete);
    }

    [Theory]
    [InlineData("[]")]
    [InlineData("{\"is_acl_mode\":\"true\"}")]
    [InlineData("{\"is_acl_mode\":true,\"acl\":{\"write\":\"true\"}}")]
    [InlineData("{\"adv_right\":{\"upload\":1}}")]
    [InlineData("{\"write\":\"true\"}")]
    public void InvalidTypesDoNotGrantPermissions(string raw) =>
        Assert.Throws<InvalidDataException>(() => FileStationPermissions.Parse(JsonNode.Parse(raw)));

    private sealed class Handler(string permission) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
            var body = await request.Content!.ReadAsStringAsync(token);
            Assert.Contains("method=list", body); Assert.Contains("version=2", body);
            var data = new JsonObject { ["total"] = 1, ["offset"] = 0, ["files"] = new JsonArray(new JsonObject
            {
                ["path"] = "/synthetic/item.txt", ["name"] = "item.txt", ["isdir"] = false,
                ["additional"] = new JsonObject { ["size"] = 4, ["perm"] = JsonNode.Parse(permission) }
            }) };
            return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
    }
}
