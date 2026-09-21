using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatAdvancedFlowTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ReminderAndScheduleCompleteReadbackAndSingleSubmission(string format)
    {
        using var fixture = new Fixture(format);
        var at = DateTimeOffset.FromUnixTimeMilliseconds(DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeMilliseconds());
        var id = Guid.NewGuid();
        var reminder = await fixture.Chat.SetReminderAsync("p-1", "c-1", at, id);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reminder.Result.Status);
        Assert.Equal(at, reminder.ConfirmedReminder?.RemindAt);
        await fixture.Chat.SetReminderAsync("p-1", "c-1", at, id);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
        var draft = new ChatScheduledMessageDraft("c-1", "Synthetic scheduled text", at, Guid.NewGuid());
        var schedule = await fixture.Chat.CreateScheduledMessageAsync(draft);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, schedule.Result.Status);
        Assert.Equal(draft.Text, schedule.ConfirmedMessage?.Text);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.DeleteReminderAsync("p-1", "c-1", Guid.NewGuid())).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.DeleteScheduledMessageAsync("s-1", "c-1", Guid.NewGuid())).Status);
        var sent = fixture.Calls.Single(call => call["api"] == "SYNO.Chat.Post.Schedule" && call["method"] == "create");
        Assert.Equal(format == "JSON" ? "\"c-1\"" : "c-1", sent["channel_id"]);
        var sentTime = at.ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(sentTime) : sentTime, sent["send_at"]);
    }

    [Theory]
    [InlineData("network")]
    [InlineData("http")]
    public async Task UnknownReminderOnlyReviewsAndBlocksAnotherRequestForTheSameTarget(string failure)
    {
        using var fixture = new Fixture("JSON") { Failure = failure };
        var at = DateTimeOffset.UtcNow.AddHours(1);
        var id = Guid.NewGuid();
        var first = await fixture.Chat.SetReminderAsync("p-1", "c-1", at, id);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        var changed = await fixture.Chat.SetReminderAsync("p-1", "c-1", at.AddMinutes(1), Guid.NewGuid());
        Assert.False(changed.Result.Submitted);
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        var second = await fixture.Chat.SetReminderAsync("p-1", "c-1", at, id);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
        fixture.ReminderTime = at.ToUnixTimeMilliseconds();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.SetReminderAsync("p-1", "c-1", at, id)).Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
    }

    [Fact]
    public async Task AdvancedWritesDependOnChatContractsInsteadOfOneDsmBuild()
    {
        using var fixture = new Fixture("JSON") { Build = "future" };
        var availability = await fixture.Chat.PrepareAdvancedFeaturesAsync();
        Assert.Contains(ChatReadFeature.Reminders, availability.SupportedFeatures);
        Assert.Contains(ChatWriteFeature.Reminders, availability.SupportedWriteFeatures);
        var result = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
        Assert.DoesNotContain(fixture.Calls, call => call["api"].StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ForeignConversationReadbackCannotBecomeSuccess()
    {
        using var fixture = new Fixture("JSON") { ForeignOwner = true, ReminderTime = 1800000000000 };
        await Assert.ThrowsAsync<DsmException>(() => fixture.Chat.ListRemindersAsync("c-1"));
    }

    [Fact]
    public async Task AdvancedActionsNeedNoSystemAdministrationCapabilities()
    {
        using var fixture = new Fixture("JSON", configure: capabilities =>
        {
            capabilities.Remove("SYNO.Core.Desktop.Initdata");
            capabilities.Remove("SYNO.Core.Package");
        });
        var availability = await fixture.Chat.PrepareAdvancedFeaturesAsync();
        Assert.Contains(ChatWriteFeature.Reminders, availability.SupportedWriteFeatures);
        Assert.Empty(fixture.Calls);
        var result = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
        Assert.DoesNotContain(fixture.Calls, call => call["api"].StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("", false)]
    [InlineData(" ", false)]
    [InlineData("synthetic-sid", true)]
    public async Task InvalidSessionExposesNoWritesAndSendsNothing(string sid, bool wrongProfile)
    {
        using var fixture = new Fixture("JSON");
        var chat = fixture.Reconnect(sid, wrongProfile);
        Assert.Empty(chat.Availability.SupportedWriteFeatures);
        var result = await chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        Assert.False(result.Result.Submitted);
        Assert.Equal(MutationErrorCategory.Validation, result.Result.ErrorCategory);
        Assert.Empty(fixture.Calls);
    }

    [Theory]
    [InlineData("other", "entry.cgi", 1, 1, "JSON")]
    [InlineData("SYNO.Chat.Post.Reminder", "other.cgi", 1, 1, "JSON")]
    [InlineData("SYNO.Chat.Post.Reminder", "entry.cgi", 0, 1, "JSON")]
    [InlineData("SYNO.Chat.Post.Reminder", "entry.cgi", 2, 1, "JSON")]
    [InlineData("SYNO.Chat.Post.Reminder", "entry.cgi", 2, 2, "JSON")]
    [InlineData("SYNO.Chat.Post.Reminder", "entry.cgi", 1, 1, "XML")]
    public async Task InvalidCapabilityCannotExposeOrSubmitAdvancedAction(string name, string path, int min, int max, string format)
    {
        using var fixture = new Fixture("JSON", configure: capabilities =>
            capabilities["SYNO.Chat.Post.Reminder"] = new(name, path, min, max, format));
        var availability = await fixture.Chat.PrepareAdvancedFeaturesAsync();
        Assert.DoesNotContain(ChatWriteFeature.Reminders, availability.SupportedWriteFeatures);
        Assert.Contains(ChatWriteFeature.ScheduledMessages, availability.SupportedWriteFeatures);
        var result = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        Assert.False(result.Result.Submitted);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task CancelledPreparationSendsNothing()
    {
        using var fixture = new Fixture("FORM");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Chat.PrepareAdvancedFeaturesAsync(cancellation.Token));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task MissingListIsFailureInsteadOfEmptyAndCannotConfirmDeletion()
    {
        using var fixture = new Fixture("FORM") { MissingList = true };
        await Assert.ThrowsAsync<DsmException>(() => fixture.Chat.ListRemindersAsync("c-1"));
        var result = await fixture.Chat.DeleteReminderAsync("p-1", "c-1", Guid.NewGuid());
        Assert.False(result.Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "delete");
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task PollRequiresOwnedTypedReadbackAndPreservesOptionsEncoding(string format)
    {
        using var fixture = new Fixture(format);
        var draft = new ChatPollDraft("c-1", "Synthetic question", ["One", "Two"], true, false, Guid.NewGuid());
        var result = await fixture.Chat.CreatePollAsync(draft);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(new[] { "One", "Two" }, result.ConfirmedMessage!.Poll!.Options.Select(item => item.Text));
        await fixture.Chat.CreatePollAsync(draft);
        var call = Assert.Single(fixture.Calls, call => call["api"] == "SYNO.Chat.Post.Vote");
        Assert.Equal(new[] { "One", "Two" }, JsonSerializer.Deserialize<string[]>(call["choices"]));
        var options = format == "JSON" ? JsonSerializer.Deserialize<string>(call["options"])! : call["options"];
        Assert.True(JsonNode.Parse(options)!["multiple"]!.GetValue<bool>());
    }

    [Fact]
    public async Task JsonCoreMessageReadUsedByPreflightMustKeepConversationIdAString()
    {
        using var fixture = new Fixture("JSON", jsonCore: true);
        var result = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var read = Assert.Single(fixture.Calls, call => call["api"] == "SYNO.Chat.Post");
        Assert.Equal("\"c-1\"", read["channel_id"]);
    }

    [Fact]
    public async Task RecreatedRepositoryOnlyReviewsAnUnresolvedTarget()
    {
        using var fixture = new Fixture("JSON") { Failure = "network" };
        var at = DateTimeOffset.UtcNow.AddHours(1);
        await fixture.Chat.SetReminderAsync("p-1", "c-1", at, Guid.NewGuid());
        var reconnected = fixture.Reconnect();
        var id = Guid.NewGuid();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await reconnected.SetReminderAsync("p-1", "c-1", at, id)).Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
        fixture.ReminderTime = at.ToUnixTimeMilliseconds();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await reconnected.SetReminderAsync("p-1", "c-1", at, id)).Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "set");
    }

    [Fact]
    public async Task ExpiredOrCancelledDraftMakesNoRequest()
    {
        using var fixture = new Fixture("JSON");
        var expired = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(-1), Guid.NewGuid());
        Assert.Equal(MutationErrorCategory.Validation, expired.Result.ErrorCategory);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        var cancelled = await fixture.Chat.SetReminderAsync("p-1", "c-1", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid(), cancellation.Token);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, cancelled.Result.Status);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task PackageAdministrationPermissionIsNotRequiredForOwnChatFeatures()
    {
        using var fixture = new Fixture("FORM") { MetadataDenied = true, ReminderTime = 1800000000000 };
        var availability = await fixture.Chat.PrepareAdvancedFeaturesAsync();
        Assert.Contains(ChatWriteFeature.Reminders, availability.SupportedWriteFeatures);
        Assert.Single(await fixture.Chat.ListRemindersAsync("c-1"));
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "set");
        Assert.DoesNotContain(fixture.Calls, call => call["api"].StartsWith("SYNO.Core.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task AnotherUsersMatchingPollCannotConfirmOurWrite()
    {
        using var fixture = new Fixture("JSON") { WrongPollOwner = true };
        var draft = new ChatPollDraft("c-1", "Synthetic question", ["One", "Two"], false, true, Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.CreatePollAsync(draft)).Result.Status);
        await fixture.Chat.CreatePollAsync(draft);
        Assert.Single(fixture.Calls, call => call["api"] == "SYNO.Chat.Post.Vote");
        fixture.WrongPollOwner = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.CreatePollAsync(draft)).Result.Status);
    }

    [Fact]
    public async Task SecondsInReadResponseAreNotShownAsMillisecondsNearTheEpoch()
    {
        using var fixture = new Fixture("JSON") { ReminderTime = 1800000000 };
        var reminder = Assert.Single(await fixture.Chat.ListRemindersAsync("c-1"));
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1800000000), reminder.RemindAt);
    }

    [Fact]
    public async Task ChangedReminderAndScheduleAreRejectedBeforeCancellation()
    {
        using var fixture = new Fixture("JSON") { ReminderTime = 1800000000000 };
        var reminder = Assert.Single(await fixture.Chat.ListRemindersAsync("c-1"));
        fixture.ReminderTime += 60000;
        var rejected = await fixture.Chat.DeleteReminderAsync(reminder, Guid.NewGuid());
        Assert.Equal(MutationErrorCategory.Conflict, rejected.ErrorCategory);
        Assert.False(rejected.Submitted);
        var created = await fixture.Chat.CreateScheduledMessageAsync(new("c-1", "Synthetic", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid()));
        fixture.ScheduleTime += 60000;
        var scheduleRejected = await fixture.Chat.DeleteScheduledMessageAsync(created.ConfirmedMessage!, Guid.NewGuid());
        Assert.Equal(MutationErrorCategory.Conflict, scheduleRejected.ErrorCategory);
        Assert.False(scheduleRejected.Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task SingleReminderObjectKeepsItsPrimaryTimeWhenPropsContainOtherMetadata()
    {
        using var fixture = new Fixture("JSON") { ReminderTime = 1800000000000, SingleReminder = true };
        var reminder = Assert.Single(await fixture.Chat.ListRemindersAsync("c-1"));
        Assert.Equal("p-1", reminder.MessageId);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1800000000000), reminder.RemindAt);
    }

    [Fact]
    public async Task OldMatchingPollDoesNotConfirmANewWriteWhoseResponseWasLost()
    {
        using var fixture = new Fixture("JSON") { Failure = "network" };
        fixture.SeedOldPoll();
        var draft = new ChatPollDraft("c-1", "Synthetic question", ["One", "Two"], false, false, Guid.NewGuid());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.CreatePollAsync(draft)).Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Chat.CreatePollAsync(draft)).Result.Status);
        Assert.Single(fixture.Calls, call => call["api"] == "SYNO.Chat.Post.Vote");
        fixture.PollId = "new-poll";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Chat.CreatePollAsync(draft)).Result.Status);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly string _format;
        private readonly NasProfile _profile;
        private readonly Dictionary<string, ApiCapability> _capabilities;
        public IChatRepository Chat { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public string Build { get; init; } = "69057";
        public string? Failure { get; init; }
        public long? ReminderTime { get; set; }
        public long? ScheduleTime { get; set; }
        private string? _scheduleText;
        private JsonObject? _poll;
        public string PollId { get; set; } = "poll-2";
        public bool ForeignOwner { get; init; }
        public bool MissingList { get; init; }
        public bool SingleReminder { get; init; }
        public bool MetadataDenied { get; init; }
        public bool WrongPollOwner { get; set; }
        public Fixture(string format, bool jsonCore = false, Action<Dictionary<string, ApiCapability>>? configure = null)
        {
            _format = format;
            _http = new(new Handler(this));
            _profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
            _capabilities = new[] { ("SYNO.Chat.User", 3), ("SYNO.Chat.Channel", 5), ("SYNO.Chat.Post", 8),
                ("SYNO.Chat.Post.Reminder", 1), ("SYNO.Chat.Post.Schedule", 1), ("SYNO.Chat.Post.Vote", 1),
                ("SYNO.Core.Desktop.Initdata", 1), ("SYNO.Core.Package", 2) }
                .ToDictionary(item => item.Item1, item => new ApiCapability(item.Item1, "entry.cgi", 1, item.Item2,
                    item.Item1 is "SYNO.Chat.User" or "SYNO.Chat.Channel" or "SYNO.Chat.Post" ? jsonCore ? "JSON" : "FORM" : format));
            configure?.Invoke(_capabilities);
            Chat = Reconnect();
        }
        public IChatRepository Reconnect(string sid = "synthetic-sid", bool wrongProfile = false) =>
            new DsmRepository(_profile, new(wrongProfile ? Guid.NewGuid() : _profile.Id, sid, "synthetic-token", null), new DsmApiClient(_http), _capabilities);
        public void SeedOldPoll()
        {
            PollId = "old-poll";
            _poll = new() { ["question"] = "Synthetic question", ["choices"] = new JsonArray("One", "Two"), ["options"] = "{\"multiple\":false,\"anonymous\":false}" };
        }
        private JsonObject Reply(Dictionary<string, string> call)
        {
            string Text(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
            switch (call["api"])
            {
                case "SYNO.Core.Desktop.Initdata": return new() { ["Session"] = new JsonObject { ["productversion"] = "7.2.1", ["version"] = Build, ["smallfixnumber"] = "12" } };
                case "SYNO.Core.Package": return new() { ["packages"] = new JsonArray(new JsonObject { ["id"] = "Chat", ["version"] = "2.4.1-22111" }) };
                case "SYNO.Chat.User": return new() { ["current_user_id"] = "u-1", ["users"] = new JsonArray(new JsonObject { ["user_id"] = "u-1", ["nickname"] = "Self", ["is_login"] = true }) };
                case "SYNO.Chat.Channel": return new() { ["channels"] = new JsonArray(new JsonObject { ["channel_id"] = "c-1", ["type"] = "private", ["name"] = "Synthetic group" }) };
                case "SYNO.Chat.Post":
                    var post = new JsonObject { ["post_id"] = _poll is null ? "p-1" : PollId, ["channel_id"] = "c-1", ["creator_id"] = WrongPollOwner ? "u-2" : "u-1", ["is_my_post"] = !WrongPollOwner, ["message"] = _poll?["question"]?.GetValue<string>() ?? "Synthetic text", ["create_at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
                    if (_poll is not null) post["vote"] = _poll.DeepClone();
                    return new() { ["posts"] = new JsonArray(post), ["offset"] = 0, ["total"] = 1 };
                case "SYNO.Chat.Post.Reminder":
                    if (call["method"] == "set") ReminderTime = long.Parse(Text("remind_at"));
                    if (call["method"] == "delete") ReminderTime = null;
                    if (MissingList) return new();
                    if (SingleReminder && ReminderTime is { } singleAt) return new() { ["post_id"] = "p-1", ["reminde_at"] = singleAt, ["props"] = new JsonObject { ["type"] = "synthetic" } };
                    return new() { ["reminders"] = ReminderTime is { } at ? new JsonArray(new JsonObject { ["post_id"] = "p-1", ["channel_id"] = ForeignOwner ? "other" : "c-1", ["remind_at"] = at }) : new JsonArray() };
                case "SYNO.Chat.Post.Schedule":
                    if (call["method"] == "create") { ScheduleTime = long.Parse(Text("send_at")); _scheduleText = Text("message"); }
                    if (call["method"] == "delete") ScheduleTime = null;
                    return new() { ["cronjob_id"] = "s-1", ["schedules"] = ScheduleTime is { } time ? new JsonArray(new JsonObject { ["cronjob_id"] = "s-1", ["channel_id"] = "c-1", ["message"] = _scheduleText, ["send_at"] = time }) : new JsonArray() };
                case "SYNO.Chat.Post.Vote":
                    _poll = new() { ["question"] = Text("message"), ["choices"] = JsonNode.Parse(call["choices"]), ["options"] = Text("options") };
                    return new() { ["post_id"] = PollId };
                default: throw new InvalidOperationException("unexpected synthetic request");
            }
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.Equal("nas.invalid", request.RequestUri.Host);
                var body = await request.Content!.ReadAsStringAsync(cancellationToken);
                var call = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Equal("synthetic-token", call["SynoToken"]);
                owner.Calls.Add(call);
                if (call["api"] == "SYNO.Core.Package" && owner.MetadataDenied)
                    return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                if (call["method"] == "set" && owner.Failure == "network") throw new HttpRequestException();
                if (call["api"] == "SYNO.Chat.Post.Vote" && owner.Failure == "network") throw new HttpRequestException();
                if (call["method"] == "set" && owner.Failure == "http") return new(HttpStatusCode.BadGateway);
                var response = new JsonObject { ["success"] = true, ["data"] = owner.Reply(call) };
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
