using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

/// <summary>经过真实 Repository 与 HTTP 构造器的合成请求，不访问真实 Chat 服务。</summary>
public sealed class ChatConversationWireParityTests
{
    [Theory]
    [InlineData("FORM", "FORM")]
    [InlineData("JSON", "JSON")]
    [InlineData("JSON", "FORM")]
    [InlineData("FORM", "JSON")]
    public async Task GroupCreationEncodesEveryStageAndConfirmsMembers(string format, string memberFormat)
    {
        using var fixture = new Fixture(format, memberFormat);
        var result = await fixture.Repository.CreatePrivateGroupAsync(fixture.Group);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("group-7", result.ConfirmedConversation?.Id);
        var writes = fixture.Calls.Where(call => call.Api == "SYNO.Chat.Channel.Named").ToArray();
        Assert.Equal(new[] { "create", "join", "invite" }, writes.Select(call => call.Method));
        Assert.All(writes, call => Assert.Equal("1", call.Values["version"]));
        Assert.Equal(Encode(fixture.Group.Title, format), writes[0].Values["name"]);
        Assert.Equal(Encode("private", format), writes[0].Values["type"]);
        Assert.Equal(Encode("group-7", format), writes[1].Values["channel_id"]);
        Assert.Equal(Encode("group-7", format), writes[2].Values["channel_id"]);
        Assert.Equal(new[] { "u-2", "u-3" }, JsonSerializer.Deserialize<string[]>(writes[2].Values["user_ids"]));
        Assert.Equal("[]", writes[2].Values["channel_key_encs"]);
        var memberRead = Assert.Single(fixture.Calls, call => call.Api == "SYNO.Chat.Channel.Member");
        Assert.Equal("get", memberRead.Method);
        Assert.Equal("1", memberRead.Values["version"]);
        Assert.Equal(Encode("group-7", memberFormat), memberRead.Values["channel_id"]);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task DirectCreationKeepsArraysAndBooleanTyped(string format)
    {
        using var fixture = new Fixture(format, format);
        var result = await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var call = Assert.Single(fixture.Calls, call => call.Api == "SYNO.Chat.Channel.Anonymous");
        Assert.Equal("2", call.Values["version"]);
        Assert.Equal("initiate", call.Method);
        Assert.Equal("[\"u-2\"]", call.Values["user_ids"]);
        Assert.Equal("false", call.Values["encrypted"]);
        Assert.Equal("[]", call.Values["channel_key_encs"]);
    }

    [Theory]
    [InlineData("network", false)]
    [InlineData("timeout", false)]
    [InlineData("http", false)]
    [InlineData("network", true)]
    [InlineData("timeout", true)]
    [InlineData("http", true)]
    public async Task TransportFailureAfterSubmissionNeverCreatesAgain(string failure, bool group)
    {
        using var fixture = new Fixture("FORM", "FORM") { Failure = failure };
        var first = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        var second = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Single(fixture.Calls, call => call.Method is "create" or "initiate");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExplicitApiRejectionIsTerminalAndDoesNotReplayTheRequestId(bool group)
    {
        using var fixture = new Fixture("JSON", "JSON") { Failure = "api" };
        var first = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        var second = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        Assert.Equal(MutationResultStatus.PermissionDenied, first.Result.Status);
        Assert.False(first.Result.RequiresRefresh);
        Assert.Equal(first, second);
        Assert.Single(fixture.Calls, call => call.Method is "create" or "initiate");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfirmedRequestIdCannotCreateAgainWhenTheChannelLaterDisappears(bool group)
    {
        using var fixture = new Fixture("FORM", "FORM");
        var first = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, first.Result.Status);
        fixture.HideChannel = true;
        var calls = fixture.Calls.Count;
        var second = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group)
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct);
        Assert.Equal(first, second);
        Assert.Equal(calls, fixture.Calls.Count);
        var mismatched = group ? await fixture.Repository.CreatePrivateGroupAsync(fixture.Group with { Title = "Different" })
            : await fixture.Repository.OpenDirectConversationAsync(fixture.Direct with { UserId = "u-3" });
        Assert.Equal(MutationErrorCategory.Validation, mismatched.Result.ErrorCategory);
        Assert.Equal(calls, fixture.Calls.Count);
    }

    [Fact]
    public async Task MissingMemberFromReadbackLeavesJsonGroupPendingWithoutReplayingAnyStage()
    {
        using var fixture = new Fixture("JSON", "JSON") { MissingMember = true };
        var first = await fixture.Repository.CreatePrivateGroupAsync(fixture.Group);
        var second = await fixture.Repository.CreatePrivateGroupAsync(fixture.Group);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Equal(new[] { "create", "join", "invite" }, fixture.Calls
            .Where(call => call.Api == "SYNO.Chat.Channel.Named").Select(call => call.Method));
    }

    [Fact]
    public async Task ExistingGroupUsesIndependentMembersWhenTheSummaryOmitsThem()
    {
        using var fixture = new Fixture("JSON", "JSON") { ExistingGroup = true, SummaryMembersEmpty = true };
        var result = await fixture.Repository.CreatePrivateGroupAsync(fixture.Group);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.DoesNotContain(fixture.Calls, call => call.Api == "SYNO.Chat.Channel.Named");
        Assert.Single(fixture.Calls, call => call.Api == "SYNO.Chat.Channel.Member");
    }

    [Fact]
    public async Task ExistingGroupSummaryCannotOverrideMissingMembersFromTheAuthoritativeRead()
    {
        using var fixture = new Fixture("JSON", "JSON") { ExistingGroup = true, MissingMember = true };
        var result = await fixture.Repository.CreatePrivateGroupAsync(fixture.Group);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Single(fixture.Calls, call => call.Method == "create");
    }

    private static string Encode(string value, string format) => format == "JSON" ? JsonSerializer.Serialize(value) : value;

    private sealed record Call(string Api, string Method, Dictionary<string, string> Values);

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private bool _created;
        private bool _direct;
        public string? Failure { get; init; }
        public bool HideChannel { get; set; }
        public bool MissingMember { get; init; }
        public bool ExistingGroup { get; init; }
        public bool SummaryMembersEmpty { get; init; }
        public List<Call> Calls { get; } = [];
        public ChatPrivateGroupCreateRequest Group { get; } = new("Synthetic & \"group\"", ["u-3", "u-2"], Guid.NewGuid());
        public ChatDirectConversationRequest Direct { get; } = new("u-2", Guid.NewGuid());
        public DsmRepository Repository { get; }
        public Fixture(string format, string memberFormat)
        {
            _http = new(new Handler(this));
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            var capabilities = new Dictionary<string, ApiCapability>();
            foreach (var (suffix, max, requestFormat) in new[]
            {
                ("User", 3, "FORM"), ("Channel", 5, "FORM"), ("Post", 8, "FORM"),
                ("Channel.Anonymous", 2, format), ("Channel.Named", 1, format), ("Channel.Member", 1, memberFormat),
            }) capabilities["SYNO.Chat." + suffix] = new("SYNO.Chat." + suffix, "entry.cgi", 1, max, requestFormat);
            Repository = new(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), capabilities);
        }

        private HttpResponseMessage Reply(Call call)
        {
            if (call.Method is "create" or "initiate")
            {
                if (Failure == "network") throw new HttpRequestException();
                if (Failure == "timeout") throw new TaskCanceledException();
                if (Failure == "http") return new(HttpStatusCode.BadGateway);
                if (Failure == "api") return Json("""{"success":false,"error":{"code":105}}""");
                _created = true;
                _direct = call.Method == "initiate";
            }
            JsonObject data = call.Api switch
            {
                "SYNO.Chat.User" => new()
                {
                    ["current_user_id"] = "u-1", ["users"] = new JsonArray(
                        new JsonObject { ["user_id"] = "u-1", ["nickname"] = "Self", ["is_login"] = true },
                        new JsonObject { ["user_id"] = "u-2", ["nickname"] = "Second" },
                        new JsonObject { ["user_id"] = "u-3", ["nickname"] = "Third" }),
                },
                "SYNO.Chat.Channel" => new()
                {
                    ["channels"] = (!_created && !ExistingGroup) || HideChannel ? new JsonArray() : new JsonArray(new JsonObject
                    {
                        ["channel_id"] = "group-7", ["type"] = _direct ? "anonymous" : "private", ["name"] = Group.Title,
                        ["members"] = SummaryMembersEmpty ? new JsonArray() : new JsonArray("u-1", "u-2", "u-3"),
                    }),
                },
                "SYNO.Chat.Channel.Member" => new()
                {
                    ["user_ids"] = MissingMember ? new JsonArray("u-1", "u-2") : new JsonArray("u-1", "u-2", "u-3"),
                    ["broken_user_ids"] = new JsonArray(),
                },
                _ => new() { ["channel_id"] = "group-7" },
            };
            return Json(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
        }

        private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK)
        { Content = new StringContent(value, Encoding.UTF8, "application/json") };
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Equal("nas.invalid", request.RequestUri!.Host);
                Assert.Empty(request.RequestUri.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var values = body.Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Equal("synthetic-sid", values["_sid"]);
                Assert.Equal("synthetic-token", values["SynoToken"]);
                var call = new Call(values["api"], values["method"], values);
                owner.Calls.Add(call);
                return owner.Reply(call);
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
