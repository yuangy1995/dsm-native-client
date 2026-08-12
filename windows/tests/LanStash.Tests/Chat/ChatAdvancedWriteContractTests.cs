using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatAdvancedWriteContractTests
{
    private static readonly Guid ProfileId = Guid.NewGuid();

    [Fact]
    public async Task AdvancedWritesStayClosedAndSendNoRequests()
    {
        var api = new RecordingApi();
        var repository = new DsmRepository(
            new NasProfile(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester"),
            new DsmSession(ProfileId, "synthetic-sid", null, null),
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.Chat.Post.Reminder"] = Capability("SYNO.Chat.Post.Reminder", 1),
                ["SYNO.Chat.Post.Schedule"] = Capability("SYNO.Chat.Post.Schedule", 1),
                ["SYNO.Chat.Post.Vote"] = Capability("SYNO.Chat.Post.Vote", 1),
                ["SYNO.Chat.Post"] = Capability("SYNO.Chat.Post", 5),
            });
        var chat = (IChatRepository)repository;

        var reminder = await chat.SetReminderAsync(
            "synthetic-post", "synthetic-channel", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid());
        var schedule = await chat.CreateScheduledMessageAsync(new ChatScheduledMessageDraft(
            "synthetic-channel", "message", DateTimeOffset.UtcNow.AddHours(1), Guid.NewGuid()));
        var poll = await chat.CreatePollAsync(new ChatPollDraft(
            "synthetic-channel", "question", ["one", "two"], true, false, Guid.NewGuid()));
        var forward = await chat.ForwardMessageAsync(new ChatForwardRequest(
            "synthetic-post", "synthetic-channel", ["other-channel"], Guid.NewGuid()));

        Assert.Equal(MutationResultStatus.Unsupported, reminder.Result.Status);
        Assert.Equal(MutationResultStatus.Unsupported, schedule.Result.Status);
        Assert.Equal(MutationResultStatus.Unsupported, poll.Result.Status);
        Assert.Equal(MutationResultStatus.Unsupported, forward.Status);
        Assert.Null(reminder.ConfirmedReminder);
        Assert.Null(schedule.ConfirmedMessage);
        Assert.Null(poll.ConfirmedMessage);
        Assert.Equal(0, api.CallCount);
    }

    private static ApiCapability Capability(string name, int version) =>
        new(name, "entry.cgi", version, version, "FORM");

    private sealed class RecordingApi : IDsmApiClient
    {
        public int CallCount { get; private set; }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DsmSession> LoginAsync(
            NasProfile profile, string password, string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile, DsmSession session,
            CancellationToken cancellationToken = default) => Task.CompletedTask;

        public Task<JsonObject> CallAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string method, IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return Task.FromResult(new JsonObject());
        }

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return Task.FromResult(new JsonObject());
        }

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string remotePath, long offset, long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
