using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class PhotoRepositoryContractTests
{
    [Fact]
    public async Task PersonalAndSharedSpacesAreProbedIndependently()
    {
        var api = new RecordingPhotoApiClient(request => request.Method switch
        {
            "list" => Page("files", 0, 0),
            "list_share" => Page(
                "shares",
                0,
                1,
                new JsonObject
                {
                    ["name"] = "photo",
                    ["path"] = "/photo",
                    ["isdir"] = true,
                }),
            _ => throw new InvalidOperationException(),
        });
        IPhotoRepository repository = CreateRepository(api);

        var spaces = await repository.DiscoverSpacesAsync();

        Assert.Equal(
            new[] { PhotoSpaceIds.Personal, PhotoSpaceIds.Shared },
            spaces.Select(space => space.Id));
        Assert.Contains(api.Requests, request =>
            request.Method == "list" && request.Parameters["folder_path"] == "/home/Photos");
        Assert.Contains(api.Requests, request => request.Method == "list_share");
    }

    [Fact]
    public async Task MissingPersonalSpaceDoesNotHideSharedSpace()
    {
        var api = new RecordingPhotoApiClient(request =>
        {
            if (request.Method == "list")
            {
                throw new DsmException("missing", "none", 408);
            }
            return Page(
                "shares",
                0,
                1,
                new JsonObject { ["path"] = "/photo", ["isdir"] = true });
        });

        var spaces = await CreateRepository(api).DiscoverSpacesAsync();

        Assert.Equal(PhotoSpaceIds.Shared, Assert.Single(spaces).Id);
    }

    [Theory]
    [InlineData(true, 401)]
    [InlineData(false, null)]
    public async Task AuthenticationAndNetworkFailuresAreNotReportedAsNoSpaces(
        bool authenticationFailure,
        int? code)
    {
        var api = new RecordingPhotoApiClient(_ =>
            throw new DsmException(
                "failure",
                "retry",
                code,
                authenticationFailure));

        var error = await Assert.ThrowsAsync<DsmException>(() =>
            CreateRepository(api).DiscoverSpacesAsync());

        Assert.Equal(authenticationFailure, error.AuthenticationFailure);
        Assert.Equal(code, error.Code);
    }

    [Fact]
    public async Task PaginationAdvancesByRawDirectoryItemsIncludingNonMedia()
    {
        var api = new RecordingPhotoApiClient(_ => Page(
            "files",
            7,
            20,
            SourceItem("album", "/photo/album", true),
            SourceItem("image.JPG", "/photo/image.JPG", false, 10),
            SourceItem("notes.txt", "/photo/notes.txt", false, 20),
            SourceItem("clip.mp4", "/photo/clip.mp4", false, 30)));

        var page = await CreateRepository(api).ListFolderAsync(
            PhotoSpace.Shared,
            "/photo",
            7,
            4);

        Assert.Equal(7, page.Offset);
        Assert.Equal(11, page.NextOffset);
        Assert.Equal(20, page.SourceTotal);
        Assert.True(page.HasMore);
        Assert.Equal(
            new[] { PhotoItemKind.Folder, PhotoItemKind.Image, PhotoItemKind.Video },
            page.Items.Select(item => item.Kind));
        Assert.All(page.Items, item => Assert.Equal(ProfileId, item.ProfileId));
    }

    [Fact]
    public async Task EmptyRawPageBeforeTotalIsRejectedAsNoProgress()
    {
        var repository = CreateRepository(
            new RecordingPhotoApiClient(_ => Page("files", 7, 20)));

        await Assert.ThrowsAsync<InvalidDataException>(() => repository.ListFolderAsync(
            PhotoSpace.Shared,
            "/photo",
            7,
            10));
    }

    [Fact]
    public async Task ResponseItemsOutsideRequestedFolderAreRejected()
    {
        var api = new RecordingPhotoApiClient(_ => Page(
            "files",
            0,
            3,
            SourceItem("valid.jpg", "/photo/album/valid.jpg", false),
            SourceItem("other.jpg", "/photo/other.jpg", false),
            SourceItem("personal.jpg", "/home/Photos/personal.jpg", false)));

        await Assert.ThrowsAsync<InvalidDataException>(() => CreateRepository(api).ListFolderAsync(
            PhotoSpace.Shared,
            "/photo/album",
            0,
            3));
    }

    [Fact]
    public async Task BoundedTimelineUsesBreadthFirstPagesAndSkipsSystemAndFailedChildren()
    {
        var api = new RecordingPhotoApiClient(request =>
        {
            var path = request.Parameters["folder_path"];
            var offset = int.Parse(request.Parameters["offset"]);
            return (path, offset) switch
            {
                ("/photo", 0) => Page(
                    "files",
                    0,
                    4,
                    SourceItem("album", "/photo/album", true),
                    SourceItem("@eaDir", "/photo/@eaDir", true),
                    SourceItem("#recycle", "/photo/#recycle", true),
                    SourceItem("root.jpg", "/photo/root.jpg", false, 10, modified: 200)),
                ("/photo/album", 0) => Page(
                    "files",
                    0,
                    2,
                    SourceItem("nested.jpg", "/photo/album/nested.jpg", false, 20, modified: 100),
                    SourceItem("locked", "/photo/album/locked", true)),
                ("/photo/album/locked", 0) => throw new DsmException("denied", "none", 105),
                _ => throw new InvalidOperationException($"Unexpected request: {path} at {offset}"),
            };
        });

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(PageSize: 200));

        Assert.Equal(
            new[] { "/photo/root.jpg", "/photo/album/nested.jpg" },
            result.Items.Select(item => item.Path));
        Assert.Equal(3, result.ScannedFolderCount);
        Assert.Equal(1, result.SkippedFolderCount);
        Assert.Equal(6, result.SourceItemCount);
        Assert.Equal(PhotoTimelineCompletion.Complete, result.Completion);
        Assert.DoesNotContain(api.Requests, request =>
            request.Parameters.GetValueOrDefault("folder_path") is "/photo/@eaDir" or "/photo/#recycle");
        Assert.All(api.Requests, request => Assert.Equal("200", request.Parameters["limit"]));
    }

    [Fact]
    public async Task TimelinePaginatesByRawItemsAndReturnsAStableModifiedOrder()
    {
        var api = new RecordingPhotoApiClient(request =>
            request.Parameters["offset"] switch
            {
                "0" => Page(
                    "files",
                    0,
                    3,
                    SourceItem("notes.txt", "/photo/notes.txt", false, 1),
                    SourceItem("older.jpg", "/photo/older.jpg", false, 2, modified: 100)),
                "2" => Page(
                    "files",
                    2,
                    3,
                    SourceItem("newer.jpg", "/photo/newer.jpg", false, 3, modified: 200)),
                _ => throw new InvalidOperationException(),
            });

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(PageSize: 2));

        Assert.Equal(PhotoTimelineCompletion.Complete, result.Completion);
        Assert.Equal(1, result.ScannedFolderCount);
        Assert.Equal(3, result.SourceItemCount);
        Assert.Equal(
            new[] { "/photo/newer.jpg", "/photo/older.jpg" },
            result.Items.Select(item => item.Path));
        Assert.Equal(new[] { "0", "2" }, api.Requests.Select(request => request.Parameters["offset"]));
    }

    [Fact]
    public async Task FailedChildLaterPageDiscardsItsMediaAndSubfolders()
    {
        var api = new RecordingPhotoApiClient(request =>
        {
            var path = request.Parameters["folder_path"];
            var offset = int.Parse(request.Parameters["offset"]);
            return (path, offset) switch
            {
                ("/photo", 0) => Page(
                    "files",
                    0,
                    2,
                    SourceItem("album", "/photo/album", true),
                    SourceItem("root.jpg", "/photo/root.jpg", false)),
                ("/photo/album", 0) => Page(
                    "files",
                    0,
                    3,
                    SourceItem("partial.jpg", "/photo/album/partial.jpg", false),
                    SourceItem("nested", "/photo/album/nested", true)),
                ("/photo/album", 2) => throw new InvalidDataException("bad second page"),
                ("/photo/album/nested", 0) => throw new InvalidOperationException(
                    "A failed child must not enqueue its staged subfolder."),
                _ => throw new InvalidOperationException($"Unexpected request: {path} at {offset}"),
            };
        });

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(PageSize: 2));

        Assert.Equal(["/photo/root.jpg"], result.Items.Select(item => item.Path));
        Assert.Equal(2, result.ScannedFolderCount);
        Assert.Equal(1, result.SkippedFolderCount);
        Assert.Equal(4, result.SourceItemCount);
        Assert.Equal(PhotoTimelineCompletion.Complete, result.Completion);
        Assert.DoesNotContain(api.Requests, request =>
            request.Parameters["folder_path"] == "/photo/album/nested");
    }

    [Fact]
    public async Task TimelineStopsAtMediaLimitWithoutReadingAnotherPage()
    {
        var api = new RecordingPhotoApiClient(_ => Page(
            "files",
            0,
            2,
            SourceItem("first.jpg", "/photo/first.jpg", false, 1),
            SourceItem("second.jpg", "/photo/second.jpg", false, 1)));

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(MaximumMediaItems: 1));

        Assert.Equal(PhotoTimelineCompletion.Truncated, result.Completion);
        Assert.Single(result.Items);
        Assert.Equal(1, result.SourceItemCount);
        Assert.Single(api.Requests);
    }

    [Fact]
    public async Task TimelineFolderLimitLeavesQueuedFoldersTruncated()
    {
        var api = new RecordingPhotoApiClient(_ => Page(
            "files",
            0,
            1,
            SourceItem("album", "/photo/album", true)));

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(MaximumFolders: 1));

        Assert.Equal(1, result.ScannedFolderCount);
        Assert.Equal(PhotoTimelineCompletion.Truncated, result.Completion);
        Assert.Single(api.Requests);
    }

    [Fact]
    public async Task FailedChildrenConsumeTheFolderAttemptLimit()
    {
        var api = new RecordingPhotoApiClient(request =>
        {
            var path = request.Parameters["folder_path"];
            return path switch
            {
                "/photo" => Page(
                    "files",
                    0,
                    3,
                    SourceItem("a", "/photo/a", true),
                    SourceItem("b", "/photo/b", true),
                    SourceItem("c", "/photo/c", true)),
                "/photo/a" or "/photo/b" or "/photo/c" =>
                    throw new DsmException("denied", "none", 105),
                _ => throw new InvalidOperationException(),
            };
        });

        var result = await CreateRepository(api).LoadTimelineAsync(
            PhotoSpace.Shared,
            new PhotoTimelineLimits(MaximumFolders: 3));

        Assert.Equal(3, result.ScannedFolderCount);
        Assert.Equal(2, result.SkippedFolderCount);
        Assert.Equal(PhotoTimelineCompletion.Truncated, result.Completion);
        Assert.Equal(3, api.Requests.Count);
        Assert.DoesNotContain(api.Requests, request =>
            request.Parameters["folder_path"] == "/photo/c");
    }

    [Fact]
    public async Task TimelineSortUsesCreatedThenModifiedThenUnknown()
    {
        var api = new RecordingPhotoApiClient(_ => Page(
            "files",
            0,
            3,
            SourceItem("created.jpg", "/photo/created.jpg", false, 1, created: 300, modified: 10),
            SourceItem("modified.jpg", "/photo/modified.jpg", false, 1, modified: 200),
            SourceItem("unknown.jpg", "/photo/unknown.jpg", false, 1)));

        var result = await CreateRepository(api).LoadTimelineAsync(PhotoSpace.Shared);

        Assert.Equal(
            new[] { "/photo/created.jpg", "/photo/modified.jpg", "/photo/unknown.jpg" },
            result.Items.Select(item => item.Path));
    }

    [Fact]
    public async Task TimelineRootFailureAndCallerCancellationPropagate()
    {
        var failedApi = new RecordingPhotoApiClient(_ =>
            throw new DsmException("root failed", "retry"));
        await Assert.ThrowsAsync<DsmException>(() =>
            CreateRepository(failedApi).LoadTimelineAsync(PhotoSpace.Shared));

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var cancelledApi = new RecordingPhotoApiClient(_ =>
            throw new InvalidOperationException("must not be called"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CreateRepository(cancelledApi).LoadTimelineAsync(
                PhotoSpace.Shared,
                cancellationToken: cancellation.Token));
        Assert.Empty(cancelledApi.Requests);

        using var duringRequestCancellation = new CancellationTokenSource();
        var duringRequestApi = new RecordingPhotoApiClient(_ =>
        {
            duringRequestCancellation.Cancel();
            return Page("files", 0, 0);
        });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            CreateRepository(duringRequestApi).LoadTimelineAsync(
                PhotoSpace.Shared,
                cancellationToken: duringRequestCancellation.Token));
        Assert.Single(duringRequestApi.Requests);
    }

    [Fact]
    public async Task TimelineRejectsChangingTotalAcrossPages()
    {
        var api = new RecordingPhotoApiClient(request =>
            request.Parameters["offset"] switch
            {
                "0" => Page(
                    "files",
                    0,
                    3,
                    SourceItem("first.jpg", "/photo/first.jpg", false),
                    SourceItem("second.jpg", "/photo/second.jpg", false)),
                "2" => Page(
                    "files",
                    2,
                    4,
                    SourceItem("third.jpg", "/photo/third.jpg", false)),
                _ => throw new InvalidOperationException(),
            });

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            CreateRepository(api).LoadTimelineAsync(
                PhotoSpace.Shared,
                new PhotoTimelineLimits(PageSize: 2)));
    }

    [Theory]
    [InlineData("offset")]
    [InlineData("total")]
    [InlineData("item")]
    [InlineData("isdir")]
    [InlineData("size")]
    [InlineData("mtime")]
    public async Task NonNativeOrNonObjectPhotoFieldsAreRejected(string field)
    {
        var item = SourceItem("image.jpg", "/photo/image.jpg", false, 1, modified: 100);
        var page = Page("files", 0, 1, item);
        switch (field)
        {
            case "offset":
                page["offset"] = "0";
                break;
            case "total":
                page["total"] = "1";
                break;
            case "item":
                page["files"] = new JsonArray("not-an-object");
                break;
            case "isdir":
                item["isdir"] = "false";
                break;
            case "size":
                item["size"] = "1";
                break;
            default:
                ((JsonObject)((JsonObject)item["additional"]!)["time"]!)["mtime"] = "100";
                break;
        }
        var repository = CreateRepository(new RecordingPhotoApiClient(_ => page));

        await Assert.ThrowsAsync<InvalidDataException>(() => repository.ListFolderAsync(
            PhotoSpace.Shared,
            "/photo",
            0,
            1));
    }

    [Fact]
    public async Task ThumbnailRepositoryUsesPublicV2WireAndBoundedImageContract()
    {
        var api = new RecordingPhotoApiClient(
            _ => throw new NotSupportedException(),
            binaryResponse: new DsmBinaryResponse([1, 2, 3], "image/jpeg"));
        var repository = CreateRepository(api);

        var thumbnail = await repository.GetThumbnailAsync(
            ImageItem(ProfileId, "/photo/image.jpg"),
            PhotoThumbnailSize.Medium);

        Assert.Equal(new byte[] { 1, 2, 3 }, thumbnail.Bytes);
        var request = Assert.Single(api.BinaryRequests);
        Assert.Equal("SYNO.FileStation.Thumb", request.Capability.Name);
        Assert.Equal("get", request.Method);
        Assert.Equal("/photo/image.jpg", request.Parameters["path"]);
        Assert.Equal("medium", request.Parameters["size"]);
        Assert.Equal("0", request.Parameters["rotate"]);
        Assert.Equal("image/", request.AcceptedMediaTypePrefix);
        Assert.Equal(PhotoThumbnail.MaximumBytes, request.MaximumBytes);
    }

    [Fact]
    public async Task ThumbnailRequiresServerSupportForPublicV2Contract()
    {
        var api = new RecordingPhotoApiClient(_ => throw new NotSupportedException());
        var repository = new DsmRepository(
            Profile(),
            Session(),
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.FileStation.List"] = new(
                    "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
                ["SYNO.FileStation.Thumb"] = new(
                    "SYNO.FileStation.Thumb", "entry.cgi", 1, 1, "FORM"),
            });

        var error = await Assert.ThrowsAsync<DsmException>(() =>
            repository.GetThumbnailAsync(
                ImageItem(ProfileId, "/photo/image.jpg"),
                PhotoThumbnailSize.Small));

        Assert.Equal(103, error.Code);
        Assert.Empty(api.BinaryRequests);
    }

    [Fact]
    public async Task NonImageAndForeignProfileAreRejectedBeforeTransport()
    {
        var api = new RecordingPhotoApiClient(_ => throw new NotSupportedException());
        var repository = CreateRepository(api);
        var video = ImageItem(ProfileId, "/photo/clip.mp4") with { Kind = PhotoItemKind.Video };
        var foreign = ImageItem(Guid.NewGuid(), "/photo/image.jpg");

        await Assert.ThrowsAsync<ArgumentException>(() =>
            repository.GetThumbnailAsync(video, PhotoThumbnailSize.Small));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            repository.GetThumbnailAsync(foreign, PhotoThumbnailSize.Small));

        Assert.Empty(api.BinaryRequests);
    }

    [Fact]
    public async Task MismatchedSessionProfileIsRejectedBeforeAnyPhotoRequest()
    {
        var api = new RecordingPhotoApiClient(_ => throw new NotSupportedException());
        var repository = new DsmRepository(
            Profile(),
            Session() with { ProfileId = Guid.NewGuid() },
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.FileStation.List"] = new(
                    "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
                ["SYNO.FileStation.Thumb"] = ThumbnailCapability(),
            });

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            repository.DiscoverSpacesAsync());

        Assert.Empty(api.Requests);
        Assert.Empty(api.BinaryRequests);
    }

    [Fact]
    public async Task BinaryThumbnailAuthenticationNeverAppearsInUrl()
    {
        HttpRequestMessage? observed = null;
        using var handler = new StubHttpMessageHandler((request, _) =>
        {
            observed = request;
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent([1, 2, 3]),
            };
            response.Content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
            return Task.FromResult(response);
        });
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);

        var result = await client.ReadBinaryAsync(
            Profile(),
            Session(),
            ThumbnailCapability(),
            "get",
            new Dictionary<string, string>
            {
                ["path"] = "/photo/synthetic.jpg",
                ["size"] = "medium",
                ["rotate"] = "0",
            },
            "image/",
            PhotoThumbnail.MaximumBytes);

        Assert.Equal("image/jpeg", result.MediaType);
        var request = Assert.IsType<HttpRequestMessage>(observed);
        Assert.DoesNotContain(Session().Sid, request.RequestUri!.AbsoluteUri, StringComparison.Ordinal);
        Assert.DoesNotContain(Session().SynoToken!, request.RequestUri.AbsoluteUri, StringComparison.Ordinal);
        Assert.Contains("api=SYNO.FileStation.Thumb", request.RequestUri.Query, StringComparison.Ordinal);
        Assert.Contains("version=2", request.RequestUri.Query, StringComparison.Ordinal);
        Assert.Equal("id=synthetic-sid", Assert.Single(request.Headers.GetValues("Cookie")));
        Assert.Equal("synthetic-token", Assert.Single(request.Headers.GetValues("X-SYNO-TOKEN")));
    }

    [Fact]
    public async Task BinaryCapabilityPathCannotChangeNasAuthority()
    {
        var sends = 0;
        using var handler = new StubHttpMessageHandler((_, _) =>
        {
            sends += 1;
            throw new InvalidOperationException();
        });
        using var http = new HttpClient(handler);
        var hostile = new ApiCapability(
            "SYNO.FileStation.Thumb",
            "//other.invalid/entry.cgi",
            2,
            2,
            "FORM");

        await Assert.ThrowsAsync<ArgumentException>(() =>
            new DsmApiClient(http).ReadBinaryAsync(
                Profile(), Session(), hostile, "get", null, "image/", 3));

        Assert.Equal(0, sends);
    }

    [Fact]
    public async Task BinaryThumbnailRejectsNonImageAndDeclaredOversizeResponses()
    {
        using var nonImageHandler = new StubHttpMessageHandler((_, _) =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{}", Encoding.UTF8, "application/json"),
            };
            return Task.FromResult(response);
        });
        using var nonImageHttp = new HttpClient(nonImageHandler);
        var nonImage = await Assert.ThrowsAsync<DsmBinaryResponseException>(() =>
            new DsmApiClient(nonImageHttp).ReadBinaryAsync(
                Profile(), Session(), ThumbnailCapability(), "get", null, "image/", 3));
        Assert.Equal(DsmBinaryResponseFailure.UnexpectedMediaType, nonImage.Failure);

        using var oversizedHandler = new StubHttpMessageHandler((_, _) =>
        {
            var content = new ByteArrayContent([1]);
            content.Headers.ContentType = new MediaTypeHeaderValue("image/png");
            content.Headers.ContentLength = 4;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        });
        using var oversizedHttp = new HttpClient(oversizedHandler);
        var oversized = await Assert.ThrowsAsync<DsmBinaryResponseException>(() =>
            new DsmApiClient(oversizedHttp).ReadBinaryAsync(
                Profile(), Session(), ThumbnailCapability(), "get", null, "image/", 3));
        Assert.Equal(DsmBinaryResponseFailure.ResponseTooLarge, oversized.Failure);

        using var streamedHandler = new StubHttpMessageHandler((_, _) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new UnknownLengthContent([1, 2, 3, 4], "image/webp"),
            }));
        using var streamedHttp = new HttpClient(streamedHandler);
        var streamed = await Assert.ThrowsAsync<DsmBinaryResponseException>(() =>
            new DsmApiClient(streamedHttp).ReadBinaryAsync(
                Profile(), Session(), ThumbnailCapability(), "get", null, "image/", 3));
        Assert.Equal(DsmBinaryResponseFailure.ResponseTooLarge, streamed.Failure);

        using var emptyHandler = new StubHttpMessageHandler((_, _) =>
        {
            var content = new ByteArrayContent([]);
            content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        });
        using var emptyHttp = new HttpClient(emptyHandler);
        var empty = await Assert.ThrowsAsync<DsmBinaryResponseException>(() =>
            new DsmApiClient(emptyHttp).ReadBinaryAsync(
                Profile(), Session(), ThumbnailCapability(), "get", null, "image/", 3));
        Assert.Equal(DsmBinaryResponseFailure.EmptyBody, empty.Failure);
    }

    [Fact]
    public async Task BinaryThumbnailPropagatesCallerCancellation()
    {
        using var handler = new StubHttpMessageHandler(async (_, cancellationToken) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException();
        });
        using var http = new HttpClient(handler);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new DsmApiClient(http).ReadBinaryAsync(
                Profile(),
                Session(),
                ThumbnailCapability(),
                "get",
                null,
                "image/",
                3,
                cancellation.Token));
    }

    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    private static DsmRepository CreateRepository(RecordingPhotoApiClient api) => new(
        Profile(),
        Session(),
        api,
        new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
        {
            ["SYNO.FileStation.List"] = new(
                "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
            ["SYNO.FileStation.Thumb"] = ThumbnailCapability(),
        });

    private static NasProfile Profile() =>
        new(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester");

    private static DsmSession Session() =>
        new(ProfileId, "synthetic-sid", "synthetic-token", null);

    private static ApiCapability ThumbnailCapability() =>
        new("SYNO.FileStation.Thumb", "entry.cgi", 1, 5, "FORM");

    private static PhotoItem ImageItem(Guid profileId, string path) => new(
        profileId,
        $"{profileId:N}:{path}",
        path.Split('/').Last(),
        path,
        PhotoItemKind.Image,
        3,
        null,
        null,
        System.IO.Path.GetExtension(path).TrimStart('.'),
        null);

    private static JsonObject SourceItem(
        string name,
        string path,
        bool isDirectory,
        long? size = null,
        long? created = null,
        long? modified = null)
    {
        var item = new JsonObject
        {
            ["name"] = name,
            ["path"] = path,
            ["isdir"] = isDirectory,
            ["size"] = size,
        };
        if (created is not null || modified is not null)
        {
            item["additional"] = new JsonObject
            {
                ["time"] = new JsonObject
                {
                    ["crtime"] = created,
                    ["mtime"] = modified,
                },
            };
        }
        return item;
    }

    private static JsonObject Page(
        string root,
        int offset,
        int total,
        params JsonObject[] items) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        [root] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private sealed record ApiRequest(
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed record BinaryRequest(
        ApiCapability Capability,
        string Method,
        IReadOnlyDictionary<string, string> Parameters,
        string AcceptedMediaTypePrefix,
        int MaximumBytes);

    private sealed class RecordingPhotoApiClient(
        Func<ApiRequest, JsonObject> response,
        DsmBinaryResponse? binaryResponse = null) : IDsmApiClient
    {
        public List<ApiRequest> Requests { get; } = [];
        public List<BinaryRequest> BinaryRequests { get; } = [];

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
                method,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

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
            BinaryRequests.Add(new BinaryRequest(
                capability,
                method,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal),
                acceptedMediaTypePrefix,
                maximumBytes));
            return Task.FromResult(binaryResponse ??
                new DsmBinaryResponse([1], "image/jpeg"));
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

    private sealed class UnknownLengthContent : HttpContent
    {
        private readonly byte[] _bytes;

        public UnknownLengthContent(byte[] bytes, string mediaType)
        {
            _bytes = bytes;
            Headers.ContentType = new MediaTypeHeaderValue(mediaType);
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context) => stream.WriteAsync(_bytes, 0, _bytes.Length);

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context,
            CancellationToken cancellationToken) =>
            stream.WriteAsync(_bytes.AsMemory(), cancellationToken).AsTask();
    }
}
