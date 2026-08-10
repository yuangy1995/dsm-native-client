using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatAttachmentReadRepositoryContractTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("55555555-5555-5555-5555-555555555555");

    [Fact]
    public void AttachmentBinaryFeaturesRequirePostFileV2WithFormContract()
    {
        var withoutFileApi = CreateRepository(new AttachmentReadApiClient(), Capabilities());
        var exact = CapabilitiesWithPostFile();
        var withFileApi = CreateRepository(new AttachmentReadApiClient(), exact);
        var invalidFormat = CapabilitiesWithPostFile();
        invalidFormat["SYNO.Chat.Post.File"] = invalidFormat["SYNO.Chat.Post.File"] with
        {
            RequestFormat = "JSON",
        };
        var invalidFormatRepository = CreateRepository(new AttachmentReadApiClient(), invalidFormat);
        var unsupportedVersion = CapabilitiesWithPostFile();
        unsupportedVersion["SYNO.Chat.Post.File"] = unsupportedVersion["SYNO.Chat.Post.File"] with
        {
            MaxVersion = 1,
        };
        var unsupportedVersionRepository = CreateRepository(
            new AttachmentReadApiClient(),
            unsupportedVersion);

        Assert.Equal(ChatAvailabilityStatus.Available, withoutFileApi.Availability.Status);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentThumbnail,
            withoutFileApi.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentContent,
            withoutFileApi.Availability.SupportedFeatures);
        Assert.Contains(ChatReadFeature.AttachmentThumbnail, withFileApi.Availability.SupportedFeatures);
        Assert.Contains(ChatReadFeature.AttachmentContent, withFileApi.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentThumbnail,
            invalidFormatRepository.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentContent,
            invalidFormatRepository.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentThumbnail,
            unsupportedVersionRepository.Availability.SupportedFeatures);
        Assert.DoesNotContain(
            ChatReadFeature.AttachmentContent,
            unsupportedVersionRepository.Availability.SupportedFeatures);
    }

    [Fact]
    public async Task ThumbnailUsesStablePostIdFixedV2AndBoundedImageContract()
    {
        var api = new AttachmentReadApiClient
        {
            BinaryResponse = _ => new DsmBinaryResponse([0x01, 0x02], "image/jpeg"),
        };
        var repository = CreateRepository(api, CapabilitiesWithPostFile());
        var attachment = new ChatAttachment(
            "file-id-that-must-not-route-request",
            ChatAttachmentKind.Image,
            "photo.jpg",
            "image/jpeg",
            2,
            null,
            true);

        var thumbnail = await repository.ReadAttachmentThumbnailAsync(" post-thumb-1 ", attachment);

        Assert.Equal(new byte[] { 0x01, 0x02 }, thumbnail.Bytes);
        Assert.Equal("image/jpeg", thumbnail.MediaType);
        var request = Assert.Single(api.BinaryRequests);
        Assert.Equal("SYNO.Chat.Post.File", request.ApiName);
        Assert.Equal(2, request.MinimumVersion);
        Assert.Equal(2, request.MaximumVersion);
        Assert.Equal("thumbnail", request.Method);
        Assert.Equal("post-thumb-1", request.Parameters["post_id"]);
        Assert.Equal("sm", request.Parameters["type"]);
        Assert.Equal("image/", request.AcceptedMediaTypePrefix);
        Assert.Equal(ChatAttachmentThumbnail.MaximumBytes, request.MaximumBytes);
        Assert.DoesNotContain(
            "file-id-that-must-not-route-request",
            request.Parameters.Values);
    }

    [Fact]
    public async Task ThumbnailRejectsNonImageBeforeTransport()
    {
        var api = new AttachmentReadApiClient();
        var repository = CreateRepository(api, CapabilitiesWithPostFile());
        var attachment = new ChatAttachment(
            "file-1",
            ChatAttachmentKind.File,
            "note.txt",
            "text/plain",
            1,
            null,
            false);

        await Assert.ThrowsAsync<ArgumentException>(() =>
            repository.ReadAttachmentThumbnailAsync("post-thumb-2", attachment));

        Assert.Empty(api.BinaryRequests);
    }

    [Fact]
    public async Task SaveUsesStablePostIdCallerDestinationExpectedLengthAndProgress()
    {
        var api = new AttachmentReadApiClient
        {
            ContentResponse = request =>
            {
                request.Progress?.Report(0);
                request.Destination.Write(new byte[] { 0x00, 0x01, 0xFE }, 0, 3);
                request.Progress?.Report(3);
                return new ChatAttachmentContentReadResult(
                    ChatAttachmentContentReadStatus.Completed,
                    BytesWritten: 3,
                    DestinationWasCleared: false,
                    DiagnosticTag: "chat.attachment-save.completed");
            },
        };
        var repository = CreateRepository(api, CapabilitiesWithPostFile());
        var attachment = new ChatAttachment(
            "file-id-that-must-not-route-request",
            ChatAttachmentKind.File,
            "../../server-suggested-name.bin",
            "application/octet-stream",
            3,
            null,
            null);
        using var destination = new MemoryStream();
        var reports = new List<long>();
        var progress = new InlineProgress(reports.Add);

        var result = await repository.SaveAttachmentAsync(
            " post-save-1 ",
            attachment,
            destination,
            progress);

        Assert.Equal(ChatAttachmentContentReadStatus.Completed, result.Status);
        Assert.Equal(new byte[] { 0x00, 0x01, 0xFE }, destination.ToArray());
        Assert.Equal(new long[] { 0, 3 }, reports);
        var request = Assert.Single(api.ContentRequests);
        Assert.Equal("SYNO.Chat.Post.File", request.ApiName);
        Assert.Equal(2, request.MinimumVersion);
        Assert.Equal(2, request.MaximumVersion);
        Assert.Equal("post-save-1", request.MessageId);
        Assert.Equal(3L, request.ExpectedLength);
        Assert.Same(destination, request.Destination);
        Assert.Same(progress, request.Progress);
    }

    [Fact]
    public async Task SaveWithoutPostFileV2LeavesCallerDestinationUntouched()
    {
        var api = new AttachmentReadApiClient();
        var repository = CreateRepository(api, Capabilities());
        var attachment = new ChatAttachment(
            "file-1",
            ChatAttachmentKind.File,
            "note.txt",
            "text/plain",
            1,
            null,
            null);
        using var destination = new MemoryStream();

        var result = await repository.SaveAttachmentAsync("post-save-2", attachment, destination);

        Assert.Equal(ChatAttachmentContentReadStatus.Unsupported, result.Status);
        Assert.Empty(api.ContentRequests);
        Assert.Equal(0, destination.Length);
    }

    [Fact]
    public async Task SaveRequiresKnownNonnegativeAttachmentLengthBeforeTransport()
    {
        var api = new AttachmentReadApiClient();
        var repository = CreateRepository(api, CapabilitiesWithPostFile());
        var attachment = new ChatAttachment(
            "file-1",
            ChatAttachmentKind.File,
            "unknown-size.bin",
            "application/octet-stream",
            SizeBytes: null,
            DurationMilliseconds: null,
            ThumbnailAvailable: null);
        using var destination = new MemoryStream();

        var result = await repository.SaveAttachmentAsync("post-save-3", attachment, destination);

        Assert.Equal(ChatAttachmentContentReadStatus.Failed, result.Status);
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
        Assert.Empty(api.ContentRequests);
        Assert.Equal(0, destination.Length);
    }

    private static DsmRepository CreateRepository(
        AttachmentReadApiClient api,
        IReadOnlyDictionary<string, ApiCapability> capabilities) =>
        new(Profile(), Session(), api, capabilities);

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

    private static Dictionary<string, ApiCapability> CapabilitiesWithPostFile()
    {
        var capabilities = Capabilities();
        capabilities["SYNO.Chat.Post.File"] = new(
            "SYNO.Chat.Post.File",
            "entry.cgi",
            1,
            2,
            "FORM");
        return capabilities;
    }

    private sealed record BinaryReadRequest(
        string ApiName,
        int MinimumVersion,
        int MaximumVersion,
        string Method,
        IReadOnlyDictionary<string, string> Parameters,
        string AcceptedMediaTypePrefix,
        int MaximumBytes);

    private sealed record ContentReadRequest(
        string ApiName,
        int MinimumVersion,
        int MaximumVersion,
        string MessageId,
        Stream Destination,
        long ExpectedLength,
        IProgress<long>? Progress);

    private sealed class AttachmentReadApiClient : IDsmApiClient
    {
        public List<BinaryReadRequest> BinaryRequests { get; } = [];
        public List<ContentReadRequest> ContentRequests { get; } = [];
        public Func<BinaryReadRequest, DsmBinaryResponse>? BinaryResponse { get; init; }
        public Func<ContentReadRequest, ChatAttachmentContentReadResult>? ContentResponse { get; init; }

        public Task<DsmBinaryResponse> ReadBinaryAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters,
            string acceptedMediaTypePrefix,
            int maximumBytes,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new BinaryReadRequest(
                capability.Name,
                capability.MinVersion,
                capability.MaxVersion,
                method,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal),
                acceptedMediaTypePrefix,
                maximumBytes);
            BinaryRequests.Add(request);
            return Task.FromResult(BinaryResponse?.Invoke(request) ??
                throw new InvalidOperationException("Missing binary response."));
        }

        public Task<ChatAttachmentContentReadResult> ReadChatAttachmentContentAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            ChatAttachmentContentReadRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var captured = new ContentReadRequest(
                capability.Name,
                capability.MinVersion,
                capability.MaxVersion,
                request.MessageId,
                request.Destination,
                request.ExpectedLength,
                progress);
            ContentRequests.Add(captured);
            return Task.FromResult(ContentResponse?.Invoke(captured) ??
                new ChatAttachmentContentReadResult(
                    ChatAttachmentContentReadStatus.Unsupported,
                    BytesWritten: 0,
                    DestinationWasCleared: false,
                    ErrorCategory: MutationErrorCategory.Unsupported));
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
        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
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
}
