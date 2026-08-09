using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Synology Chat 内部只读接口适配器。仅使用已记录的 User.list、Channel.list 与 Post.list。
/// </summary>
public sealed partial class DsmRepository
{
    private static readonly IReadOnlyDictionary<string, (int Minimum, int Maximum)> ChatReadVersions =
        new Dictionary<string, (int Minimum, int Maximum)>(StringComparer.Ordinal)
        {
            ["SYNO.Chat.User"] = (1, 3),
            ["SYNO.Chat.Channel"] = (1, 5),
            ["SYNO.Chat.Post"] = (1, 8),
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

    public ChatAvailability Availability => HasReadableChatContract
        ? new(ChatAvailabilityStatus.Available, ChatReadFeatures)
        : new(ChatAvailabilityStatus.Unavailable, new HashSet<ChatReadFeature>());

    public async Task<IReadOnlyList<ChatUser>> ListUsersAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        var data = await CallChatAsync(
            "SYNO.Chat.User",
            "list",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var currentUserId = FirstStableId(data, "current_user_id", "login_user_id", "my_user_id");
        return ContainerObjects(data, "users", "user", "user_list", "list", "members", "items", "results")
            .Select(item => ParseUser(item, currentUserId))
            .OfType<ChatUser>()
            .ToArray();
    }

    public async Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        var usersData = await CallChatAsync(
            "SYNO.Chat.User",
            "list",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var currentUserId = FirstStableId(
            usersData,
            "current_user_id",
            "login_user_id",
            "my_user_id");
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
        return ContainerObjects(channelsData, "channels", "channel_list", "items", "results")
            .Select(item => ParseConversation(item, userNames, currentUserId))
            .OfType<ChatConversation>()
            .OrderByDescending(item => item.LastActivityAt ?? DateTimeOffset.MinValue)
            .ToArray();
    }

    public async Task<ChatMessagePage> ListMessagesAsync(
        string conversationId,
        string? beforeCursor,
        int limit,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var normalizedConversationId = conversationId.Trim();
        var safeLimit = Math.Min(limit, 100);
        var offset = ParseCursor(beforeCursor);
        var data = await CallChatAsync(
            "SYNO.Chat.Post",
            "list",
            new Dictionary<string, string>
            {
                ["channel_id"] = normalizedConversationId,
                ["limit"] = safeLimit.ToString(CultureInfo.InvariantCulture),
                ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
            },
            cancellationToken).ConfigureAwait(false);
        var sourceOffset = ValidateResponseOffset(data, offset);
        var sourcePosts = ContainerObjects(data, "posts", "post_list", "items", "results").ToArray();
        foreach (var post in sourcePosts)
        {
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
        var messages = sourcePosts
            .Select(item => ParseMessage(item, normalizedConversationId))
            .OfType<ChatMessage>()
            .OrderBy(item => item.SentAt)
            .ToArray();
        var total = data.Int("total");
        var nextOffset = checked(sourceOffset + sourcePosts.Length);
        var hasMore = nextOffset > sourceOffset && (total is not null
            ? nextOffset < Math.Max(0, total.Value)
            : sourcePosts.Length == safeLimit);
        return new ChatMessagePage(
            messages,
            hasMore ? nextOffset.ToString(CultureInfo.InvariantCulture) : null,
            hasMore,
            sourceOffset,
            sourcePosts.Length,
            total is null ? null : Math.Max(0, total.Value));
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
               capability.MaxVersion >= verified.Minimum &&
               capability.MinVersion <= verified.Maximum;
    }

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
            parameters,
            cancellationToken);
    }

    private static int ParseCursor(string? cursor)
    {
        if (cursor is null)
        {
            return 0;
        }
        if (!int.TryParse(cursor, NumberStyles.None, CultureInfo.InvariantCulture, out var offset) ||
            offset < 0)
        {
            throw new ArgumentException("The Chat cursor must be a non-negative server offset.", nameof(cursor));
        }
        return offset;
    }

    private static int ValidateResponseOffset(JsonObject data, int requestedOffset)
    {
        if (!data.ContainsKey("offset"))
        {
            return requestedOffset;
        }
        var responseOffset = data.Int("offset");
        if (responseOffset is null || responseOffset < 0 || responseOffset != requestedOffset)
        {
            throw InvalidChatResponse();
        }
        return responseOffset.Value;
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
            encrypted);
    }

    private static ChatMessage? ParseMessage(JsonObject item, string fallbackConversationId)
    {
        var id = FirstStableId(item, "post_id", "id");
        if (id is null)
        {
            return null;
        }
        var encrypted = FirstBool(item, "encrypted", "is_encrypted") ?? false;
        var attachments = ParseAttachments(item, id);
        var text = encrypted ? null : FirstNonEmpty(item, "message", "text", "content");
        if (!encrypted && string.IsNullOrWhiteSpace(text) && attachments.Count == 0)
        {
            return null;
        }
        var creator = item.Object("creator") ?? item.Object("user") ?? item.Object("sender");
        var senderId = FirstStableId(item, "creator_id", "user_id", "sender_id")
            ?? StableId(item["creator"])
            ?? FirstStableId(creator, "user_id", "creator_id", "sender_id", "id")
            ?? "unknown";
        return new ChatMessage(
            id,
            FirstStableId(item, "channel_id", "conversation_id") ?? fallbackConversationId,
            senderId,
            FirstNonEmpty(item, "creator_name", "sender_name", "nickname")
                ?? FirstNonEmpty(creator, "nickname", "display_name", "name", "username"),
            FirstBool(item, "is_my_post", "is_mine", "is_current_user")
                ?? FirstBool(creator, "is_login", "is_current", "is_current_user"),
            FirstDate(item, "create_at", "created_at", "timestamp") ?? DateTimeOffset.UnixEpoch,
            text,
            attachments,
            encrypted ? ChatEncryptionState.Locked : ChatEncryptionState.NotEncrypted);
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
