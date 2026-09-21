using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatActionFlowTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task CloseUsesFrozenWriteAndConfirmedAbsenceWithoutReplaying(string format)
    {
        using var fixture = new Fixture(format);
        var request = new ChatCloseConversationRequest("1", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.CloseConversationAsync(request)).Status);
        await fixture.Chat.CloseConversationAsync(request);
        var call = Assert.Single(fixture.Calls, call => call["method"] == "close");
        Assert.Equal("5", call["version"]);
        Assert.Equal(format == "JSON" ? "\"1\"" : "1", call["channel_id"]);
    }

    [Fact]
    public async Task MalformedConversationListCannotConfirmClosure()
    {
        using var fixture = new Fixture("JSON") { MalformedAfterClose = true };
        var request = new ChatCloseConversationRequest("1", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.CloseConversationAsync(request)).Status);
        await fixture.Chat.CloseConversationAsync(request);
        Assert.Single(fixture.Calls, call => call["method"] == "close");
        fixture.MalformedAfterClose = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.CloseConversationAsync(request)).Status);
    }

    [Theory]
    [InlineData("FORM", false)]
    [InlineData("JSON", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", true)]
    public async Task ForwardUsesNumericTargetArrayAndVerifiesEveryDestination(string format, bool attachment)
    {
        using var fixture = new Fixture(format) { Attachment = attachment };
        var request = new ChatForwardRequest("source", "1", ["3", "2", "2"], Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.ForwardMessageAsync(request)).Status);
        await fixture.Chat.ForwardMessageAsync(request);
        var call = Assert.Single(fixture.Calls, call => call["method"] == "forward");
        Assert.Equal("5", call["version"]);
        Assert.Equal(new long[] { 2, 3 }, JsonSerializer.Deserialize<long[]>(call["channel_ids"]));
        Assert.Equal(format == "JSON" ? "\"source\"" : "source", call["post_id"]);
    }

    [Fact]
    public async Task EncryptedConversationCanBeClosedWithoutReadingItsMessages()
    {
        using var fixture = new Fixture("JSON") { EncryptedSource = true };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.CloseConversationAsync(new("1", Guid.NewGuid()))).Status);
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Chat.Post");
    }

    [Fact]
    public async Task PartialForwardOnlyReviewsAndOldMatchingMessagesCannotConfirmIt()
    {
        using var fixture = new Fixture("JSON") { SkipDestination = "3", OldMatchingMessages = true };
        var request = new ChatForwardRequest("source", "1", ["2", "3"], Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.ForwardMessageAsync(request)).Status);
        await fixture.Chat.ForwardMessageAsync(request);
        Assert.Single(fixture.Calls, call => call["method"] == "forward");
        fixture.Delivered.Add("3");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.ForwardMessageAsync(request)).Status);
        Assert.Single(fixture.Calls, call => call["method"] == "forward");
    }

    [Fact]
    public async Task CompatibleChatContractCanDeleteOwnMessageWithoutDsmBuildGate()
    {
        using var fixture = new Fixture("JSON") { OwnSource = true, UnknownEnvironment = true };
        var result = await fixture.Chat.DeleteOwnMessageAsync(new("source", "1", Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.True(result.Submitted);
        Assert.Single(fixture.Calls, item => item["method"] == "delete");
        Assert.DoesNotContain(fixture.Calls, item => item["api"].StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task DeleteRejectsChangedOrForeignContentBeforeWriting()
    {
        using var fixture = new Fixture("JSON") { OwnSource = true };
        var source = await fixture.Chat.GetMessageAsync("1", "source");
        var changed = await fixture.Chat.DeleteOwnMessageAsync(new("source", "1", Guid.NewGuid()) { ExpectedMessage = source with { Text = "changed" } });
        Assert.Equal(MutationErrorCategory.Conflict, changed.ErrorCategory);
        Assert.DoesNotContain(fixture.Calls, item => item["method"] == "delete");
        using var foreign = new Fixture("FORM");
        var denied = await foreign.Chat.DeleteOwnMessageAsync(new("source", "1", Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Permission, denied.ErrorCategory);
        Assert.DoesNotContain(foreign.Calls, item => item["method"] == "delete");
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task DeleteFindsOlderMessageAndRequiresFullReadbackWithNoReplay(string format)
    {
        using var fixture = new Fixture(format) { OwnSource = true, PostsAhead = 101, KeepAfterDelete = true };
        var request = new ChatDeleteMessageRequest("source", "1", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        Assert.Contains(fixture.Calls, item => item["method"] == "list" && item.GetValueOrDefault("offset") == "100");
        await fixture.Chat.DeleteOwnMessageAsync(request);
        Assert.Single(fixture.Calls, item => item["method"] == "delete");
        fixture.Deleted = true;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        fixture.Deleted = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        var write = Assert.Single(fixture.Calls, item => item["method"] == "delete");
        Assert.Equal("5", write["version"]);
        Assert.Equal(format == "JSON" ? "\"source\"" : "source", write["post_id"]);
    }

    [Fact]
    public async Task DeleteCannotTreatMalformedOrIncompleteReadbackAsSuccess()
    {
        using var fixture = new Fixture("JSON") { OwnSource = true, MalformedAfterDelete = true };
        var request = new ChatDeleteMessageRequest("source", "1", Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        fixture.MalformedAfterDelete = false; fixture.HoleAfterDelete = true;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        fixture.HoleAfterDelete = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.DeleteOwnMessageAsync(request)).Status);
        Assert.Single(fixture.Calls, item => item["method"] == "delete");
    }

    [Fact]
    public async Task AlreadyPinnedTargetIsAConflictWithoutWritingOrMalformedSuccess()
    {
        using var fixture = new Fixture("JSON") { Pinned = true };
        var result = await fixture.Chat.SetMessagePinnedAsync(new("1", "source", true, Guid.NewGuid()));
        Assert.False(result.Submitted);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pin");
    }

    [Fact]
    public async Task PendingForwardCannotBeBypassedByChangingRecipients()
    {
        using var fixture = new Fixture("JSON") { SkipDestination = "3" };
        var request = new ChatForwardRequest("source", "1", ["2", "3"], Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.ForwardMessageAsync(request)).Status);
        var changed = await fixture.Chat.ForwardMessageAsync(new("source", "1", ["2"], Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Conflict, changed.ErrorCategory);
        Assert.False(changed.Submitted);
        Assert.Single(fixture.Calls, call => call["method"] == "forward");
        fixture.Delivered.Add("3");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.ForwardMessageAsync(request)).Status);
    }

    [Fact]
    public async Task PollOrInaccessibleDestinationCannotBeForwarded()
    {
        using var poll = new Fixture("FORM") { SourcePoll = true };
        var denied = await poll.Chat.ForwardMessageAsync(new("source", "1", ["2"], Guid.NewGuid()));
        Assert.False(denied.Submitted);
        Assert.DoesNotContain(poll.Calls, call => call["method"] == "forward");
        using var other = new Fixture("JSON");
        var unavailable = await other.Chat.ForwardMessageAsync(new("source", "1", ["99"], Guid.NewGuid()));
        Assert.False(unavailable.Submitted);
        Assert.DoesNotContain(other.Calls, call => call["method"] == "forward");
    }

    [Fact]
    public async Task UnpinReadsBeyondFirstHundredAndConfirmsRemoval()
    {
        using var fixture = new Fixture("JSON") { Pinned = true, PinsAhead = 100 };
        var request = new ChatPinMessageRequest("1", "source", false, Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.SetMessagePinnedAsync(request)).Status);
        Assert.Single(fixture.Calls, call => call["method"] == "unpin");
        Assert.Contains(fixture.Calls, call => call["method"] == "search" && call["offset"] == "100");
        await fixture.Chat.SetMessagePinnedAsync(request);
        Assert.Single(fixture.Calls, call => call["method"] == "unpin");
    }

    [Fact]
    public async Task PinValidatesSelectedContentAndGroupBeforeWriting()
    {
        using var fixture = new Fixture("FORM");
        var source = Assert.Single((await fixture.Chat.ListMessagesAsync("1", null, 50)).Messages);
        var changed = await fixture.Chat.SetMessagePinnedAsync(new("1", "source", true, Guid.NewGuid()) { ExpectedMessage = source with { Text = "different" } });
        Assert.Equal(MutationErrorCategory.Conflict, changed.ErrorCategory);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pin");
        var valid = await fixture.Chat.SetMessagePinnedAsync(new("1", "source", true, Guid.NewGuid()) { ExpectedMessage = source });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, valid.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "pin");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly string _format;
        private readonly long _time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        private bool _closed;
        public bool MalformedAfterClose { get; set; }
        public bool SourcePoll { get; init; }
        public bool OldMatchingMessages { get; init; }
        public bool Attachment { get; init; }
        public bool EncryptedSource { get; init; }
        public bool OwnSource { get; init; }
        public int PostsAhead { get; init; }
        public bool Deleted { get; set; }
        public bool KeepAfterDelete { get; init; }
        public bool MalformedAfterDelete { get; set; }
        public bool HoleAfterDelete { get; set; }
        public bool UnknownEnvironment { get; init; }
        public bool Pinned { get; set; }
        public int PinsAhead { get; init; }
        public string? SkipDestination { get; init; }
        public HashSet<string> Delivered { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IChatRepository Chat { get; }
        public Fixture(string format)
        {
            _format = format; _http = new(new Handler(this));
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            var capabilities = new[] { ("SYNO.Chat.User", 3), ("SYNO.Chat.Channel", 5), ("SYNO.Chat.Post", 8), ("SYNO.Core.Desktop.Initdata", 1), ("SYNO.Core.Package", 2) }
                .ToDictionary(item => item.Item1, item => new ApiCapability(item.Item1, "entry.cgi", 1, item.Item2, format));
            Chat = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), capabilities);
        }
        private JsonObject Message(string id, string channel, bool owned) => new()
        { ["post_id"] = id, ["channel_id"] = channel, ["creator_id"] = owned ? "u-1" : "u-2", ["is_my_post"] = owned,
          ["message"] = Attachment ? null : "Synthetic text", ["create_at"] = _time,
          ["files"] = Attachment ? new JsonArray(new JsonObject { ["file_id"] = "file-" + id, ["name"] = "synthetic.bin", ["size"] = 42, ["mime_type"] = "application/octet-stream" }) : new JsonArray() };
        private JsonObject Reply(Dictionary<string, string> call)
        {
            string Text(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
            switch (call["api"])
            {
                case "SYNO.Core.Desktop.Initdata": return new() { ["Session"] = new JsonObject { ["productversion"] = "7.2.1", ["version"] = UnknownEnvironment ? "synthetic-unknown" : "69057", ["smallfixnumber"] = "12" } };
                case "SYNO.Core.Package": return new() { ["packages"] = new JsonArray(new JsonObject { ["id"] = "Chat", ["version"] = "2.4.1-22111" }) };
                case "SYNO.Chat.User": return new() { ["current_user_id"] = "u-1", ["users"] = new JsonArray(new JsonObject { ["user_id"] = "u-1", ["nickname"] = "Self", ["is_login"] = true }, new JsonObject { ["user_id"] = "u-2", ["nickname"] = "Other" }) };
                case "SYNO.Chat.Channel":
                    if (call["method"] == "close") { _closed = true; return new(); }
                    if (_closed && MalformedAfterClose) return new();
                    return new() { ["channels"] = new JsonArray(Enumerable.Range(_closed ? 2 : 1, _closed ? 2 : 3).Select(id => (JsonNode)new JsonObject
                        { ["channel_id"] = id.ToString(), ["name"] = $"Synthetic {id}", ["type"] = "private", ["encrypted"] = id == 1 && EncryptedSource }).ToArray()) };
                case "SYNO.Chat.Post":
                    if (call["method"] == "delete") { Deleted = !KeepAfterDelete; return new(); }
                    if (call["method"] == "list" && Deleted && MalformedAfterDelete) return new();
                    if (call["method"] == "list" && Deleted && HoleAfterDelete) return new() { ["posts"] = new JsonArray(), ["total"] = 1 };
                    if (call["method"] == "forward")
                    { foreach (var id in JsonSerializer.Deserialize<long[]>(call["channel_ids"])!) if (id.ToString() != SkipDestination) Delivered.Add(id.ToString()); return new(); }
                    if (call["method"] is "pin" or "unpin") { Pinned = call["method"] == "pin"; return new(); }
                    if (call["method"] == "search")
                    {
                        var all = Enumerable.Range(0, PinsAhead).Select(id => new JsonObject { ["post_id"] = $"pin-{id}", ["channel_id"] = "1", ["last_pin_at"] = _time, ["create_at"] = _time, ["message"] = "Synthetic pin" }).ToList();
                        if (Pinned) all.Add(new() { ["post_id"] = "source", ["channel_id"] = "1", ["last_pin_at"] = _time, ["create_at"] = _time, ["message"] = "Synthetic text" });
                        return new() { ["search_results"] = new JsonArray(all.Skip(int.Parse(call["offset"])).Take(100).Cast<JsonNode>().ToArray()) };
                    }
                    var channel = Text("channel_id"); var posts = new List<JsonObject>();
                    if (channel == "1")
                    {
                        posts.AddRange(Enumerable.Range(0, PostsAhead).Select(id => Message("ahead-" + id, "1", false)));
                        var source = Message("source", "1", OwnSource);
                        if (SourcePoll) source["vote"] = new JsonObject { ["question"] = "Synthetic text", ["choices"] = new JsonArray("one", "two") };
                        if (!Deleted) posts.Add(source);
                    }
                    else
                    {
                        if (OldMatchingMessages) posts.Add(Message("old-" + channel, channel, true));
                        if (Delivered.Contains(channel)) posts.Add(Message("new-" + channel, channel, true));
                    }
                    var offset = int.Parse(call["offset"]);
                    return new() { ["posts"] = new JsonArray(posts.Skip(offset).Take(int.Parse(call["limit"])).Cast<JsonNode>().ToArray()), ["offset"] = offset, ["total"] = posts.Count };
                default: throw new InvalidOperationException();
            }
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var text = await request.Content!.ReadAsStringAsync(cancellationToken);
                var call = text.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = owner.Reply(call) }.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
