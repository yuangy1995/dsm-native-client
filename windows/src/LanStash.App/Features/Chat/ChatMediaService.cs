using LanStash.Domain;

namespace LanStash.App.Features.Chat;

/// <summary>媒体只按原会话及消息的附件身份读取，内容缓存在本机临时文件，释放播放器后删除。</summary>
public sealed class ChatMediaService
{
    public const long MaximumBytes = 512L * 1024 * 1024;

    public async Task<ChatMediaArtifact> ReadAsync(IChatRepository repository, ChatMessageAttachmentItem item,
        CancellationToken cancellationToken = default)
    {
        if (item.Attachment.Kind is not (ChatAttachmentKind.Video or ChatAttachmentKind.Voice) ||
            item.Attachment.SizeBytes is not (> 0 and <= MaximumBytes)) throw new NotSupportedException("chat.media.size-or-kind");
        var conversations = await repository.ListConversationsAsync(cancellationToken);
        if (!conversations.Any(value => value.Id == item.ConversationId && !value.IsEncrypted)) throw new UnauthorizedAccessException("chat.media.conversation");
        var message = await repository.LocateMessageAsync(item.ConversationId, item.MessageId, item.ThreadId, cancellationToken);
        if (message is null || message.EncryptionState != ChatEncryptionState.NotEncrypted ||
            message.Attachments.Count != 1 || message.Attachments[0] != item.Attachment) throw new IOException("chat.media.changed");
        var folder = Path.Combine(Path.GetTempPath(), "LanStashChatMedia-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, "media");
        FileStream? stream = null;
        try
        {
            stream = new(file, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read | FileShare.Delete, 64 * 1024,
                FileOptions.Asynchronous | FileOptions.RandomAccess | FileOptions.DeleteOnClose);
            var result = await repository.SaveAttachmentAsync(item.MessageId, item.Attachment, stream, cancellationToken: cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (result.Status != ChatAttachmentContentReadStatus.Completed || result.BytesWritten != item.Attachment.SizeBytes || stream.Length != item.Attachment.SizeBytes)
                throw new IOException("chat.media.incomplete");
            stream.Position = 0;
            return new(stream, folder, MediaType(item.Attachment));
        }
        catch
        {
            if (stream is not null) await stream.DisposeAsync();
            if (Directory.Exists(folder)) Directory.Delete(folder);
            throw;
        }
    }

    private static string MediaType(ChatAttachment attachment)
    {
        if (attachment.MediaType?.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) == true ||
            attachment.MediaType?.StartsWith("video/", StringComparison.OrdinalIgnoreCase) == true) return attachment.MediaType;
        return Path.GetExtension(attachment.FileName).ToLowerInvariant() switch
        {
            ".mp3" => "audio/mpeg", ".wav" => "audio/wav", ".aac" => "audio/aac", ".m4a" => "audio/mp4",
            ".ogg" => "audio/ogg", ".flac" => "audio/flac", ".webm" => "video/webm", ".mov" => "video/quicktime",
            _ => attachment.Kind == ChatAttachmentKind.Video ? "video/mp4" : "audio/mp4",
        };
    }
}

public sealed class ChatMediaArtifact(FileStream stream, string directory, string mediaType) : IDisposable
{
    private bool _disposed;
    public Stream Stream => stream;
    public string MediaType { get; } = mediaType;
    public void Dispose()
    {
        if (_disposed) return; _disposed = true;
        stream.Dispose();
        if (Directory.Exists(directory)) Directory.Delete(directory);
    }
}
