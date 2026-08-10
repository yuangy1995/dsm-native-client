using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    private const int ChatAttachmentPostVersion = 5;

    /// <summary>
    /// 使用已记录的 Chat 内部单附件 multipart 契约提交一次请求。
    /// SendAsync 是唯一提交边界；进入该调用后绝不由传输层自动重放。
    /// </summary>
    public async Task<ChatAttachmentUploadTransportResult> SendChatAttachmentAsync(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability,
        ChatAttachmentUploadRequest upload,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!ValidChatAttachmentCapability(profile, session, capability))
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.Unsupported,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "chat.attachment-send.unsupported");
        }
        if (!ValidChatAttachmentUpload(upload))
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.ConfirmedFailure,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-send.invalid-input");
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "chat.attachment-send.cancelled-before-submit");
        }

        Uri requestUri;
        try
        {
            requestUri = ResolveSafeApiUri(profile, capability.Path);
        }
        catch (ArgumentException)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.ConfirmedFailure,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-send.invalid-endpoint");
        }
        catch (DsmException)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.ConfirmedFailure,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-send.invalid-endpoint");
        }

        var fields = new List<KeyValuePair<string, string>>
        {
            new("api", capability.Name),
            new("version", "5"),
            new("method", "create"),
            new("channel_id", upload.ConversationId),
            new("type", "file"),
            new("message", upload.Message),
            new("is_thread", "false"),
            new("_sid", session.Sid),
        };
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            // 固定请求 fixture 记录 token 同时位于 header 与 multipart 时的兼容形态。
            fields.Add(new KeyValuePair<string, string>("SynoToken", session.SynoToken));
        }

        var boundary = $"LanStash-Chat-{Guid.NewGuid():N}";
        using var content = new ExactLengthMultipartUploadContent(
            boundary,
            fields,
            upload.FileName,
            upload.Content,
            upload.Length,
            progress);
        using var request = new HttpRequestMessage(HttpMethod.Post, requestUri)
        {
            Content = content,
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.UserAgent.ParseAdd("LanStash-Windows/0.1");
        request.Headers.TryAddWithoutValidation("Cookie", $"id={session.Sid}");
        if (!string.IsNullOrWhiteSpace(session.SynoToken))
        {
            request.Headers.TryAddWithoutValidation("X-SYNO-TOKEN", session.SynoToken);
        }

        SetNasConnectionContext(request, profile);
        if (cancellationToken.IsCancellationRequested)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission,
                DiagnosticTag: "chat.attachment-send.cancelled-before-submit");
        }

        HttpResponseMessage response;
        try
        {
            // 此处是唯一提交边界：后续网络、解析或取消结果只能进入核对，不能重传。
            response = await _http.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.CancellationRequestedAfterSubmission,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "chat.attachment-send.cancelled-after-submit");
        }
        catch (HttpRequestException)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "chat.attachment-send.network-unverified");
        }
        catch (IOException)
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "chat.attachment-send.stream-unverified");
        }
        catch (InvalidOperationException error) when (
            string.Equals(
                error.Message,
                "upload.automatic_replay_blocked",
                StringComparison.Ordinal))
        {
            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network,
                DiagnosticTag: "chat.attachment-send.replay-blocked");
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                return new ChatAttachmentUploadTransportResult(
                    ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                    ErrorCategory: response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden
                        ? MutationErrorCategory.Authentication
                        : MutationErrorCategory.Server,
                    DiagnosticTag: "chat.attachment-send.http-unverified");
            }

            JsonObject? envelope;
            try
            {
                await using var responseStream = await response.Content
                    .ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                envelope = await JsonNode.ParseAsync(
                    responseStream,
                    cancellationToken: cancellationToken).ConfigureAwait(false) as JsonObject;
            }
            catch (OperationCanceledException)
            {
                return new ChatAttachmentUploadTransportResult(
                    ChatAttachmentUploadTransportStatus.CancellationRequestedAfterSubmission,
                    ErrorCategory: MutationErrorCategory.Network,
                    DiagnosticTag: "chat.attachment-send.cancelled-after-submit");
            }
            catch (Exception error) when (
                error is JsonException or HttpRequestException or IOException)
            {
                return new ChatAttachmentUploadTransportResult(
                    ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                    ErrorCategory: MutationErrorCategory.Server,
                    DiagnosticTag: "chat.attachment-send.response-unverified");
            }

            var success = StrictNativeBool(envelope, "success");
            if (success == true)
            {
                return new ChatAttachmentUploadTransportResult(
                    ChatAttachmentUploadTransportStatus.Accepted,
                    CandidateMessageId: ChatAttachmentCandidateMessageIdFromEnvelope(envelope),
                    DiagnosticTag: "chat.attachment-send.accepted");
            }

            var code = StrictNativeInt(envelope?["error"] as JsonObject, "code");
            if (success == false && code is not null)
            {
                return ConfirmedChatAttachmentFailure(code.Value);
            }

            return new ChatAttachmentUploadTransportResult(
                ChatAttachmentUploadTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Server,
                DiagnosticTag: "chat.attachment-send.response-unverified");
        }
    }

    private static bool ValidChatAttachmentCapability(
        NasProfile profile,
        DsmSession session,
        ApiCapability capability) =>
        profile.Id == session.ProfileId &&
        !string.IsNullOrWhiteSpace(session.Sid) &&
        string.Equals(capability.Name, "SYNO.Chat.Post", StringComparison.Ordinal) &&
        capability.MinVersion <= ChatAttachmentPostVersion &&
        capability.MaxVersion >= ChatAttachmentPostVersion &&
        IsSafeWebApiPath(capability.Path);

    private static bool ValidChatAttachmentUpload(ChatAttachmentUploadRequest? upload) =>
        upload is not null &&
        !string.IsNullOrWhiteSpace(upload.ConversationId) &&
        upload.ConversationId == upload.ConversationId.Trim() &&
        upload.ConversationId.IndexOfAny(['\r', '\n', '\0']) < 0 &&
        upload.Message is not null &&
        upload.Message.IndexOf('\0') < 0 &&
        upload.Content is { CanRead: true } &&
        upload.Length >= 0 &&
        ValidChatAttachmentFileName(upload.FileName);

    private static bool ValidChatAttachmentFileName(string fileName) =>
        !string.IsNullOrWhiteSpace(fileName) &&
        fileName == fileName.Trim() &&
        fileName is not ("." or "..") &&
        fileName.IndexOfAny(['/', '\\', '"', '\r', '\n', '\0']) < 0;

    private static string? ChatAttachmentCandidateMessageIdFromEnvelope(JsonObject? envelope)
    {
        var data = envelope?["data"] as JsonObject;
        return ChatAttachmentCandidateMessageIdFromObject(data) ??
            ChatAttachmentCandidateMessageIdFromObject(envelope);
    }

    private static string? ChatAttachmentCandidateMessageIdFromObject(JsonObject? item) =>
        item is null
            ? null
            : StableJsonString(item["post_id"]) ??
              StableJsonString(item["message_id"]) ??
              StableJsonString(item["id"]) ??
              ChatAttachmentCandidateMessageIdFromObject(item["post"] as JsonObject) ??
              ChatAttachmentCandidateMessageIdFromObject(item["message"] as JsonObject);

    private static ChatAttachmentUploadTransportResult ConfirmedChatAttachmentFailure(int code)
    {
        var category = code switch
        {
            105 => MutationErrorCategory.Permission,
            106 or 107 or 119 or 401 => MutationErrorCategory.Authentication,
            102 or 103 => MutationErrorCategory.Unsupported,
            _ => MutationErrorCategory.Server,
        };
        var diagnosticTag = code is >= 100 and <= 9999
            ? $"chat.attachment-send.dsm-{code}"
            : "chat.attachment-send.dsm-failure";
        return new ChatAttachmentUploadTransportResult(
            ChatAttachmentUploadTransportStatus.ConfirmedFailure,
            ErrorCategory: category,
            DiagnosticTag: diagnosticTag);
    }
}
