using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatMessageInteractionWireTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SearchUsesNumericConversationArrayAndIndependentOffset(string format)
    {
        using var fixture = new Fixture(format);
        fixture.Messages.Add(fixture.Post("102", "Synthetic second"));
        var first = await fixture.Chat.SearchMessagesAsync(" Synthetic ", "10", null, 1);
        var second = await fixture.Chat.SearchMessagesAsync("Synthetic", "10", first.NextCursor, 1);
        Assert.Equal("1", first.NextCursor); Assert.Null(second.NextCursor);
        Assert.Equal("102", Assert.Single(second.Messages).Id);
        var calls = fixture.Calls.Where(value => value.Method == "search").ToArray();
        Assert.All(calls, call =>
        {
            Assert.Equal("5", call.Raw["version"]); Assert.Equal("[10]", call.Raw["in"]);
            Assert.Equal(format == "JSON" ? "\"Synthetic\"" : "Synthetic", call.Raw["keyword"]);
            Assert.DoesNotContain("channel_id", call.Raw.Keys); Assert.DoesNotContain("prev_count", call.Raw.Keys);
        });
        Assert.Equal(new[] { "0", "1" }, calls.Select(call => call.Raw["offset"]));
    }

    [Theory]
    [InlineData("foreign")]
    [InlineData("duplicate")]
    [InlineData("missing-total")]
    [InlineData("bad-total")]
    [InlineData("empty-before-total")]
    public async Task SearchRejectsBrokenOrForeignPages(string kind)
    {
        using var fixture = new Fixture();
        fixture.Transform = (call, data) =>
        {
            if (call.Method != "search") return data;
            var rows = (JsonArray)data["search_results"]!;
            if (kind == "foreign") rows[0]!["channel_id"] = "99";
            if (kind == "duplicate") { rows.Add(rows[0]!.DeepClone()); data["total"] = 2; }
            if (kind == "missing-total") data.Remove("total");
            if (kind == "bad-total") data["total"] = -1;
            if (kind == "empty-before-total") rows.Clear();
            return data;
        };
        await Assert.ThrowsAsync<DsmException>(() => fixture.Chat.SearchMessagesAsync("Synthetic", "10", null, 20));
        Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task SearchAndLocatorPreserveThreadAndEditedMetadata()
    {
        using var fixture = new Fixture();
        var reply = fixture.Post("202", "Synthetic reply", "101"); reply["update_at"] = fixture.Now.ToUnixTimeMilliseconds();
        fixture.Messages.Add(reply);
        var result = Assert.Single((await fixture.Chat.SearchMessagesAsync("reply", null, null, 20)).Messages);
        Assert.True(result.IsThreadReply); Assert.Equal("101", result.ThreadId); Assert.NotNull(result.EditedAt);
        var located = await fixture.Chat.LocateMessageAsync("10", "202", "101");
        Assert.Equal(result, located);
        Assert.Equal("[]", fixture.Calls.Single(call => call.Method == "search").Raw["in"]);
        var list = fixture.Calls.Last(); Assert.Equal("101", list.Text("thread_id"));
        Assert.Equal("0", list.Raw["prev_count"]); Assert.Equal("0", list.Raw["next_count"]);
    }

    [Fact]
    public async Task ThreadInitialPageOmitsRootLocatorAndOlderPageUsesReplyId()
    {
        using var fixture = new Fixture();
        for (var index = 1; index <= 3; index++) fixture.Messages.Add(fixture.Post((200 + index).ToString(), "Synthetic reply " + index, "101", index));
        var first = await fixture.Chat.ListRepliesAsync("10", "101", null, 2);
        var older = await fixture.Chat.ListRepliesAsync("10", "101", first.PreviousCursor, 2);
        Assert.Equal(new[] { "202", "203" }, first.Messages.Select(message => message.Id));
        Assert.Equal("202", first.PreviousCursor); Assert.Equal("201", Assert.Single(older.Messages).Id);
        Assert.False(older.HasMoreBefore);
        Assert.DoesNotContain("post_id", fixture.Calls[0].Raw.Keys);
        Assert.Equal("202", fixture.Calls[1].Text("post_id"));
        Assert.All(fixture.Calls, call => { Assert.DoesNotContain("offset", call.Raw.Keys); Assert.DoesNotContain("limit", call.Raw.Keys); });
    }

    [Theory]
    [InlineData("foreign-thread")]
    [InlineData("foreign-message")]
    [InlineData("foreign-channel")]
    public async Task LocatorRejectsWrongIdentity(string kind)
    {
        using var fixture = new Fixture(); fixture.Messages.Add(fixture.Post("202", "Synthetic reply", "101"));
        fixture.Transform = (call, data) =>
        {
            if (call.Api == "SYNO.Chat.Post" && call.Method == "list" && data["posts"] is JsonArray { Count: > 0 } rows)
                rows[0]![kind == "foreign-thread" ? "thread_id" : kind == "foreign-message" ? "post_id" : "channel_id"] = "99";
            return data;
        };
        await Assert.ThrowsAsync<DsmException>(() => fixture.Chat.LocateMessageAsync("10", "202", "101"));
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task EditUsesVersionEightFreshPolicyAndExactReadback(string format)
    {
        using var fixture = new Fixture(format);
        var original = await fixture.OriginalAsync();
        var request = new ChatEditMessageRequest(original, "  Synthetic edited  ", Guid.NewGuid());
        var result = await fixture.Chat.EditMessageAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status); Assert.Equal("Synthetic edited", result.Message?.Text);
        await fixture.Chat.EditMessageAsync(request);
        var call = Assert.Single(fixture.Writes);
        Assert.Equal("8", call.Raw["version"]); Assert.Equal("set", call.Method); Assert.Equal("101", call.Text("post_id"));
        Assert.Contains(fixture.Calls, value => value.Api == "SYNO.Chat.Admin.Setting" && value.Raw["version"] == "3");
        Assert.DoesNotContain(fixture.Calls, value => value.Api.StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("expired")]
    [InlineData("disabled")]
    [InlineData("foreign-author")]
    [InlineData("changed-text")]
    [InlineData("changed-time")]
    [InlineData("sticker")]
    [InlineData("system")]
    [InlineData("encrypted")]
    [InlineData("permission")]
    public async Task EditPreflightRejectsChangedOrForbiddenMessagesWithoutWriting(string kind)
    {
        using var fixture = new Fixture(); var original = await fixture.OriginalAsync();
        switch (kind)
        {
            case "expired": fixture.EditMinutes = 1; break;
            case "disabled": fixture.AllowsEditing = false; break;
            case "foreign-author": fixture.Messages[0]["creator_id"] = "2"; break;
            case "changed-text": fixture.Messages[0]["message"] = "Another client changed this"; break;
            case "changed-time": fixture.Messages[0]["update_at"] = fixture.Now.ToUnixTimeMilliseconds(); break;
            case "sticker": case "system": fixture.Messages[0]["type"] = kind; original = await fixture.OriginalAsync(); break;
            case "encrypted": fixture.Encrypted = true; break;
            case "permission": fixture.Accessible = false; break;
        }
        var result = await fixture.Chat.EditMessageAsync(new(original, "Synthetic edited", Guid.NewGuid()));
        Assert.False(result.Result.Submitted); Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result.Result.Status); Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task EditingPolicyZeroMeansUnlimitedAndBadPolicyDoesNotWrite()
    {
        using var fixture = new Fixture(); fixture.EditMinutes = 0;
        var policy = await fixture.Chat.GetEditingPolicyAsync(); Assert.Null(policy.MaximumAge);
        fixture.Transform = (call, data) => { if (call.Api == "SYNO.Chat.Admin.Setting") data.Remove("allow_edit_message_time_within_min"); return data; };
        var result = await fixture.Chat.EditMessageAsync(new(await fixture.OriginalAsync(), "Synthetic edited", Guid.NewGuid()));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task NicknameAloneCannotGrantEditingOwnership()
    {
        using var fixture = new Fixture(); fixture.DeclareCurrentUser = false; fixture.AccountField = null;
        fixture.Nickname = "synthetic-user"; fixture.Messages[0].Remove("is_my_post");
        var result = await fixture.Chat.EditMessageAsync(new(await fixture.OriginalAsync(), "Synthetic edited", Guid.NewGuid()));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes);
        fixture.AccountField = "synthetic-user";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.EditMessageAsync(new(await fixture.OriginalAsync(), "Synthetic edited", Guid.NewGuid()))).Result.Status);
    }

    [Fact]
    public async Task UnknownEditBlocksDeletionAndOtherEditsAndOnlyReadsAfterReconnect()
    {
        using var fixture = new Fixture(); var original = await fixture.OriginalAsync(); fixture.DropWriteReply = true;
        var request = new ChatEditMessageRequest(original, "Synthetic edited", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.EditMessageAsync(request)).Result.Status);
        var other = await fixture.Chat.EditMessageAsync(new(original, "Another edit", Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Conflict, other.Result.ErrorCategory);
        var deletion = await fixture.Chat.DeleteOwnMessageAsync(new(original.Id, original.ConversationId, Guid.NewGuid()) { ExpectedMessage = original });
        Assert.False(deletion.Submitted); Assert.Equal(MutationErrorCategory.Conflict, deletion.ErrorCategory);
        fixture.Messages[0]["message"] = "Synthetic edited";
        var recovered = await fixture.Reconnect().EditMessageAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, recovered.Result.Status); Assert.Single(fixture.Writes);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task VoteSendsStringArrayAndReadsCompleteOwnChoices(string format)
    {
        using var fixture = new Fixture(format); fixture.SeedPoll(); var original = await fixture.OriginalAsync();
        var result = await fixture.Chat.VoteAsync(new(original, ["2", "1"], Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.All(result.Message!.Poll!.Options, option => Assert.True(option.IsSelectedByCurrentUser));
        var call = Assert.Single(fixture.Writes); Assert.Equal("[\"1\",\"2\"]", call.Raw["choice_ids"]);
        Assert.Equal("1", call.Raw["version"]); Assert.Equal("vote", call.Method);
        Assert.Equal(2, fixture.Calls.Count(value => value.Method == "get_choices"));
    }

    [Theory]
    [InlineData("closed")]
    [InlineData("expired")]
    [InlineData("single")]
    [InlineData("changed-options")]
    [InlineData("missing-id")]
    [InlineData("missing-voters")]
    [InlineData("foreign-choice")]
    public async Task VoteRejectsInvalidOrChangedPollWithoutWriting(string kind)
    {
        using var fixture = new Fixture(); fixture.SeedPoll(); var original = await fixture.OriginalAsync();
        var poll = fixture.Messages[0]["props"]!["vote"]!;
        switch (kind)
        {
            case "closed": poll["state"] = "close"; break;
            case "expired": poll["options"]!["expire_at"] = fixture.Now.AddDays(-1).ToUnixTimeMilliseconds(); break;
            case "single": poll["options"]!["multiple"] = false; break;
            case "changed-options": poll["choices"]![0]!["text"] = "Changed option"; break;
            case "missing-id": poll["choices"]![0]!.AsObject().Remove("id"); break;
            case "missing-voters": poll["choices"]![0]!.AsObject().Remove("voters"); break;
        }
        var result = await fixture.Chat.VoteAsync(new(original, kind == "foreign-choice" ? ["missing"] : ["1", "2"], Guid.NewGuid()));
        Assert.False(result.Result.Submitted); Assert.Empty(fixture.Writes);
    }

    [Fact]
    public async Task UnknownVoteNeverReplaysAndRequiresOriginalPollIdentity()
    {
        using var fixture = new Fixture(); fixture.SeedPoll(); var original = await fixture.OriginalAsync(); fixture.DropWriteReply = true;
        var request = new ChatVoteRequest(original, ["1"], Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.VoteAsync(request)).Result.Status);
        fixture.SelectChoices(["1"]);
        fixture.Messages[0]["props"]!["vote"]!["choices"]![0]!["text"] = "Changed option";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.VoteAsync(request)).Result.Status);
        fixture.Messages[0]["props"]!["vote"]!["choices"]![0]!["text"] = "First";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.VoteAsync(request)).Result.Status); Assert.Single(fixture.Writes);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ThreadReplyUsesRootAndStableReturnedIdentity(string format)
    {
        using var fixture = new Fixture(format);
        var request = new ChatTextSendRequest("10", "Synthetic reply", Guid.NewGuid()) { ThreadId = "101" };
        var result = await fixture.Chat.SendTextAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status); Assert.Equal("101", result.ConfirmedMessage?.ThreadId);
        await fixture.Chat.SendTextAsync(request);
        var call = Assert.Single(fixture.Writes); Assert.Equal("5", call.Raw["version"]);
        Assert.Equal("normal", call.Text("type")); Assert.Equal("false", call.Raw["is_thread"]); Assert.Equal("101", call.Text("thread_id"));
        var changed = await fixture.Chat.SendTextAsync(request with { Text = "Changed" });
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory); Assert.Single(fixture.Writes);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task LostSendReceiptCannotClaimMatchingTextOrReplayAcrossRepository(bool thread)
    {
        using var fixture = new Fixture(); fixture.DropWriteReply = true; fixture.ApplyBeforeDrop = true;
        var request = new ChatTextSendRequest("10", "Synthetic new message", Guid.NewGuid()) { ThreadId = thread ? "101" : null };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.SendTextAsync(request)).Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Reconnect().SendTextAsync(request with { ClientRequestId = Guid.NewGuid() })).Result.Status);
        Assert.Single(fixture.Writes); Assert.Contains(fixture.Messages, value => value["message"]!.GetValue<string>() == request.Text);
    }

    [Fact]
    public async Task AcceptedSendCanUseStableIdentityWhenMineFlagIsMissingButRejectsForeignAuthor()
    {
        using var fixture = new Fixture(); fixture.OmitMineOnCreate = true;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.SendTextAsync(new("10", "Synthetic first", Guid.NewGuid()))).Result.Status);
        fixture.CreateAuthor = "2";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.SendTextAsync(new("10", "Synthetic second", Guid.NewGuid()))).Result.Status);
    }

    [Fact]
    public async Task ReadUsesActualReadMessageTimestampAndWaitsForNasReadback()
    {
        using var fixture = new Fixture(); var message = await fixture.OriginalAsync();
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Chat.MarkReadAsync("10", message.Id, fixture.Now));
        Assert.Empty(fixture.Writes);
        var read = await fixture.Chat.MarkReadAsync("10", message.Id, message.SentAt);
        Assert.Equal(message.SentAt, read.LastViewedAt); Assert.Equal(0, read.UnreadCount);
        var call = Assert.Single(fixture.Writes); Assert.Equal("2", call.Raw["version"]);
        Assert.Equal(message.SentAt.ToUnixTimeMilliseconds().ToString(), call.Raw["last_view_at"]);
        fixture.IgnoreRead = true; fixture.LastViewedAt = null;
        await Assert.ThrowsAsync<DsmException>(() => fixture.Chat.MarkReadAsync("10", message.Id, message.SentAt));
    }

    [Fact]
    public async Task ThreadReadDoesNotAdvancePastANewerUnseenReply()
    {
        using var fixture = new Fixture(); fixture.Messages.Add(fixture.Post("202", "Synthetic reply", "101", 1));
        var message = Assert.Single((await fixture.Chat.ListRepliesAsync("10", "101", null, 20)).Messages);
        fixture.Messages.Add(fixture.Post("203", "Synthetic newer reply", "101", 2));
        await Assert.ThrowsAnyAsync<Exception>(() => fixture.Chat.MarkThreadReadAsync("10", "101", message.Id)); Assert.Empty(fixture.Writes);
        await fixture.Chat.ListRepliesAsync("10", "101", null, 20);
        await fixture.Chat.MarkThreadReadAsync("10", "101", "203");
        Assert.Equal("SYNO.Chat.Post.Subscribe", Assert.Single(fixture.Writes).Api);
    }

    internal sealed record WireCall(Dictionary<string, string> Raw, string Format)
    {
        public string Api => Raw["api"];
        public string Method => Raw["method"];
        public string Text(string key) => Format == "JSON" ? JsonSerializer.Deserialize<string>(Raw[key])! : Raw[key];
    }

    [Fact]
    public async Task ChangedQuickConnectRouteDoesNotBypassUnknownSendOwnership()
    {
        using var fixture = new Fixture(); fixture.DropWriteReply = true;
        var request = new ChatTextSendRequest("10", "Synthetic route-bound send", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.SendTextAsync(request)).Result.Status);
        var alternateRoute = fixture.ConfiguredProfile with { Host = "relay.invalid", Port = 443 };
        var reconnect = fixture.Reconnect(alternateRoute, fixture.ConfiguredProfile);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await reconnect.SendTextAsync(request)).Result.Status);
        Assert.Single(fixture.Writes);
    }

    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly string _format;
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        internal Dictionary<string, ApiCapability> Capabilities { get; }
        public IChatRepository Chat { get; }
        public NasProfile ConfiguredProfile => _profile;
        public DateTimeOffset Now { get; } = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        public List<JsonObject> Messages { get; } = [];
        public List<WireCall> Calls { get; } = [];
        public IEnumerable<WireCall> Writes => Calls.Where(call => call.Method is "set" or "create" or "delete" or "vote" or "view");
        public Func<WireCall, JsonObject, JsonObject>? Transform { get; set; }
        public bool Accessible = true, Encrypted, AllowsEditing = true, DropWriteReply, ApplyBeforeDrop,
            DeclareCurrentUser = true, OmitMineOnCreate, IgnoreRead;
        public double EditMinutes = 30;
        public string? AccountField = "synthetic-user";
        public string Nickname = "Synthetic display", CreateAuthor = "1";
        public long? LastViewedAt;

        public Fixture(string format = "FORM")
        {
            _format = format; _http = new(new Handler(this));
            Capabilities = new[] { ("SYNO.Chat.User", 3), ("SYNO.Chat.Channel", 5), ("SYNO.Chat.Post", 8),
                ("SYNO.Chat.Admin.Setting", 3), ("SYNO.Chat.Post.Vote", 1), ("SYNO.Chat.Post.Subscribe", 2) }
                .ToDictionary(value => value.Item1, value => new ApiCapability(value.Item1, "entry.cgi", 1, value.Item2, format));
            Messages.Add(Post("101", "Synthetic original")); Chat = Reconnect();
        }
        public IChatRepository Reconnect(NasProfile? profile = null, NasProfile? configuredProfile = null) => new DsmRepository(profile ?? _profile,
            new(_profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), Capabilities) { ConfiguredChatProfile = configuredProfile };
        public async Task<ChatMessage> OriginalAsync()
        { await Chat.ListConversationsAsync(); return (await Chat.LocateMessageAsync("10", "101"))!; }
        public JsonObject Post(string id, string text, string? thread = null, int order = 0) => new()
        {
            ["post_id"] = id, ["channel_id"] = "10", ["creator_id"] = "1", ["is_my_post"] = true, ["message"] = text,
            ["create_at"] = Now.AddMinutes(-5).AddMilliseconds(order).ToUnixTimeMilliseconds(), ["type"] = "normal", ["thread_id"] = thread ?? "0",
        };
        public void SeedPoll()
        {
            Messages[0]["props"] = new JsonObject { ["vote"] = new JsonObject
            {
                ["state"] = "open", ["options"] = new JsonObject { ["multiple"] = true, ["anonymous"] = false, ["expire_at"] = 0 },
                ["choices"] = new JsonArray(new JsonObject { ["id"] = "1", ["text"] = "First", ["count"] = 0, ["voters"] = new JsonArray() },
                    new JsonObject { ["id"] = "2", ["text"] = "Second", ["count"] = 0, ["voters"] = new JsonArray() }),
            } };
        }
        public void SelectChoices(string[] choices)
        {
            foreach (var option in Messages[0]["props"]!["vote"]!["choices"]!.AsArray().OfType<JsonObject>())
            {
                var selected = choices.Contains(option["id"]!.GetValue<string>());
                option["count"] = selected ? 1 : 0; option["voters"] = selected ? new JsonArray(1) : new JsonArray();
            }
        }
        private JsonObject Respond(WireCall call)
        {
            switch (call.Api, call.Method)
            {
                case ("SYNO.Chat.User", "list"):
                    var users = new JsonObject { ["users"] = new JsonArray(new JsonObject { ["user_id"] = "1", ["nickname"] = Nickname, ["username"] = AccountField }) };
                    if (DeclareCurrentUser) users["current_user_id"] = "1"; return users;
                case ("SYNO.Chat.Channel", "list"):
                    return new() { ["channels"] = Accessible ? new JsonArray(new JsonObject { ["channel_id"] = "10", ["name"] = "Synthetic group", ["type"] = "private",
                        ["encrypted"] = Encrypted, ["unread"] = LastViewedAt is null ? 2 : 0, ["last_view_at"] = LastViewedAt }) : new JsonArray() };
                case ("SYNO.Chat.Channel", "view"):
                    if (!IgnoreRead) LastViewedAt = long.Parse(call.Raw["last_view_at"]); return new();
                case ("SYNO.Chat.Post.Subscribe", "view"): return new();
                case ("SYNO.Chat.Admin.Setting", "get"): return new() { ["allow_edit_message"] = AllowsEditing, ["allow_edit_message_time_within_min"] = EditMinutes };
                case ("SYNO.Chat.Post", "search"):
                    var found = Messages.Where(row => row["message"]!.GetValue<string>().Contains(call.Text("keyword"), StringComparison.OrdinalIgnoreCase)).ToArray();
                    return new() { ["search_results"] = new JsonArray(found.Skip(int.Parse(call.Raw["offset"])).Take(int.Parse(call.Raw["limit"])).Select(row => row.DeepClone()).ToArray()), ["total"] = found.Length };
                case ("SYNO.Chat.Post", "list"):
                    var thread = call.Text("thread_id"); var id = call.Raw.ContainsKey("post_id") ? call.Text("post_id") : null;
                    var before = int.Parse(call.Raw["prev_count"]); var after = int.Parse(call.Raw["next_count"]);
                    var candidates = Messages.Where(row => thread == "0" ? row["thread_id"]!.GetValue<string>() == "0" || row["thread_id"]!.GetValue<string>() == row["post_id"]!.GetValue<string>()
                        : row["thread_id"]!.GetValue<string>() == thread).ToList();
                    if (id is not null && before == 0 && after == 0) candidates = candidates.Where(row => row["post_id"]!.GetValue<string>() == id).ToList();
                    else if (id is null) candidates = candidates.TakeLast(before).ToList();
                    else { var index = candidates.FindIndex(row => row["post_id"]!.GetValue<string>() == id); candidates = index < 0 ? [] : candidates.Take(index).TakeLast(before).Concat([candidates[index]]).ToList(); }
                    return new() { ["posts"] = new JsonArray(candidates.Select(row => row.DeepClone()).ToArray()) };
                case ("SYNO.Chat.Post", "set"):
                    Messages.Single(row => row["post_id"]!.GetValue<string>() == call.Text("post_id"))["message"] = call.Text("message"); return new();
                case ("SYNO.Chat.Post", "create"):
                    var created = Post((900 + Writes.Count()).ToString(), call.Text("message"), call.Raw.ContainsKey("thread_id") ? call.Text("thread_id") : null);
                    created["creator_id"] = CreateAuthor; if (OmitMineOnCreate) created.Remove("is_my_post");
                    Messages.Add(created); return new() { ["post_id"] = created["post_id"]!.DeepClone() };
                case ("SYNO.Chat.Post.Vote", "get_choices"): return new() { ["choices"] = Messages[0]["props"]!["vote"]!["choices"]!.DeepClone() };
                case ("SYNO.Chat.Post.Vote", "vote"): SelectChoices(JsonSerializer.Deserialize<string[]>(call.Raw["choice_ids"])!); return new();
                default: throw new InvalidOperationException("Unexpected synthetic request.");
            }
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var values = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                var call = new WireCall(values, owner._format); owner.Calls.Add(call);
                var dropping = owner.DropWriteReply && call.Method is "set" or "create" or "vote";
                if (dropping && !owner.ApplyBeforeDrop) throw new HttpRequestException("Synthetic lost reply.");
                var data = owner.Respond(call); if (dropping) throw new HttpRequestException("Synthetic lost reply.");
                data = owner.Transform?.Invoke(call, data) ?? data;
                return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
