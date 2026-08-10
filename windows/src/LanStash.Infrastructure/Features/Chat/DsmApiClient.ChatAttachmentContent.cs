using System.Buffers;
using System.Net;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    private const int ChatAttachmentFileVersion = 2;
    private const int ChatAttachmentReadBufferSize = 64 * 1_024;

    /// <summary>
    /// 使用已记录的 Chat 附件读取契约流式写入调用方提供的目标流。
    /// 仅接受初始为空的可定位目标，失败或取消时清理已写入的部分内容。
    /// </summary>
    public async Task<ChatAttachmentContentReadResult> ReadChatAttachmentContentAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        ChatAttachmentContentReadRequest read,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!ValidChatAttachmentFileCapability(profile, session, capability))
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Unsupported,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "chat.attachment-save.unsupported");
        }
        if (!ValidChatAttachmentContentReadRequest(read))
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Failed,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-save.invalid-input");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.CancelledBeforeRead,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: null,
                DiagnosticTag: "chat.attachment-save.cancelled-before-read");
        }

        Uri endpoint;
        try
        {
            endpoint = ResolveSafeApiUri(profile, capability.Path);
        }
        catch (ArgumentException)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Failed,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-save.invalid-endpoint");
        }
        catch (DsmException)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Failed,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-save.invalid-endpoint");
        }

        var query = string.Join(
            "&",
            new[]
            {
                new KeyValuePair<string, string>("api", capability.Name),
                new KeyValuePair<string, string>("version", "2"),
                new KeyValuePair<string, string>("method", "get"),
                new KeyValuePair<string, string>("post_id", read.MessageId),
            }.Select(pair =>
                $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value)}"));
        var requestUri = new Uri($"{endpoint.AbsoluteUri}?{query}", UriKind.Absolute);
        using var request = new HttpRequestMessage(HttpMethod.Get, requestUri);
        request.Headers.Accept.ParseAdd("application/octet-stream");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        if (cancellationToken.IsCancellationRequested)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.CancelledBeforeRead,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: null,
                DiagnosticTag: "chat.attachment-save.cancelled-before-read");
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.CancelledDuringRead,
                0,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.cancelled-during-read");
        }
        catch (HttpRequestException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                0,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.network-failed");
        }
        catch (IOException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                0,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.network-failed");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return FailedChatAttachmentContentRead(
                    ChatAttachmentContentReadStatus.Failed,
                    0,
                    read.Destination,
                    response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                        ? MutationErrorCategory.Authentication
                        : MutationErrorCategory.Server,
                    "chat.attachment-save.http-failed");
            }
            if (IsJsonMediaType(response.Content.Headers.ContentType?.MediaType))
            {
                return FailedChatAttachmentContentRead(
                    ChatAttachmentContentReadStatus.Failed,
                    0,
                    read.Destination,
                    MutationErrorCategory.Server,
                    "chat.attachment-save.response-invalid");
            }
            if (response.Content.Headers.ContentLength is { } declaredLength &&
                declaredLength != read.ExpectedLength)
            {
                return FailedChatAttachmentContentRead(
                    ChatAttachmentContentReadStatus.Failed,
                    0,
                    read.Destination,
                    MutationErrorCategory.Server,
                    "chat.attachment-save.length-mismatch");
            }

            return await CopyChatAttachmentContentAsync(
                response.Content,
                read,
                progress,
                cancellationToken).ConfigureAwait(false);
        }
    }

    private static bool ValidChatAttachmentFileCapability(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability) =>
        profile.Id == session.ProfileId &&
        !string.IsNullOrWhiteSpace(session.Sid) &&
        string.Equals(capability.Name, "SYNO.Chat.Post.File", StringComparison.Ordinal) &&
        capability.MinVersion <= ChatAttachmentFileVersion &&
        capability.MaxVersion >= ChatAttachmentFileVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase) &&
        IsSafeWebApiPath(capability.Path);

    private static bool ValidChatAttachmentContentReadRequest(
        ChatAttachmentContentReadRequest? read)
    {
        if (read is null ||
            string.IsNullOrWhiteSpace(read.MessageId) ||
            read.MessageId != read.MessageId.Trim() ||
            read.MessageId.IndexOfAny(['\r', '\n', '\0']) >= 0 ||
            read.ExpectedLength < 0 ||
            read.Destination is null)
        {
            return false;
        }
        try
        {
            return read.Destination.CanWrite &&
                read.Destination.CanSeek &&
                read.Destination.Position == 0 &&
                read.Destination.Length == 0;
        }
        catch (Exception error) when (
            error is IOException or NotSupportedException or ObjectDisposedException)
        {
            return false;
        }
    }

    private async Task<ChatAttachmentContentReadResult> CopyChatAttachmentContentAsync(
        HttpContent content,
        ChatAttachmentContentReadRequest read,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        long written = 0;
        progress?.Report(0);
        try
        {
            await using var source = await content.ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            var buffer = ArrayPool<byte>.Shared.Rent(ChatAttachmentReadBufferSize);
            try
            {
                while (true)
                {
                    var count = await source.ReadAsync(
                        buffer.AsMemory(0, buffer.Length),
                        cancellationToken).ConfigureAwait(false);
                    if (count == 0)
                    {
                        break;
                    }
                    if (count > read.ExpectedLength - written)
                    {
                        return FailedChatAttachmentContentRead(
                            ChatAttachmentContentReadStatus.Failed,
                            written,
                            read.Destination,
                            MutationErrorCategory.Server,
                            "chat.attachment-save.length-mismatch");
                    }
                    await read.Destination.WriteAsync(
                        buffer.AsMemory(0, count),
                        cancellationToken).ConfigureAwait(false);
                    written += count;
                    progress?.Report(written);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
        }
        catch (OperationCanceledException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.CancelledDuringRead,
                written,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.cancelled-during-read");
        }
        catch (HttpRequestException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                written,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.network-failed");
        }
        catch (IOException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                written,
                read.Destination,
                MutationErrorCategory.Network,
                "chat.attachment-save.io-failed");
        }
        catch (Exception error) when (
            error is NotSupportedException or ObjectDisposedException)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                written,
                read.Destination,
                MutationErrorCategory.Validation,
                "chat.attachment-save.destination-failed");
        }

        if (written != read.ExpectedLength)
        {
            return FailedChatAttachmentContentRead(
                ChatAttachmentContentReadStatus.Failed,
                written,
                read.Destination,
                MutationErrorCategory.Server,
                "chat.attachment-save.length-mismatch");
        }
        return new ChatAttachmentContentReadResult(
            ChatAttachmentContentReadStatus.Completed,
            written,
            DestinationWasCleared: false,
            ErrorCategory: null,
            DiagnosticTag: "chat.attachment-save.completed");
    }

    private static ChatAttachmentContentReadResult FailedChatAttachmentContentRead(
        ChatAttachmentContentReadStatus status,
        long bytesWritten,
        Stream destination,
        MutationErrorCategory errorCategory,
        string diagnosticTag)
    {
        var cleared = TryClearChatAttachmentDestination(destination);
        return new ChatAttachmentContentReadResult(
            status,
            bytesWritten,
            DestinationWasCleared: cleared,
            ErrorCategory: errorCategory,
            DiagnosticTag: cleared ? diagnosticTag : $"{diagnosticTag}.cleanup-failed");
    }

    private static bool TryClearChatAttachmentDestination(Stream destination)
    {
        try
        {
            if (!destination.CanWrite || !destination.CanSeek)
            {
                return false;
            }
            destination.Position = 0;
            destination.SetLength(0);
            destination.Position = 0;
            return true;
        }
        catch (Exception error) when (
            error is IOException or NotSupportedException or ObjectDisposedException)
        {
            return false;
        }
    }

    private static bool IsJsonMediaType(string? mediaType) =>
        mediaType is not null &&
        (mediaType.Equals("application/json", StringComparison.OrdinalIgnoreCase) ||
         mediaType.EndsWith("+json", StringComparison.OrdinalIgnoreCase));
}
