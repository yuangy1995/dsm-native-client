using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Synology Chat 内部只读接口适配器。仅使用已记录的 User.list、Channel.list、
/// Channel.Member.get 与 Post.list。
/// </summary>
public sealed partial class DsmRepository
{
    private const int ChatMemberReadVersion = 1;
    private const int ChatPinnedMessageReadVersion = 5;
    private const int ChatTextSendVersion = 5;




    private static readonly IReadOnlyDictionary<string, (int Minimum, int Maximum)> ChatReadVersions =
        new Dictionary<string, (int Minimum, int Maximum)>(StringComparer.Ordinal)
        {
            ["SYNO.Chat.User"] = (1, 3),
            ["SYNO.Chat.Channel"] = (1, 5),
            ["SYNO.Chat.Channel.Member"] = (1, 1),
            ["SYNO.Chat.Post"] = (5, 5),
        };

    private static readonly IReadOnlySet<ChatReadFeature> ChatReadFeatures =
        new HashSet<ChatReadFeature>
        {
            ChatReadFeature.Users,
            ChatReadFeature.Conversations,
            ChatReadFeature.Messages,
            ChatReadFeature.AttachmentMetadata,
            ChatReadFeature.EncryptedContentMetadata,
        };

    private bool HasReadableChatContract =>
        HasVerifiedChatVersion("SYNO.Chat.User") &&
        HasVerifiedChatVersion("SYNO.Chat.Channel") &&
        HasVerifiedChatVersion("SYNO.Chat.Post");

    private bool HasTextMessageSendContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post", ChatTextSendVersion);

    private bool HasConversationMembersContract =>
        HasReadableChatContract &&
        _capabilities.TryGetValue("SYNO.Chat.Channel.Member", out var capability) &&
        capability.MinVersion <= ChatMemberReadVersion &&
        capability.MaxVersion >= ChatMemberReadVersion &&
        capability.Name == "SYNO.Chat.Channel.Member" && HasChatConversationFormat(capability);

    private bool HasPinnedMessageReadContract =>
        HasReadableChatContract && HasAdvancedApi("SYNO.Chat.Post", ChatPinnedMessageReadVersion);

    public ChatAvailability Availability => HasReadableChatContract
        ? new(
            ChatAvailabilityStatus.Available,
            SupportedChatReadFeatures(),
            SupportedChatWriteFeatures())
        : new(
            ChatAvailabilityStatus.Unavailable,
            new HashSet<ChatReadFeature>(),
            new HashSet<ChatWriteFeature>());

    public async Task<IReadOnlyList<ChatUser>> ListUsersAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        var data = await CallChatAsync(
            "SYNO.Chat.User",
            "list",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var currentUserId = ReadChatCurrentUserId(data);
        return ContainerObjects(data, "users", "user", "user_list", "list", "members", "items", "results")
            .Select(item => ParseUser(item, currentUserId))
            .OfType<ChatUser>()
            .ToArray();
    }

    public async Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(
        string conversationId,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        if (!HasConversationMembersContract)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
        var normalizedConversationId = conversationId.Trim();
        var memberData = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            _capabilities["SYNO.Chat.Channel.Member"],
            ChatMemberReadVersion,
            "get",
            new Dictionary<string, string>
            {
                ["channel_id"] = ChatConversationString("SYNO.Chat.Channel.Member", normalizedConversationId),
            },
            cancellationToken).ConfigureAwait(false);
        var memberIds = StableIdArray(memberData, "user_ids");
        var brokenMemberIds = StableIdArray(memberData, "broken_user_ids")
            .ToHashSet(StringComparer.Ordinal);
        var readableMemberIds = memberIds
            .Where(id => !brokenMemberIds.Contains(id))
            .ToArray();
        if (readableMemberIds.Length == 0)
        {
            return [];
        }
        var users = await ListUsersAsync(cancellationToken).ConfigureAwait(false);
        var usersById = users
            .GroupBy(user => user.Id, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);
        return readableMemberIds
            .Select(id => usersById.GetValueOrDefault(id))
            .OfType<ChatUser>()
            .ToArray();
    }

    public async Task<IReadOnlyList<ChatPinnedMessage>> ListPinnedMessagesAsync(
        string conversationId,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        if (!HasPinnedMessageReadContract)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }

        var normalizedConversationId = conversationId.Trim();
        var source = await ReadAllPinnedPayloadAsync(normalizedConversationId, cancellationToken).ConfigureAwait(false);
        var values = new List<ChatPinnedMessage>();
        foreach (var item in source)
        {
            foreach (var key in new[] { "channel_id", "conversation_id" })
            {
                if (item.ContainsKey(key) &&
                    !string.Equals(StableId(item[key]), normalizedConversationId, StringComparison.Ordinal))
                {
                    throw InvalidChatResponse();
                }
            }
            var value = ParsePinnedMessage(item, normalizedConversationId);
            if (value is not null)
            {
                values.Add(value);
            }
        }
        return values.OrderByDescending(value => value.PinnedAt).ToArray();
    }

    public Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(CancellationToken cancellationToken = default) =>
        LoadChatConversationsAsync(requireComplete: false, cancellationToken);

    private async Task<IReadOnlyList<ChatConversation>> LoadChatConversationsAsync(bool requireComplete, CancellationToken cancellationToken)
    {
        EnsureReadableChatContract();
        var usersData = await CallChatAsync(
            "SYNO.Chat.User",
            "list",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var currentUserId = ReadChatCurrentUserId(usersData);
        var userNames = ContainerObjects(
                usersData,
                "users",
                "user",
                "user_list",
                "list",
                "members",
                "items",
                "results")
            .Select(item => ParseUser(item, currentUserId))
            .OfType<ChatUser>()
            .GroupBy(item => item.Id, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First().DisplayName, StringComparer.Ordinal);
        var channelsData = await CallChatAsync(
            "SYNO.Chat.Channel",
            "list",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        string[] roots = ["channels", "channel_list", "items", "results", DsmApiResponseKeys.RootArray];
        if (requireComplete && !roots.Any(key => channelsData[key] is JsonArray or JsonObject)) throw InvalidChatResponse();
        var source = ContainerObjects(channelsData, "channels", "channel_list", "items", "results").ToArray();
        var result = source
            .Select(item => ParseConversation(item, userNames, currentUserId))
            .OfType<ChatConversation>()
            .OrderByDescending(item => item.LastActivityAt ?? DateTimeOffset.MinValue)
            .ToArray();
        if (requireComplete && (result.Length != source.Length || result.Select(item => item.Id).Distinct().Count() != result.Length)) throw InvalidChatResponse();
        return result;
    }

    public Task<ChatMessagePage> ListMessagesAsync(
        string conversationId,
        string? beforeCursor,
        int limit,
        CancellationToken cancellationToken = default) =>
        ListMessagesCoreAsync(conversationId, beforeCursor, limit, cancellationToken);

    private async Task<ChatMessagePage> ListMessagesCoreAsync(string conversationId, string? beforeCursor,
        int limit, CancellationToken cancellationToken, ISet<string>? verifiedIds = null, string? verifiedMessageId = null,
        string? threadId = null)
    {
        EnsureReadableChatContract();
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var normalizedConversationId = conversationId.Trim();
        var safeLimit = Math.Min(limit, 100);
        if (beforeCursor is not null && !ValidAdvancedId(beforeCursor))
            throw new ArgumentException("chat.cursor.invalid", nameof(beforeCursor));
        var parameters = new Dictionary<string, string>
        {
            ["channel_id"] = normalizedConversationId,
            ["thread_id"] = threadId ?? "0",
            ["prev_count"] = safeLimit.ToString(CultureInfo.InvariantCulture),
            ["next_count"] = "0",
        };
        if (beforeCursor is not null) parameters["post_id"] = beforeCursor;
        var data = await CallChatExactVersionAsync(
            "SYNO.Chat.Post",
            "list",
            5,
            parameters,
            cancellationToken).ConfigureAwait(false);
        if (data["posts"] is not JsonArray posts || posts.Count > safeLimit + (beforeCursor is null ? 0 : 1))
            throw InvalidChatResponse();
        int? total = null;
        if (data.TryGetPropertyValue("total", out var rawTotal))
        {
            if (rawTotal is not JsonValue totalValue || !totalValue.TryGetValue<int>(out var count) || count < 0 ||
                (beforeCursor is null && posts.Count == 0 && count > 0)) throw InvalidChatResponse();
            total = count;
        }
        var sourcePosts = posts.Select(node => node as JsonObject ?? throw InvalidChatResponse()).ToArray();
        var pageIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var post in sourcePosts)
        {
            var id = FirstStableId(post, "post_id", "id");
            if (id is null || !pageIds.Add(id)) throw InvalidChatResponse();
            // v5 可能包含定位消息，跨页去重不能把这个已知定位项判成重复内容。
            if (id != beforeCursor && verifiedIds is not null && !verifiedIds.Add(id)) throw InvalidChatResponse();
            foreach (var explicitConversationKey in new[] { "channel_id", "conversation_id" })
            {
                if (post.ContainsKey(explicitConversationKey) &&
                    !string.Equals(
                        StableId(post[explicitConversationKey]),
                        normalizedConversationId,
                        StringComparison.Ordinal))
                {
                    throw InvalidChatResponse();
                }
            }
        }
        var olderPosts = sourcePosts.Where(post => FirstStableId(post, "post_id", "id") != beforeCursor).ToArray();
        if (olderPosts.Length > safeLimit) throw InvalidChatResponse();
        var messages = olderPosts
            .Select(item => ParseMessage(item, normalizedConversationId))
            .OfType<ChatMessage>()
            .OrderBy(item => item.SentAt)
            .ToArray();
        if (verifiedMessageId is not null && olderPosts.Any(item => FirstStableId(item, "post_id", "id") == verifiedMessageId) &&
            !messages.Any(item => item.Id == verifiedMessageId))
            throw InvalidChatResponse();
        if (messages.Any(message => threadId is null ? message.IsThreadReply :
            message.Id != threadId && message.ThreadId != threadId)) throw InvalidChatResponse();
        // 游标来自最早原始记录，辅助记录同样推进分页；不再把偏移量作为消息编号发送。
        var oldest = olderPosts.OrderBy(post => FirstLong(post, "create_at") ?? 0).FirstOrDefault();
        var oldestId = oldest is null ? null : FirstStableId(oldest, "post_id", "id");
        var hasMore = olderPosts.Length == safeLimit && oldestId is not null && oldestId != beforeCursor;
        return new ChatMessagePage(
            threadId is null ? messages : messages.Where(message => message.Id != threadId).ToArray(),
            hasMore ? oldestId : null,
            hasMore,
            0,
            sourcePosts.Length,
            total);
    }

    private void EnsureReadableChatContract()
    {
        if (_profile.Id != _session.ProfileId)
        {
            throw new InvalidOperationException("Chat requests require a session for the active NAS profile.");
        }
        if (!HasReadableChatContract)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
    }

    private bool HasVerifiedChatVersion(string apiName)
    {
        var verified = ChatReadVersions[apiName];
        return _capabilities.TryGetValue(apiName, out var capability) &&
               capability.Name == apiName && capability.MinVersion >= 1 && capability.MaxVersion >= capability.MinVersion && HasChatConversationFormat(capability) &&
               capability.MaxVersion >= verified.Minimum &&
               capability.MinVersion <= verified.Maximum;
    }

    private bool HasExactChatVersion(string apiName, int version) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.Name == apiName && capability.MinVersion >= 1 && capability.MaxVersion >= capability.MinVersion && HasChatConversationFormat(capability) &&
        capability.MinVersion <= version &&
        capability.MaxVersion >= version;

    private Task<JsonObject> CallChatAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        var verified = ChatReadVersions[apiName];
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MaxVersion < verified.Minimum ||
            capability.MinVersion > verified.Maximum)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
        var selectedVersion = Math.Min(capability.MaxVersion, verified.Maximum);
        if (selectedVersion < verified.Minimum || selectedVersion < capability.MinVersion)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                103);
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                MinVersion = selectedVersion,
                MaxVersion = selectedVersion,
            },
            method,
            EncodeChatParameters(capability, parameters),
            cancellationToken);
    }

    private Task<JsonObject> CallChatExactVersionAsync(
        string apiName,
        string method,
        int version,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MinVersion > version ||
            capability.MaxVersion < version)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability with { MinVersion = version, MaxVersion = version },
            method,
            EncodeChatParameters(capability, parameters),
            cancellationToken);
    }

    private static IReadOnlyDictionary<string, string>? EncodeChatParameters(ApiCapability capability,
        IReadOnlyDictionary<string, string>? parameters)
    {
        if (parameters is null || !capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)) return parameters;
        // 这些已有读取/创建方法的字符串字段统一编码一次；数组、布尔与分页数字保持原类型。
        return parameters.ToDictionary(pair => pair.Key, pair => pair.Key is "channel_id" or "thread_id" or "post_id" or "message" or "name" or "type" or "sort_by" or "keyword"
            ? System.Text.Json.JsonSerializer.Serialize(pair.Value) : pair.Value, StringComparer.Ordinal);
    }

    private static ChatUser? ParseUser(JsonObject item, string? currentUserId)
    {
        var id = FirstStableId(item, "user_id", "member_id", "uid", "account_id", "id");
        if (id is null)
        {
            return null;
        }
        var name = FirstNonEmpty(item, "nickname", "display_name", "name", "username") ?? id;
        var explicitCurrent = FirstBool(item, "is_login", "is_current", "is_current_user");
        var avatarAvailable = FirstBool(item, "has_avatar", "avatar_available", "is_avatar_exist");
        return new ChatUser(
            id,
            name,
            avatarAvailable,
            FirstBool(item, "disabled", "is_disabled") ?? false,
            explicitCurrent ?? (currentUserId is null ? null : id == currentUserId));
    }

    private static ChatConversation? ParseConversation(
        JsonObject item,
        IReadOnlyDictionary<string, string> userNames,
        string? currentUserId)
    {
        var id = FirstStableId(item, "channel_id", "id");
        if (id is null)
        {
            return null;
        }
        var members = (item["members"] as JsonArray ?? item["member_ids"] as JsonArray ?? [])
            .Select(member => member is JsonObject memberObject
                ? FirstStableId(memberObject, "user_id", "member_id", "id")
                : StableId(member))
            .Where(member => !string.IsNullOrWhiteSpace(member))
            .Select(member => member!)
            .Distinct(StringComparer.Ordinal)
            .ToArray();
        var type = FirstNonEmpty(item, "type", "channel_type")?.ToLowerInvariant() ?? string.Empty;
        var declaredCount = FirstInt(item, "member_count", "members_count", "total_members");
        var isDirect = type is "direct" or "anonymous" ||
            (string.IsNullOrWhiteSpace(item.String("name")) &&
             (declaredCount ?? members.Length) <= 2 && type != "chatbot");
        var rawName = FirstNonEmpty(item, "name", "channel_name");
        var visibleMemberIds = members.Where(member => member != currentUserId).ToArray();
        if (visibleMemberIds.Length == 0)
        {
            visibleMemberIds = members;
        }
        var title = !isDirect && rawName is not null
            ? rawName
            : string.Join("、", visibleMemberIds.Select(id => userNames.GetValueOrDefault(id, id)));
        var lastPost = item.Object("last_post");
        var encrypted = FirstBool(item, "encrypted", "is_encrypted") ?? false;
        return new ChatConversation(
            id,
            isDirect ? ChatConversationKind.Direct : ChatConversationKind.Group,
            string.IsNullOrWhiteSpace(title) ? id : title,
            members,
            declaredCount ?? (members.Length == 0 ? null : members.Length),
            encrypted ? null : FirstNonEmpty(lastPost, "message", "text", "content")
                ?? FirstNonEmpty(item, "last_message", "last_message_summary", "last_post_message"),
            FirstDate(lastPost, "create_at", "created_at")
                ?? FirstDate(item, "update_at", "last_activity_at"),
            Math.Max(0, FirstInt(item, "unread", "unread_count") ?? 0),
            encrypted) { LastViewedAt = FirstDate(item, "last_view_at") };
    }

    private ChatMessage? ParseMessage(JsonObject item, string fallbackConversationId)
    {
        var id = FirstStableId(item, "post_id", "id");
        if (id is null)
        {
            return null;
        }
        var encrypted = FirstBool(item, "encrypted", "is_encrypted") ?? false;
        var attachments = ParseAttachments(item, id);
        var text = encrypted ? null : FirstNonEmpty(item, "message", "text", "content");
        var poll = encrypted ? null : ParseChatPoll(item, id);
        if (!encrypted && string.IsNullOrWhiteSpace(text) && attachments.Count == 0 && poll is null)
        {
            return null;
        }
        var creator = item.Object("creator") ?? item.Object("user") ?? item.Object("sender");
        var senderId = FirstStableId(item, "creator_id", "user_id", "sender_id")
            ?? StableId(item["creator"])
            ?? FirstStableId(creator, "user_id", "creator_id", "sender_id", "id")
            ?? "unknown";
        var sentAt = FirstDate(item, "create_at", "created_at", "timestamp") ?? DateTimeOffset.UnixEpoch;
        var updatedAt = FirstDate(item, "update_at");
        var explicitMine = FirstBool(item, "is_my_post", "is_mine", "is_current_user")
            ?? FirstBool(creator, "is_login", "is_current", "is_current_user");
        var message = new ChatMessage(
            id,
            FirstStableId(item, "channel_id", "conversation_id") ?? fallbackConversationId,
            senderId,
            FirstNonEmpty(item, "creator_name", "sender_name", "nickname")
                ?? FirstNonEmpty(creator, "nickname", "display_name", "name", "username"),
            explicitMine == false ? false : _chatCurrentUserId is { } currentId ? senderId == currentId : explicitMine,
            sentAt,
            text,
            attachments,
            encrypted ? ChatEncryptionState.Locked : ChatEncryptionState.NotEncrypted)
        {
            Poll = poll,
            Kind = FirstNonEmpty(item, "type") switch
            {
                null or "normal" => ChatMessageKind.Normal,
                "sticker" => ChatMessageKind.Sticker,
                "system" => ChatMessageKind.System,
                _ => ChatMessageKind.Unknown,
            },
            ThreadId = FirstStableId(item, "thread_id") is { } thread && thread != "0" ? thread : null,
            ReplyCount = FirstInt(item, "comment_count") is >= 0 and var count ? count : null,
            EditedAt = updatedAt > sentAt ? updatedAt : null,
        };
        _knownChatMessages[(message.ConversationId, message.Id)] = message;
        return message;
    }

    private static ChatPinnedMessage? ParsePinnedMessage(
        JsonObject item,
        string fallbackConversationId)
    {
        var id = FirstStableId(item, "post_id", "id");
        var rawPinnedAt = FirstLong(item, "last_pin_at", "pinned_at");
        if (id is null || rawPinnedAt is null || rawPinnedAt <= 0)
        {
            return null;
        }
        var pinnedAt = FirstDate(item, "last_pin_at", "pinned_at");
        if (pinnedAt is null)
        {
            return null;
        }
        var creator = item.Object("creator") ?? item.Object("user") ?? item.Object("sender");
        var senderId = FirstStableId(item, "creator_id", "user_id", "sender_id")
            ?? StableId(item["creator"])
            ?? FirstStableId(creator, "user_id", "creator_id", "sender_id", "id")
            ?? "unknown";
        return new ChatPinnedMessage(
            id,
            FirstStableId(item, "channel_id", "conversation_id") ?? fallbackConversationId,
            senderId,
            FirstNonEmpty(item, "creator_name", "sender_name", "nickname", "display_name")
                ?? FirstNonEmpty(creator, "nickname", "display_name", "name", "username"),
            FirstDate(item, "create_at", "created_at", "timestamp") ?? DateTimeOffset.UnixEpoch,
            pinnedAt.Value,
            FirstNonEmpty(item, "message", "text", "content"));
    }

    private static IReadOnlyList<ChatAttachment> ParseAttachments(JsonObject item, string messageId)
    {
        var values = item["files"] as JsonArray ?? item["attachments"] as JsonArray;
        if (values is null && item["file_props"] is JsonObject fileProps)
        {
            values = [fileProps];
        }
        if (values is null)
        {
            return [];
        }
        return values.OfType<JsonObject>().Select((file, index) =>
        {
            var name = FirstNonEmpty(file, "name", "file_name", "filename", "title")
                ?? $"attachment-{index + 1}";
            var mediaType = FirstNonEmpty(file, "content_type", "mime_type", "media_type");
            var extension = (FirstNonEmpty(file, "extension", "type")
                ?? Path.GetExtension(name).TrimStart('.')).ToLowerInvariant();
            var kind = mediaType?.StartsWith("image/", StringComparison.OrdinalIgnoreCase) == true ||
                       new[] { "jpg", "jpeg", "png", "gif", "heic", "webp" }.Contains(extension)
                ? ChatAttachmentKind.Image
                : mediaType?.StartsWith("video/", StringComparison.OrdinalIgnoreCase) == true ||
                  new[] { "mov", "mp4", "m4v", "webm" }.Contains(extension)
                    ? ChatAttachmentKind.Video
                    : mediaType?.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) == true ||
                      new[] { "aac", "m4a", "mp3", "wav", "ogg", "flac" }.Contains(extension) ||
                      FirstBool(file, "is_voice") == true
                        ? ChatAttachmentKind.Voice
                        : ChatAttachmentKind.File;
            var rawSize = FirstLong(file, "size", "file_size", "bytes");
            var rawDuration = FirstLong(file, "duration_ms", "duration");
            return new ChatAttachment(
                FirstStableId(file, "file_id", "id", "uuid") ?? $"{messageId}-attachment-{index}",
                kind,
                name,
                mediaType,
                rawSize is >= 0 ? rawSize : null,
                rawDuration is >= 0 ? rawDuration : null,
                FirstBool(file, "has_thumbnail", "thumbnail_available"));
        }).ToArray();
    }

    private static string? FirstNonEmpty(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(item.String).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value));

    private static bool? FirstBool(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(item.Bool).FirstOrDefault(value => value is not null);

    private static int? FirstInt(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(item.Int).FirstOrDefault(value => value is not null);

    private static long? FirstLong(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(item.Long).FirstOrDefault(value => value is not null);

    private static DateTimeOffset? FirstDate(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(item.Date).FirstOrDefault(value => value is not null);

    private static string? FirstStableId(JsonObject? item, params string[] keys) =>
        item is null ? null : keys.Select(key => StableId(item[key])).FirstOrDefault(value => value is not null);

    private static string? ChatTextCreateMessageId(JsonObject data) =>
        FirstStableId(data, "post_id", "id", "message_id") ??
        FirstStableId(data["post"] as JsonObject, "post_id", "id", "message_id") ??
        FirstStableId(data["message"] as JsonObject, "post_id", "id", "message_id") ??
        ContainerObjects(data, "post", "posts", "items", "results")
            .Select(item => FirstStableId(item, "post_id", "id", "message_id"))
            .FirstOrDefault(value => value is not null);

    private static string? StableId(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<string>(out var text))
        {
            var normalized = text.Trim();
            return normalized.Length == 0 ? null : normalized;
        }
        if (value.TryGetValue<long>(out var longValue))
        {
            return longValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<ulong>(out var unsignedLongValue))
        {
            return unsignedLongValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<int>(out var intValue))
        {
            return intValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<uint>(out var unsignedIntValue))
        {
            return unsignedIntValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<short>(out var shortValue))
        {
            return shortValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<ushort>(out var unsignedShortValue))
        {
            return unsignedShortValue.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<byte>(out var byteValue))
        {
            return byteValue.ToString(CultureInfo.InvariantCulture);
        }
        return value.TryGetValue<sbyte>(out var signedByteValue)
            ? signedByteValue.ToString(CultureInfo.InvariantCulture)
            : null;
    }

    private static IReadOnlyList<string> StableIdArray(JsonObject data, string key)
    {
        if (data[key] is null)
        {
            return [];
        }
        if (data[key] is not JsonArray array)
        {
            throw InvalidChatResponse();
        }
        var values = array.Select(StableId).ToArray();
        if (values.Any(value => value is null))
        {
            throw InvalidChatResponse();
        }
        return values.Select(value => value!).ToArray();
    }

    private static IEnumerable<JsonObject> ContainerObjects(JsonObject data, params string[] keys)
    {
        if (data[DsmApiResponseKeys.RootArray] is JsonArray rootArray)
        {
            if (rootArray.Any(value => value is not JsonObject))
            {
                throw InvalidChatResponse();
            }
            return rootArray.OfType<JsonObject>();
        }
        foreach (var key in keys)
        {
            if (data[key] is JsonArray array)
            {
                if (array.Any(value => value is not JsonObject))
                {
                    throw InvalidChatResponse();
                }
                return array.OfType<JsonObject>();
            }
            if (data[key] is JsonObject dictionary)
            {
                if (dictionary.Any(pair => pair.Value is not JsonObject))
                {
                    throw InvalidChatResponse();
                }
                return dictionary.Select(pair => pair.Value).OfType<JsonObject>();
            }
        }
        return [];
    }

    private static DsmException InvalidChatResponse() => new(
        UserText.Key("WinSharedda35e58bcad31766"),
        UserText.Key("WinSharedefc81ced18eb3bb0"));

}
