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
        var completeCapabilities = CapabilitiesWithMembers();
        var complete = CreateRepository(new RecordingApiClient(_ => new()), completeCapabilities);
        var incomplete = CreateRepository(
            new RecordingApiClient(_ => new()),
            Capabilities().Where(pair => pair.Key != "SYNO.Chat.Post")
                .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal));
        var invalidWriteCapabilities = CapabilitiesWithMembers();
        invalidWriteCapabilities["SYNO.Chat.Channel.Anonymous"] =
            new("SYNO.Chat.Channel.Anonymous", "entry.cgi", 1, 1, "FORM");
        invalidWriteCapabilities["SYNO.Chat.Channel.Named"] =
            new("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1, "JSON");
        var invalidWrites = CreateRepository(
            new RecordingApiClient(_ => new()),
            invalidWriteCapabilities);

        Assert.Equal(ChatAvailabilityStatus.Available, complete.Availability.Status);
        Assert.Equal(7, complete.Availability.SupportedFeatures.Count);
        Assert.Contains(ChatReadFeature.PinnedMessages, complete.Availability.SupportedFeatures);
        Assert.Contains(ChatWriteFeature.TextMessage, complete.Availability.SupportedWriteFeatures);
        Assert.Contains(ChatWriteFeature.AttachmentMessage, complete.Availability.SupportedWriteFeatures);
        Assert.Contains(ChatWriteFeature.DirectConversation, complete.Availability.SupportedWriteFeatures);
        Assert.Contains(ChatWriteFeature.PrivateGroup, complete.Availability.SupportedWriteFeatures);
        Assert.Contains(AppModule.Chat, complete.AvailableModules);
        Assert.Equal(ChatAvailabilityStatus.Unavailable, incomplete.Availability.Status);
        Assert.Empty(incomplete.Availability.SupportedFeatures);
        Assert.Empty(incomplete.Availability.SupportedWriteFeatures);
        Assert.DoesNotContain(AppModule.Chat, incomplete.AvailableModules);
        Assert.DoesNotContain(
            ChatWriteFeature.DirectConversation,
            invalidWrites.Availability.SupportedWriteFeatures);
        Assert.DoesNotContain(
            ChatWriteFeature.PrivateGroup,
            invalidWrites.Availability.SupportedWriteFeatures);
    }

    [Fact]
    public void MembersCapabilityIsOptionalAndRequiresVersionOneCoverage()
    {
        var exactCapabilities = Capabilities();
        exactCapabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 1, "FORM");
        var overlappingCapabilities = Capabilities();
        overlappingCapabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 3, "FORM");
        var unsupportedCapabilities = Capabilities();
        unsupportedCapabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 2, 3, "FORM");
        var nonFormCapabilities = Capabilities();
        nonFormCapabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 1, "JSON");

        var withoutMembers = CreateRepository(new RecordingApiClient(_ => new()));
        var exact = CreateRepository(new RecordingApiClient(_ => new()), exactCapabilities);
        var overlapping = CreateRepository(new RecordingApiClient(_ => new()), overlappingCapabilities);
        var unsupported = CreateRepository(new RecordingApiClient(_ => new()), unsupportedCapabilities);
        var nonForm = CreateRepository(new RecordingApiClient(_ => new()), nonFormCapabilities);

        Assert.Equal(ChatAvailabilityStatus.Available, withoutMembers.Availability.Status);
        Assert.DoesNotContain(ChatReadFeature.Members, withoutMembers.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatWriteFeature.PrivateGroup,
            withoutMembers.Availability.SupportedWriteFeatures);
        Assert.Contains(ChatReadFeature.Members, exact.Availability.SupportedFeatures);
        Assert.Contains(ChatReadFeature.Members, overlapping.Availability.SupportedFeatures);
        Assert.DoesNotContain(ChatReadFeature.Members, unsupported.Availability.SupportedFeatures);
        Assert.DoesNotContain(ChatReadFeature.Members, nonForm.Availability.SupportedFeatures);
    }

    [Fact]
    public async Task MembersWireUsesVersionOneGetThenPreservesKnownUserOrder()
    {
        var users = Users();
        Assert.IsType<JsonArray>(users["users"]).Add(new JsonObject
        {
            ["user_id"] = "u-broken",
            ["nickname"] = "Broken",
        });
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.Channel.Member" => new JsonObject
            {
                ["user_ids"] = new JsonArray("u-2", "u-unknown", "u-1", "u-broken"),
                ["broken_user_ids"] = new JsonArray("u-broken"),
            },
            "SYNO.Chat.User" => users,
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 3, "FORM");
        var repository = CreateRepository(api, capabilities);

        var members = await repository.ListConversationMembersAsync(" channel-1 ");

        Assert.Equal(new[] { "u-2", "u-1" }, members.Select(member => member.Id));
        Assert.False(members[0].IsCurrentUser);
        Assert.True(members[1].IsCurrentUser);
        Assert.Collection(
            api.Requests,
            request =>
            {
                AssertWire(request, "SYNO.Chat.Channel.Member", "get", 1, 1);
                Assert.Equal("channel-1", request.Parameters["channel_id"]);
                Assert.Equal("entry.cgi", request.Path);
                Assert.Equal("FORM", request.RequestFormat);
            },
            request => AssertWire(request, "SYNO.Chat.User", "list", 3, 0));
    }

    [Fact]
    public async Task EmptyOrOnlyBrokenMembersDoNotReadUserDirectory()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.Channel.Member" => new JsonObject
            {
                ["user_ids"] = new JsonArray("u-broken"),
                ["broken_user_ids"] = new JsonArray("u-broken"),
            },
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 1, "FORM");
        var repository = CreateRepository(api, capabilities);

        var members = await repository.ListConversationMembersAsync("channel-1");

        Assert.Empty(members);
        var request = Assert.Single(api.Requests);
        AssertWire(request, "SYNO.Chat.Channel.Member", "get", 1, 1);
    }

    [Fact]
    public async Task MissingMembersCapabilityIssuesNoRequests()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var repository = CreateRepository(api);

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.ListConversationMembersAsync("channel-1"));

        Assert.Equal(ChatAvailabilityStatus.Available, repository.Availability.Status);
        Assert.DoesNotContain(ChatReadFeature.Members, repository.Availability.SupportedFeatures);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public void PinnedMessagesCapabilityRequiresVersionFiveAndFormRequests()
    {
        var unsupportedCapabilities = Capabilities();
        unsupportedCapabilities["SYNO.Chat.Post"] =
            new("SYNO.Chat.Post", "entry.cgi", 1, 4, "FORM");
        var nonFormCapabilities = Capabilities();
        nonFormCapabilities["SYNO.Chat.Post"] =
            new("SYNO.Chat.Post", "entry.cgi", 1, 8, "JSON");

        var supported = CreateRepository(new RecordingApiClient(_ => new()));
        var unsupported = CreateRepository(
            new RecordingApiClient(_ => new()),
            unsupportedCapabilities);
        var nonForm = CreateRepository(
            new RecordingApiClient(_ => new()),
            nonFormCapabilities);

        Assert.Contains(ChatReadFeature.PinnedMessages, supported.Availability.SupportedFeatures);
        Assert.DoesNotContain(ChatReadFeature.PinnedMessages, unsupported.Availability.SupportedFeatures);
        Assert.DoesNotContain(ChatReadFeature.PinnedMessages, nonForm.Availability.SupportedFeatures);
    }

    [Fact]
    public async Task PinnedMessagesUseBoundedVersionFiveSearchAndWhitelistResponse()
    {
        var api = new RecordingApiClient(_ => new JsonObject
        {
            ["search_results"] = new JsonArray(
                new JsonObject
                {
                    ["post_id"] = "older",
                    ["channel_id"] = "channel-1",
                    ["creator_id"] = "u-2",
                    ["creator_name"] = "Other",
                    ["create_at"] = 10,
                    ["last_pin_at"] = 20,
                    ["message"] = "Older announcement",
                    ["files"] = new JsonArray(new JsonObject { ["name"] = "private.bin" }),
                    ["server_path"] = "/private/path",
                },
                new JsonObject
                {
                    ["post_id"] = "newer",
                    ["channel_id"] = "channel-1",
                    ["creator_id"] = "u-1",
                    ["create_at"] = 11,
                    ["last_pin_at"] = 30,
                    ["message"] = "Newer announcement",
                },
                new JsonObject
                {
                    ["post_id"] = "not-pinned",
                    ["channel_id"] = "channel-1",
                    ["message"] = "Not pinned",
                })
        });

        var values = await CreateRepository(api).ListPinnedMessagesAsync(" channel-1 ");

        Assert.Equal(new[] { "newer", "older" }, values.Select(value => value.Id));
        Assert.Equal("Other", values[1].SenderDisplayName);
        Assert.Equal("Older announcement", values[1].Text);
        var request = Assert.Single(api.Requests);
        AssertWire(request, "SYNO.Chat.Post", "search", 5, 6);
        Assert.Equal("channel-1", request.Parameters["channel_id"]);
        Assert.Equal("0", request.Parameters["offset"]);
        Assert.Equal("100", request.Parameters["limit"]);
        Assert.Equal("[\"pin\"]", request.Parameters["has"]);
        Assert.Equal("last_pin_at", request.Parameters["sort_by"]);
        Assert.Equal("[\"is_sticky\",\"last_pin_at\"]", request.Parameters["sort_by_array"]);
    }

    [Fact]
    public async Task PinnedMessagesRejectForeignConversationAndUnsupportedContractBeforeTransport()
    {
        var foreignApi = new RecordingApiClient(_ => new JsonObject
        {
            ["posts"] = new JsonArray(new JsonObject
            {
                ["post_id"] = "foreign",
                ["channel_id"] = "channel-2",
                ["last_pin_at"] = 20,
            })
        });
        await Assert.ThrowsAsync<DsmException>(() =>
            CreateRepository(foreignApi).ListPinnedMessagesAsync("channel-1"));

        var unsupportedCapabilities = Capabilities();
        unsupportedCapabilities["SYNO.Chat.Post"] =
            new("SYNO.Chat.Post", "entry.cgi", 1, 4, "FORM");
        var unsupportedApi = new RecordingApiClient(_ => throw new InvalidOperationException());
        await Assert.ThrowsAsync<DsmException>(() =>
            CreateRepository(unsupportedApi, unsupportedCapabilities)
                .ListPinnedMessagesAsync("channel-1"));

        Assert.Single(foreignApi.Requests);
        Assert.Empty(unsupportedApi.Requests);
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
    public async Task TextSendRequiresPostV5ButLeavesReadAvailable()
    {
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Post"] =
            capabilities["SYNO.Chat.Post"] with { MinVersion = 1, MaxVersion = 4 };
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var repository = CreateRepository(api, capabilities);

        var result = await repository.SendTextAsync(
            new ChatTextSendRequest("channel-1", "hello", Guid.NewGuid()));

        Assert.Equal(ChatAvailabilityStatus.Available, repository.Availability.Status);
        Assert.DoesNotContain(ChatWriteFeature.TextMessage, repository.Availability.SupportedWriteFeatures);
        Assert.Equal(MutationResultStatus.Unsupported, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task TextSendUsesFixedPostV5AndConfirmsByReadback()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" when request.Method == "create" => new JsonObject
            {
                ["post_id"] = "sent-1",
            },
            "SYNO.Chat.Post" => Posts(0, 1, MyMessage("sent-1", "hello")),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);
        var requestId = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");

        var result = await repository.SendTextAsync(
            new ChatTextSendRequest("channel-1", " hello ", requestId));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.True(result.Result.Submitted);
        Assert.False(result.Result.RequiresRefresh);
        Assert.Equal("sent-1", result.ConfirmedMessage?.Id);
        Assert.Collection(
            api.Requests,
            request => AssertWire(request, "SYNO.Chat.User", "list", 3, 0),
            request => AssertWire(request, "SYNO.Chat.Channel", "list", 5, 0),
            request =>
            {
                AssertWire(request, "SYNO.Chat.Post", "create", 5, 2);
                Assert.Equal("channel-1", request.Parameters["channel_id"]);
                Assert.Equal("hello", request.Parameters["message"]);
            },
            request =>
            {
                AssertWire(request, "SYNO.Chat.Post", "list", 8, 3);
                Assert.Equal("channel-1", request.Parameters["channel_id"]);
            });
    }

    [Fact]
    public async Task TextSendMissingStableIdRequiresReviewAndSameRequestDoesNotCreateAgain()
    {
        var postListCalls = 0;
        var api = new RecordingApiClient(request =>
        {
            if (request.ApiName == "SYNO.Chat.User")
            {
                return Users();
            }
            if (request.ApiName == "SYNO.Chat.Channel")
            {
                return Channels();
            }
            if (request.Method == "create")
            {
                return new JsonObject();
            }
            postListCalls++;
            return Posts(0, 0);
        });
        var repository = CreateRepository(api);
        var request = new ChatTextSendRequest(
            "channel-1",
            "check me",
            Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"));

        var first = await repository.SendTextAsync(request);
        var second = await repository.SendTextAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(2, postListCalls);
        Assert.Equal(1, api.Requests.Count(value =>
            value.ApiName == "SYNO.Chat.Post" && value.Method == "create"));
    }

    [Fact]
    public async Task TextSendCancelledBeforeSubmissionSendsNothing()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = await CreateRepository(api).SendTextAsync(
            new ChatTextSendRequest("channel-1", "hello", Guid.NewGuid()),
            cancellation.Token);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task AttachmentSendRequiresPostV5ButLeavesReadAvailable()
    {
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Post"] =
            capabilities["SYNO.Chat.Post"] with { MinVersion = 1, MaxVersion = 4 };
        capabilities["SYNO.Chat.Post.File"] = new(
            "SYNO.Chat.Post.File",
            "entry.cgi",
            1,
            2,
            "FORM");
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        var opens = 0;
        var repository = CreateRepository(api, capabilities);

        var result = await repository.SendAttachmentAsync(
            new ChatAttachmentSendRequest(
                "channel-1",
                null,
                new ChatAttachmentSource(
                    "photo.jpg",
                    "image/jpeg",
                    4,
                    _ =>
                    {
                        opens++;
                        return Task.FromResult<Stream>(new MemoryStream([0x01, 0x02, 0x03, 0x04]));
                    }),
                Guid.NewGuid()));

        Assert.Equal(ChatAvailabilityStatus.Available, repository.Availability.Status);
        Assert.DoesNotContain(
            ChatWriteFeature.AttachmentMessage,
            repository.Availability.SupportedWriteFeatures);
        Assert.Contains(
            ChatReadFeature.AttachmentThumbnail,
            repository.Availability.SupportedFeatures);
        Assert.Contains(
            ChatReadFeature.AttachmentContent,
            repository.Availability.SupportedFeatures);
        Assert.Equal(MutationResultStatus.Unsupported, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.Equal(0, opens);
        Assert.Empty(api.Requests);
        Assert.Empty(api.AttachmentRequests);
    }

    [Fact]
    public async Task AttachmentSendUsesDedicatedV5TransportAndConfirmsExactReadback()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" => Posts(
                0,
                1,
                MyAttachmentMessage("file-post-1", null, "photo.jpg", 4)),
            _ => throw new InvalidOperationException(request.ApiName),
        })
        {
            AttachmentResponse = _ => new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.Accepted,
                CandidateMessageId: "file-post-1"),
        };
        var repository = CreateRepository(api);
        var reports = new List<long>();

        var result = await repository.SendAttachmentAsync(
            new ChatAttachmentSendRequest(
                "channel-1",
                null,
                new ChatAttachmentSource(
                    "photo.jpg",
                    "image/jpeg",
                    4,
                    _ => Task.FromResult<Stream>(new MemoryStream([0x00, 0x01, 0xFE, 0xFF]))),
                Guid.Parse("cccccccc-cccc-cccc-cccc-cccccccccccc")),
            new InlineProgress(reports.Add));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.True(result.Result.Submitted);
        Assert.False(result.Result.RequiresRefresh);
        Assert.Equal("file-post-1", result.ConfirmedMessage?.Id);
        Assert.Equal(new[] { 0L, 4L }, reports);
        var sent = Assert.Single(api.AttachmentRequests);
        Assert.Equal("SYNO.Chat.Post", sent.ApiName);
        Assert.Equal(5, sent.MinimumVersion);
        Assert.Equal(5, sent.MaximumVersion);
        Assert.Equal("channel-1", sent.ConversationId);
        Assert.Equal(string.Empty, sent.Message);
        Assert.Equal("photo.jpg", sent.FileName);
        Assert.Equal(4L, sent.Length);
        Assert.Equal(new byte[] { 0x00, 0x01, 0xFE, 0xFF }, sent.Content);
        Assert.Collection(
            api.Requests,
            request => AssertWire(request, "SYNO.Chat.User", "list", 3, 0),
            request => AssertWire(request, "SYNO.Chat.Channel", "list", 5, 0),
            request => AssertWire(request, "SYNO.Chat.Post", "list", 8, 3));
        Assert.DoesNotContain(api.Requests, request => request.Method == "create");
    }

    [Fact]
    public async Task AttachmentSendMismatchedReadbackRemainsReviewOnlyAndNeverResends()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" => ReadMismatchedAttachment(),
            _ => throw new InvalidOperationException(request.ApiName),
        })
        {
            AttachmentResponse = _ => new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.Accepted,
                CandidateMessageId: "file-post-2"),
        };
        var repository = CreateRepository(api);
        var opens = 0;
        var request = new ChatAttachmentSendRequest(
            "channel-1",
            "caption",
            new ChatAttachmentSource(
                "photo.jpg",
                "image/jpeg",
                4,
                _ =>
                {
                    opens++;
                    return Task.FromResult<Stream>(new MemoryStream([0x01, 0x02, 0x03, 0x04]));
                }),
            Guid.Parse("dddddddd-dddd-dddd-dddd-dddddddddddd"));

        JsonObject ReadMismatchedAttachment() =>
            Posts(0, 1, MyAttachmentMessage("file-post-2", "caption", "other.jpg", 4));

        var first = await repository.SendAttachmentAsync(request);
        var second = await repository.SendAttachmentAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(1, opens);
        Assert.Single(api.AttachmentRequests);
        Assert.Equal(2, api.Requests.Count(request => request.ApiName == "SYNO.Chat.Post"));
    }

    [Fact]
    public async Task AttachmentSendCancelledBeforeSubmissionCanBeRetriedExplicitly()
    {
        var results = new Queue<ChatAttachmentUploadTransportResult>([
            new(ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission),
            new(ChatAttachmentUploadTransportStatus.Accepted, CandidateMessageId: "file-post-3"),
        ]);
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" => Posts(
                0,
                1,
                MyAttachmentMessage("file-post-3", string.Empty, "note.txt", 3)),
            _ => throw new InvalidOperationException(request.ApiName),
        })
        {
            AttachmentResponse = _ => results.Dequeue(),
        };
        var repository = CreateRepository(api);
        var opens = 0;
        var request = new ChatAttachmentSendRequest(
            "channel-1",
            null,
            new ChatAttachmentSource(
                "note.txt",
                "text/plain",
                3,
                _ =>
                {
                    opens++;
                    return Task.FromResult<Stream>(new MemoryStream([0x01, 0x02, 0x03]));
                }),
            Guid.Parse("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"));

        var first = await repository.SendAttachmentAsync(request);
        var second = await repository.SendAttachmentAsync(request);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(2, opens);
        Assert.Equal(2, api.AttachmentRequests.Count);
    }

    [Fact]
    public async Task AttachmentSendCancellationAfterSubmissionUsesOnlyReadbackOnRetry()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => Channels(),
            "SYNO.Chat.Post" => Posts(
                0,
                1,
                MyAttachmentMessage("file-post-4", "caption", "note.txt", 3)),
            _ => throw new InvalidOperationException(request.ApiName),
        })
        {
            AttachmentResponse = _ => new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.CancellationRequestedAfterSubmission,
                CandidateMessageId: "file-post-4",
                ErrorCategory: MutationErrorCategory.Network),
        };
        var repository = CreateRepository(api);
        var opens = 0;
        var request = new ChatAttachmentSendRequest(
            "channel-1",
            "caption",
            new ChatAttachmentSource(
                "note.txt",
                "text/plain",
                3,
                _ =>
                {
                    opens++;
                    return Task.FromResult<Stream>(new MemoryStream([0x01, 0x02, 0x03]));
                }),
            Guid.Parse("ffffffff-ffff-ffff-ffff-ffffffffffff"));

        var first = await repository.SendAttachmentAsync(request);
        var second = await repository.SendAttachmentAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.True(first.Result.Submitted);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(1, opens);
        Assert.Single(api.AttachmentRequests);
        Assert.Single(api.Requests, request => request.ApiName == "SYNO.Chat.Post");
    }

    [Fact]
    public async Task AttachmentSendCancellationBeforeOpeningSourceSendsNothing()
    {
        var api = new RecordingApiClient(_ => throw new InvalidOperationException());
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var opens = 0;

        var result = await CreateRepository(api).SendAttachmentAsync(
            new ChatAttachmentSendRequest(
                "channel-1",
                null,
                new ChatAttachmentSource(
                    "note.txt",
                    "text/plain",
                    1,
                    _ =>
                    {
                        opens++;
                        return Task.FromResult<Stream>(new MemoryStream([0x01]));
                    }),
                Guid.NewGuid()),
            cancellationToken: cancellation.Token);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Result.Status);
        Assert.False(result.Result.Submitted);
        Assert.Equal(0, opens);
        Assert.Empty(api.Requests);
        Assert.Empty(api.AttachmentRequests);
    }

    [Fact]
    public async Task DirectConversationUsesFixedAnonymousContractAndNeverReplaysTheSameRequest()
    {
        var channelReads = 0;
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => ++channelReads == 1
                ? new JsonObject { ["channels"] = new JsonArray() }
                : new JsonObject
                {
                    ["channels"] = new JsonArray(new JsonObject
                    {
                        ["channel_id"] = "direct-new",
                        ["type"] = "anonymous",
                        ["members"] = new JsonArray("u-1", "u-2"),
                    }),
                },
            "SYNO.Chat.Channel.Anonymous" => new JsonObject { ["channel_id"] = "direct-new" },
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);
        var request = new ChatDirectConversationRequest("u-2", Guid.NewGuid());

        var first = await repository.OpenDirectConversationAsync(request);
        var second = await repository.OpenDirectConversationAsync(request);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, first.Result.Status);
        Assert.Equal("direct-new", first.ConfirmedConversation?.Id);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        var mutation = Assert.Single(
            api.Requests,
            value => value.ApiName == "SYNO.Chat.Channel.Anonymous");
        AssertWire(mutation, "SYNO.Chat.Channel.Anonymous", "initiate", 2, 3);
        Assert.Equal("[\"u-2\"]", mutation.Parameters["user_ids"]);
        Assert.Equal("false", mutation.Parameters["encrypted"]);
        Assert.Equal("[]", mutation.Parameters["channel_key_encs"]);
    }

    [Fact]
    public async Task PrivateGroupCreatesJoinsInvitesAndConfirmsAllSelectedMembers()
    {
        var channelReads = 0;
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => GroupUsers(),
            "SYNO.Chat.Channel" => ++channelReads == 1
                ? new JsonObject { ["channels"] = new JsonArray() }
                : new JsonObject
                {
                    ["channels"] = new JsonArray(new JsonObject
                    {
                        ["channel_id"] = "group-new",
                        ["type"] = "private",
                        ["name"] = "Project",
                    }),
                },
            "SYNO.Chat.Channel.Named" when request.Method == "create" =>
                new JsonObject { ["channel_id"] = "group-new" },
            "SYNO.Chat.Channel.Named" => new JsonObject(),
            "SYNO.Chat.Channel.Member" => new JsonObject
            {
                ["user_ids"] = new JsonArray("u-1", "u-2", "u-3"),
                ["broken_user_ids"] = new JsonArray(),
            },
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api, CapabilitiesWithMembers());

        var result = await repository.CreatePrivateGroupAsync(
            new ChatPrivateGroupCreateRequest(
                " Project ",
                ["u-3", "u-2", "u-3"],
                Guid.NewGuid()));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("group-new", result.ConfirmedConversation?.Id);
        var writes = api.Requests
            .Where(value => value.ApiName == "SYNO.Chat.Channel.Named")
            .ToArray();
        Assert.Collection(
            writes,
            request =>
            {
                AssertWire(request, "SYNO.Chat.Channel.Named", "create", 1, 2);
                Assert.Equal("Project", request.Parameters["name"]);
                Assert.Equal("private", request.Parameters["type"]);
            },
            request =>
            {
                AssertWire(request, "SYNO.Chat.Channel.Named", "join", 1, 1);
                Assert.Equal("group-new", request.Parameters["channel_id"]);
            },
            request =>
            {
                AssertWire(request, "SYNO.Chat.Channel.Named", "invite", 1, 3);
                Assert.Equal("[\"u-2\",\"u-3\"]", request.Parameters["user_ids"]);
                Assert.Equal("[]", request.Parameters["channel_key_encs"]);
            });
    }

    [Fact]
    public async Task UnknownDirectConversationResultOnlyReadsBackAndNeverReplays()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => new JsonObject { ["channels"] = new JsonArray() },
            "SYNO.Chat.Channel.Anonymous" => throw new HttpRequestException("failed"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);
        var request = new ChatDirectConversationRequest("u-2", Guid.NewGuid());

        var first = await repository.OpenDirectConversationAsync(request);
        var second = await repository.OpenDirectConversationAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Single(api.Requests, value => value.ApiName == "SYNO.Chat.Channel.Anonymous");
    }

    [Fact]
    public async Task PendingRequestIdCannotBeReusedForAnotherDirectConversationDraft()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => GroupUsers(),
            "SYNO.Chat.Channel" => new JsonObject { ["channels"] = new JsonArray() },
            "SYNO.Chat.Channel.Anonymous" => throw new HttpRequestException("failed"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);
        var requestId = Guid.NewGuid();

        var first = await repository.OpenDirectConversationAsync(
            new ChatDirectConversationRequest("u-2", requestId));
        var mismatched = await repository.OpenDirectConversationAsync(
            new ChatDirectConversationRequest("u-3", requestId));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, mismatched.Result.Status);
        Assert.Equal(MutationErrorCategory.Validation, mismatched.Result.ErrorCategory);
        Assert.Single(api.Requests, value => value.ApiName == "SYNO.Chat.Channel.Anonymous");
    }

    [Fact]
    public async Task ExplicitDirectConversationRejectionReturnsTypedFailureWithoutPendingReview()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => Users(),
            "SYNO.Chat.Channel" => new JsonObject { ["channels"] = new JsonArray() },
            "SYNO.Chat.Channel.Anonymous" =>
                throw new DsmException("denied", "ask administrator", 105),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api);

        var outcome = await repository.OpenDirectConversationAsync(
            new ChatDirectConversationRequest("u-2", Guid.NewGuid()));

        Assert.Equal(MutationResultStatus.PermissionDenied, outcome.Result.Status);
        Assert.True(outcome.Result.Submitted);
        Assert.False(outcome.Result.RequiresRefresh);
        Assert.Equal(MutationErrorCategory.Permission, outcome.Result.ErrorCategory);
        Assert.Single(api.Requests, value => value.ApiName == "SYNO.Chat.Channel.Anonymous");
    }

    [Fact]
    public async Task UnknownPrivateGroupResultOnlyReadsBackAndNeverReplaysAnyWriteStage()
    {
        var api = new RecordingApiClient(request => request.ApiName switch
        {
            "SYNO.Chat.User" => GroupUsers(),
            "SYNO.Chat.Channel" => new JsonObject { ["channels"] = new JsonArray() },
            "SYNO.Chat.Channel.Named" when request.Method == "create" =>
                new JsonObject { ["channel_id"] = "group-pending" },
            "SYNO.Chat.Channel.Named" when request.Method == "join" => new JsonObject(),
            "SYNO.Chat.Channel.Named" when request.Method == "invite" =>
                throw new DsmException("failed", "retry", 500),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = CreateRepository(api, CapabilitiesWithMembers());
        var request = new ChatPrivateGroupCreateRequest(
            "Project",
            ["u-2", "u-3"],
            Guid.NewGuid());

        var first = await repository.CreatePrivateGroupAsync(request);
        var second = await repository.CreatePrivateGroupAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Equal(
            new[] { "create", "join", "invite" },
            api.Requests
                .Where(value => value.ApiName == "SYNO.Chat.Channel.Named")
                .Select(value => value.Method));
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
        ["SYNO.Chat.Channel.Anonymous"] =
            new("SYNO.Chat.Channel.Anonymous", "entry.cgi", 1, 2, "FORM"),
        ["SYNO.Chat.Channel.Named"] =
            new("SYNO.Chat.Channel.Named", "entry.cgi", 1, 1, "FORM"),
    };

    private static Dictionary<string, ApiCapability> CapabilitiesWithMembers()
    {
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Channel.Member"] =
            new("SYNO.Chat.Channel.Member", "entry.cgi", 1, 1, "FORM");
        return capabilities;
    }

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

    private static JsonObject GroupUsers()
    {
        var users = Users();
        Assert.IsType<JsonArray>(users["users"]).Add(new JsonObject
        {
            ["user_id"] = "u-3",
            ["nickname"] = "Third",
        });
        return users;
    }

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

    private static JsonObject MyMessage(
        string id,
        string? text,
        long sentAt = 1,
        string channelId = "channel-1")
    {
        var message = Message(id, text, sentAt, channelId);
        message["creator_id"] = "u-1";
        message["is_my_post"] = true;
        return message;
    }

    private static JsonObject MyAttachmentMessage(
        string id,
        string? text,
        string fileName,
        long size)
    {
        var message = MyMessage(id, text);
        message["files"] = new JsonArray(new JsonObject
        {
            ["file_id"] = $"{id}-file",
            ["name"] = fileName,
            ["content_type"] = "application/octet-stream",
            ["size"] = size,
        });
        return message;
    }

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
        string Path,
        string RequestFormat,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed record AttachmentRequest(
        string ApiName,
        int MinimumVersion,
        int MaximumVersion,
        string ConversationId,
        string Message,
        string FileName,
        long Length,
        byte[] Content);

    private sealed class RecordingApiClient(Func<ApiRequest, JsonObject> response) : IDsmApiClient
    {
        public List<ApiRequest> Requests { get; } = [];
        public List<AttachmentRequest> AttachmentRequests { get; } = [];
        public Func<AttachmentRequest, ChatAttachmentUploadTransportResult>? AttachmentResponse { get; init; }

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
                capability.Path,
                capability.RequestFormat,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            int requiredVersion,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new ApiRequest(
                capability.Name,
                method,
                requiredVersion,
                capability.Path,
                capability.RequestFormat,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

        public async Task<ChatAttachmentUploadTransportResult> SendChatAttachmentAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            ChatAttachmentUploadRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(0);
            await using var copy = new MemoryStream();
            await request.Content.CopyToAsync(copy, cancellationToken).ConfigureAwait(false);
            progress?.Report(request.Length);
            var captured = new AttachmentRequest(
                capability.Name,
                capability.MinVersion,
                capability.MaxVersion,
                request.ConversationId,
                request.Message,
                request.FileName,
                request.Length,
                copy.ToArray());
            AttachmentRequests.Add(captured);
            return AttachmentResponse?.Invoke(captured) ?? new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "chat.attachment-send.unsupported");
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

    private sealed class InlineProgress(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
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
