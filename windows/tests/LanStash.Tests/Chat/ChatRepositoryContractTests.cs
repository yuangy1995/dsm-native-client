using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatRepositoryContractTests
{
    [Fact]
    public void AvailabilityRequiresUserChannelAndPostTogether()
    {
        var complete = CreateRepository(new RecordingApiClient(_ => new()), Capabilities());
        var incomplete = CreateRepository(
            new RecordingApiClient(_ => new()),
            Capabilities().Where(pair => pair.Key != "SYNO.Chat.Post")
                .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal));

        Assert.Equal(ChatAvailabilityStatus.Available, complete.Availability.Status);
        Assert.Equal(5, complete.Availability.SupportedFeatures.Count);
        Assert.Contains(AppModule.Chat, complete.AvailableModules);
        Assert.Equal(ChatAvailabilityStatus.Unavailable, incomplete.Availability.Status);
        Assert.Empty(incomplete.Availability.SupportedFeatures);
        Assert.DoesNotContain(AppModule.Chat, incomplete.AvailableModules);
    }

    [Fact]
    public async Task UserAndConversationWireUsesOnlyRecordedListMethods()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        IChatRepository repository = CreateRepository(api);

        var users = await repository.ListUsersAsync();
        var conversations = await repository.ListConversationsAsync();

        Assert.Equal(ProfileId, repository.ProfileId);
        Assert.Equal("Current", users[0].DisplayName);
        Assert.True(users[0].IsCurrentUser);
        var conversation = Assert.Single(conversations);
        Assert.Equal(ChatConversationKind.Direct, conversation.Kind);
        Assert.Equal("Other", conversation.Title);
        Assert.Equal("hello", conversation.LastMessageSummary);
        Assert.Collection(
            api.Requests,
            request => AssertWire(request, "SYNO.Chat.User", "list", 3, 0),
            request => AssertWire(request, "SYNO.Chat.User", "list", 3, 0),
            request => AssertWire(request, "SYNO.Chat.Channel", "list", 5, 0));
        Assert.DoesNotContain(api.Requests, request => request.Method == "get");
    }

    [Fact]
    public async Task PostWireUsesExactChannelLimitAndRawOffsetParameters()
    {
        var api = new RecordingApiClient(request => Posts(
            7,
            20,
            Message("p-1", "visible"),
            Auxiliary("helper"),
            Message("p-2", "visible too")));

        var page = await CreateRepository(api).ListMessagesAsync("channel-1", "7", 250);

        var request = Assert.Single(api.Requests);
        AssertWire(request, "SYNO.Chat.Post", "list", 8, 3);
        Assert.Equal("channel-1", request.Parameters["channel_id"]);
        Assert.Equal("100", request.Parameters["limit"]);
        Assert.Equal("7", request.Parameters["offset"]);
        Assert.Equal(7, page.SourceOffset);
        Assert.Equal(3, page.SourceRecordCount);
        Assert.Equal(20, page.SourceTotal);
        Assert.Equal("10", page.PreviousCursor);
        Assert.True(page.HasMoreBefore);
        Assert.Equal(new[] { "p-1", "p-2" }, page.Messages.Select(message => message.Id));
    }

    [Fact]
    public async Task DuplicateMessageIdsAreNotCollapsedOrUsedAsCursor()
    {
        var api = new RecordingApiClient(_ => Posts(
            0,
            4,
            Message("same", "first", 2),
            Message("same", "second", 1),
            Auxiliary("helper")));

        var page = await CreateRepository(api).ListMessagesAsync("channel-1", null, 3);

        Assert.Equal(new[] { "same", "same" }, page.Messages.Select(message => message.Id));
        Assert.Equal(new[] { "second", "first" }, page.Messages.Select(message => message.Text));
        Assert.Equal(3, page.SourceRecordCount);
        Assert.Equal("3", page.PreviousCursor);
    }

    [Fact]
    public async Task EncryptedContentIsLockedAndNeverExposedAsPlaintext()
    {
        var encryptedMessage = Message("secret", "must-not-leak");
        encryptedMessage["encrypted"] = true;
        var encryptedChannel = Channels();
        var channel = Assert.IsType<JsonObject>(Assert.Single(
            Assert.IsType<JsonArray>(encryptedChannel["channels"]!)));
        channel["encrypted"] = true;
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => encryptedChannel,
            "SYNO.Chat.Post" => Posts(0, 1, encryptedMessage),
            _ => throw new InvalidOperationException(),
        });
        var repository = CreateRepository(api);

        var conversation = Assert.Single(await repository.ListConversationsAsync());
        var message = Assert.Single((await repository.ListMessagesAsync("channel-1", null, 20)).Messages);

        Assert.True(conversation.IsEncrypted);
        Assert.Null(conversation.LastMessageSummary);
        Assert.Equal(ChatEncryptionState.Locked, message.EncryptionState);
        Assert.Null(message.Text);
    }

    [Fact]
    public async Task AttachmentMetadataIsTypedWithoutFetchingBinaryContent()
    {
        var message = Message("post-file", null);
        message["files"] = new JsonArray(new JsonObject
        {
            ["file_id"] = "file-1",
            ["name"] = "photo.jpg",
            ["content_type"] = "image/jpeg",
            ["size"] = 1234,
            ["duration_ms"] = -1,
            ["has_thumbnail"] = true,
        });
        var api = new RecordingApiClient(_ => Posts(0, 1, message));

        var attachment = Assert.Single(
            Assert.Single((await CreateRepository(api).ListMessagesAsync("channel-1", null, 20)).Messages)
                .Attachments);

        Assert.Equal("file-1", attachment.Id);
        Assert.Equal(ChatAttachmentKind.Image, attachment.Kind);
        Assert.Equal("image/jpeg", attachment.MediaType);
        Assert.Equal(1234, attachment.SizeBytes);
        Assert.Null(attachment.DurationMilliseconds);
        Assert.True(attachment.ThumbnailAvailable);
        Assert.Single(api.Requests);
    }

    [Fact]
    public async Task NumericStableIdsAndKnownObjectContainersAreMappedInvariantly()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => NumericUsersInObjectContainer(),
            "SYNO.Chat.Channel" => NumericChannelsInObjectContainer(),
            "SYNO.Chat.Post" => NumericPostsInObjectContainer(),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);

        var users = await repository.ListUsersAsync();
        var conversation = Assert.Single(await repository.ListConversationsAsync());
        var page = await repository.ListMessagesAsync(" 10 ", "5", 20);
        var message = Assert.Single(page.Messages);
        var attachment = Assert.Single(message.Attachments);

        Assert.Equal(new[] { "1", "2" }, users.Select(user => user.Id));
        Assert.True(users[0].IsCurrentUser);
        Assert.Equal("10", conversation.Id);
        Assert.Equal(new[] { "1", "2" }, conversation.MemberIds);
        Assert.Equal("100", message.Id);
        Assert.Equal("10", message.ConversationId);
        Assert.Equal("2", message.SenderId);
        Assert.Equal("300", attachment.Id);
        var postRequest = api.Requests.Last();
        Assert.Equal("10", postRequest.Parameters["channel_id"]);
    }

    [Fact]
    public async Task NonIntegerNumericIdIsNotInventedAsStableMessageId()
    {
        var post = Message("temporary", "must-not-be-mapped");
        post["post_id"] = 1.5;
        var api = new RecordingApiClient(_ => Posts(0, 2, post));

        var page = await CreateRepository(api).ListMessagesAsync("channel-1", null, 20);

        Assert.Empty(page.Messages);
        Assert.Equal(1, page.SourceRecordCount);
        Assert.Equal("1", page.PreviousCursor);
    }

    [Fact]
    public async Task MissingPostConversationUsesTrimmedRequestConversation()
    {
        var post = Message("post-1", "visible");
        post.Remove("channel_id");
        var api = new RecordingApiClient(_ => Posts(0, 1, post));

        var message = Assert.Single(
            (await CreateRepository(api).ListMessagesAsync(" channel-1 ", null, 20)).Messages);

        Assert.Equal("channel-1", message.ConversationId);
        Assert.Equal("channel-1", Assert.Single(api.Requests).Parameters["channel_id"]);
    }

    [Fact]
    public async Task ForeignPostConversationRejectsWholePageWithoutAdvancingOffset()
    {
        var call = 0;
        var api = new RecordingApiClient(_ =>
        {
            call++;
            return call == 1
                ? Posts(5, 9, Message("foreign", "must-not-leak", channelId: "channel-2"))
                : Posts(5, 6, Message("safe", "visible", channelId: "channel-1"));
        });
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListMessagesAsync("channel-1", "5", 20));
        var retry = await repository.ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(new[] { "5", "5" }, api.Requests.Select(request => request.Parameters["offset"]));
        Assert.Equal(5, retry.SourceOffset);
        Assert.Equal("safe", Assert.Single(retry.Messages).Id);
        Assert.DoesNotContain(retry.Messages, message => message.Text == "must-not-leak");
    }

    [Fact]
    public async Task ConflictingExplicitConversationAliasesRejectWholePageWithoutAdvancingOffset()
    {
        var call = 0;
        var api = new RecordingApiClient(_ =>
        {
            call++;
            if (call == 1)
            {
                var untrusted = Message("foreign", "must-not-leak", channelId: "channel-1");
                untrusted["conversation_id"] = "channel-2";
                return Posts(5, 9, untrusted);
            }
            return Posts(5, 6, Message("safe", "visible", channelId: "channel-1"));
        });
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListMessagesAsync(" channel-1 ", "5", 20));
        var retry = await repository.ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(new[] { "5", "5" }, api.Requests.Select(request => request.Parameters["offset"]));
        Assert.Equal(5, retry.SourceOffset);
        Assert.Equal("safe", Assert.Single(retry.Messages).Id);
        Assert.DoesNotContain(retry.Messages, message => message.Text == "must-not-leak");
    }

    [Fact]
    public async Task NonObjectRawPostRejectsWholePageWithoutAdvancingOffset()
    {
        var call = 0;
        var api = new RecordingApiClient(_ =>
        {
            call++;
            if (call == 1)
            {
                return new JsonObject
                {
                    ["offset"] = 5,
                    ["total"] = 9,
                    ["posts"] = new JsonArray(
                        Message("untrusted", "must-not-leak"),
                        "invalid-raw-record"),
                };
            }
            return Posts(5, 6, Message("safe", "visible"));
        });
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListMessagesAsync("channel-1", "5", 20));
        var retry = await repository.ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(new[] { "5", "5" }, api.Requests.Select(request => request.Parameters["offset"]));
        Assert.Equal(5, retry.SourceOffset);
        Assert.Equal("safe", Assert.Single(retry.Messages).Id);
        Assert.DoesNotContain(retry.Messages, message => message.Text == "must-not-leak");
    }

    [Fact]
    public async Task NonObjectDictionaryPostRejectsWholePageWithoutAdvancingOffset()
    {
        var call = 0;
        var api = new RecordingApiClient(_ =>
        {
            call++;
            if (call == 1)
            {
                return new JsonObject
                {
                    ["offset"] = 5,
                    ["total"] = 9,
                    ["post_list"] = new JsonObject
                    {
                        ["safe-shaped"] = Message("untrusted", "must-not-leak"),
                        ["bad-raw"] = "invalid-raw-record",
                    },
                };
            }
            return Posts(5, 6, Message("safe", "visible"));
        });
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListMessagesAsync("channel-1", "5", 20));
        var retry = await repository.ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(new[] { "5", "5" }, api.Requests.Select(request => request.Parameters["offset"]));
        Assert.Equal(5, retry.SourceOffset);
        Assert.Equal("safe", Assert.Single(retry.Messages).Id);
        Assert.DoesNotContain(retry.Messages, message => message.Text == "must-not-leak");
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(4)]
    [InlineData(6)]
    public async Task InvalidResponseOffsetRejectsWholePageWithoutAdvancing(int responseOffset)
    {
        var call = 0;
        var api = new RecordingApiClient(_ =>
        {
            call++;
            return call == 1
                ? Posts(responseOffset, 8, Message("untrusted", "must-not-leak"))
                : Posts(5, 6, Message("safe", "visible"));
        });
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListMessagesAsync("channel-1", "5", 20));
        var retry = await repository.ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(new[] { "5", "5" }, api.Requests.Select(request => request.Parameters["offset"]));
        Assert.Equal(5, retry.SourceOffset);
        Assert.Equal("safe", Assert.Single(retry.Messages).Id);
        Assert.DoesNotContain(retry.Messages, message => message.Text == "must-not-leak");
    }

    [Fact]
    public async Task MissingResponseOffsetUsesRequestedOffset()
    {
        var response = Posts(5, 8, Message("safe", "visible"));
        response.Remove("offset");
        var api = new RecordingApiClient(_ => response);

        var page = await CreateRepository(api).ListMessagesAsync("channel-1", "5", 20);

        Assert.Equal(5, page.SourceOffset);
        Assert.Equal("6", page.PreviousCursor);
    }

    [Theory]
    [InlineData("")]
    [InlineData("-1")]
    [InlineData("not-an-offset")]
    public async Task InvalidServerCursorIsRejectedBeforeTransport(string cursor)
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());

        await Assert.ThrowsAsync<ArgumentException>(() =>
            CreateRepository(api).ListMessagesAsync("channel-1", cursor, 20));

        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task MissingReadCapabilityFailsBeforeTransport()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var capabilities = Capabilities();
        capabilities.Remove("SYNO.Chat.User");
        var repository = CreateRepository(api, capabilities);

        var error = await Assert.ThrowsAsync<DsmException>(() => repository.ListConversationsAsync());

        Assert.Equal(102, error.Code);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task ChatWireClampsDiscoveredMaximumToRecordedVersionRange()
    {
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.User"] = new("SYNO.Chat.User", "entry.cgi", 3, 99, "FORM");
        capabilities["SYNO.Chat.Channel"] = new("SYNO.Chat.Channel", "entry.cgi", 5, 99, "FORM");
        capabilities["SYNO.Chat.Post"] = new("SYNO.Chat.Post", "entry.cgi", 8, 99, "FORM");
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" => Posts(0, 1, Message("safe", "visible")),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api, capabilities);

        _ = await repository.ListUsersAsync();
        _ = await repository.ListConversationsAsync();
        _ = await repository.ListMessagesAsync("channel-1", null, 20);

        Assert.Equal(new[] { 3, 3, 5, 8 }, api.Requests.Select(request => request.Version));
    }

    [Theory]
    [InlineData("SYNO.Chat.User", 4, 6)]
    [InlineData("SYNO.Chat.Channel", 6, 9)]
    [InlineData("SYNO.Chat.Post", 9, 12)]
    public async Task CapabilityRangeWithoutRecordedIntersectionDisablesChatAndSendsNothing(
        string apiName,
        int minimum,
        int maximum)
    {
        var capabilities = Capabilities();
        var current = capabilities[apiName];
        capabilities[apiName] = current with { MinVersion = minimum, MaxVersion = maximum };
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var repository = CreateRepository(api, capabilities);

        Assert.Equal(ChatAvailabilityStatus.Unavailable, repository.Availability.Status);
        Assert.DoesNotContain(AppModule.Chat, repository.AvailableModules);
        await Assert.ThrowsAsync<DsmException>(() => repository.ListUsersAsync());
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task HttpRootArrayEnvelopeFlowsThroughStableTransportKeyIntoUsers()
    {
        string? requestBody = null;
        using var handler = new StubHttpMessageHandler(async (request, cancellationToken) =>
        {
            requestBody = await request.Content!.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    """{"success":true,"data":[{"user_id":1,"nickname":"Root User"}]}""",
                    Encoding.UTF8,
                    "application/json"),
            };
        });
        using var http = new HttpClient(handler);
        var repository = new DsmRepository(
            Profile(),
            Session(),
            new DsmApiClient(http),
            Capabilities());

        var user = Assert.Single(await repository.ListUsersAsync());

        Assert.Equal("1", user.Id);
        Assert.Equal("Root User", user.DisplayName);
        Assert.Contains("version=3", requestBody ?? string.Empty);
    }

    [Fact]
    public async Task CancellationStopsBeforeTransport()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CreateRepository(api).ListMessagesAsync("channel-1", null, 20, cancellation.Token));

        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task ForeignProfileSessionFailsBeforeTransport()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var repository = new DsmRepository(
            Profile(),
            Session() with { ProfileId = Guid.NewGuid() },
            api,
            Capabilities());

        await Assert.ThrowsAsync<InvalidOperationException>(() => repository.ListUsersAsync());

        Assert.Empty(api.Requests);
    }

    private static readonly Guid ProfileId =
        Guid.Parse("22222222-2222-2222-2222-222222222222");

    private static DsmRepository CreateRepository(
        RecordingApiClient api,
        IReadOnlyDictionary<string, ApiCapability>? capabilities = null) =>
        new(Profile(), Session(), api, capabilities ?? Capabilities());

    private static NasProfile Profile() =>
        new(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester");

    private static DsmSession Session() =>
        new(ProfileId, "synthetic-sid", "synthetic-token", null);

    private static Dictionary<string, ApiCapability> Capabilities() => new(StringComparer.Ordinal)
    {
        ["SYNO.Chat.User"] = new("SYNO.Chat.User", "entry.cgi", 1, 3, "FORM"),
        ["SYNO.Chat.Channel"] = new("SYNO.Chat.Channel", "entry.cgi", 1, 5, "FORM"),
        ["SYNO.Chat.Post"] = new("SYNO.Chat.Post", "entry.cgi", 1, 8, "FORM"),
    };

    private static JsonObject Users() => new()
    {
        ["current_user_id"] = "u-1",
        ["users"] = new JsonArray(
            new JsonObject
            {
                ["user_id"] = "u-1",
                ["nickname"] = "Current",
                ["is_login"] = true,
            },
            new JsonObject
            {
                ["user_id"] = "u-2",
                ["nickname"] = "Other",
            }),
    };

    private static JsonObject Channels() => new()
    {
        ["channels"] = new JsonArray(new JsonObject
        {
            ["channel_id"] = "channel-1",
            ["type"] = "direct",
            ["members"] = new JsonArray("u-1", "u-2"),
            ["unread"] = 2,
            ["last_post"] = new JsonObject
            {
                ["message"] = "hello",
                ["create_at"] = 2,
            },
        }),
    };

    private static JsonObject Posts(int offset, int total, params JsonObject[] posts) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["posts"] = new JsonArray(posts.Select(post => (JsonNode)post).ToArray()),
    };

    private static JsonObject Message(
        string id,
        string? text,
        long sentAt = 1,
        string channelId = "channel-1") => new()
    {
        ["post_id"] = id,
        ["channel_id"] = channelId,
        ["creator_id"] = "u-2",
        ["create_at"] = sentAt,
        ["message"] = text,
    };

    private static JsonObject Auxiliary(string id) => new()
    {
        ["post_id"] = id,
        ["channel_id"] = "channel-1",
        ["creator_id"] = "system",
        ["create_at"] = 3,
    };

    private static JsonObject NumericUsersInObjectContainer() => new()
    {
        ["current_user_id"] = 1,
        ["user_list"] = new JsonObject
        {
            ["current"] = new JsonObject
            {
                ["user_id"] = 1,
                ["nickname"] = "Current",
            },
            ["other"] = new JsonObject
            {
                ["user_id"] = 2,
                ["nickname"] = "Other",
            },
        },
    };

    private static JsonObject NumericChannelsInObjectContainer() => new()
    {
        ["channel_list"] = new JsonObject
        {
            ["direct"] = new JsonObject
            {
                ["channel_id"] = 10,
                ["type"] = "direct",
                ["members"] = new JsonArray(1, 2),
            },
        },
    };

    private static JsonObject NumericPostsInObjectContainer() => new()
    {
        ["offset"] = 5,
        ["total"] = 6,
        ["post_list"] = new JsonObject
        {
            ["message"] = new JsonObject
            {
                ["post_id"] = 100,
                ["channel_id"] = 10,
                ["creator_id"] = 2,
                ["create_at"] = 1,
                ["message"] = "visible",
                ["files"] = new JsonArray(new JsonObject
                {
                    ["file_id"] = 300,
                    ["name"] = "photo.jpg",
                }),
            },
        },
    };

    private static void AssertWire(
        ApiRequest request,
        string apiName,
        string method,
        int version,
        int parameterCount)
    {
        Assert.Equal(apiName, request.ApiName);
        Assert.Equal(method, request.Method);
        Assert.Equal(version, request.Version);
        Assert.Equal(parameterCount, request.Parameters.Count);
    }

    private sealed record ApiRequest(
        string ApiName,
        string Method,
        int Version,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class RecordingApiClient(Func<ApiRequest, JsonObject> response) : IDsmApiClient
    {
        public List<ApiRequest> Requests { get; } = [];

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ApiRequest(
                capability.Name,
                method,
                capability.MaxVersion,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) :
        HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => response(request, cancellationToken);
    }
}
