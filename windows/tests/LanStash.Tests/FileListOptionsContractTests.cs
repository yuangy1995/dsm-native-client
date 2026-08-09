using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class FileListOptionsContractTests
{
    [Theory]
    [InlineData(FileListSortField.Name, FileListSortDirection.Ascending, FileListTypeFilter.All, "name", "asc", null)]
    [InlineData(FileListSortField.Size, FileListSortDirection.Descending, FileListTypeFilter.Files, "size", "desc", "file")]
    [InlineData(FileListSortField.ModifiedTime, FileListSortDirection.Ascending, FileListTypeFilter.Folders, "mtime", "asc", "dir")]
    public async Task DirectoryOptionsMapToPublicListParameters(
        FileListSortField sortField,
        FileListSortDirection sortDirection,
        FileListTypeFilter typeFilter,
        string expectedSortField,
        string expectedSortDirection,
        string? expectedFileType)
    {
        var api = new FileListApiClient(EmptyPage("files"));
        var repository = CreateRepository(api);

        await repository.ListFilesAsync(
            "/fixture",
            7,
            900,
            new FileListOptions(sortField, sortDirection, typeFilter));

        var request = Assert.Single(api.Requests);
        Assert.Equal("list", request.Method);
        Assert.Equal("/fixture", request.Parameters["folder_path"]);
        Assert.Equal("7", request.Parameters["offset"]);
        Assert.Equal("500", request.Parameters["limit"]);
        Assert.Equal(expectedSortField, request.Parameters["sort_by"]);
        Assert.Equal(expectedSortDirection, request.Parameters["sort_direction"]);
        if (expectedFileType is null)
        {
            Assert.DoesNotContain("filetype", request.Parameters.Keys);
        }
        else
        {
            Assert.Equal(expectedFileType, request.Parameters["filetype"]);
        }
        Assert.DoesNotContain("pattern", request.Parameters.Keys);
        Assert.DoesNotContain("search_type", request.Parameters.Keys);
    }

    [Theory]
    [InlineData(FileListSortField.Size, FileListSortDirection.Descending, FileListTypeFilter.Files, "desc")]
    [InlineData(FileListSortField.ModifiedTime, FileListSortDirection.Ascending, FileListTypeFilter.Folders, "asc")]
    public async Task SharedRootForcesNameAndAllWhileKeepingDirection(
        FileListSortField sortField,
        FileListSortDirection sortDirection,
        FileListTypeFilter typeFilter,
        string expectedDirection)
    {
        var api = new FileListApiClient(EmptyPage("shares"));
        var repository = CreateRepository(api);

        await repository.ListFilesAsync(
            string.Empty,
            0,
            100,
            new FileListOptions(sortField, sortDirection, typeFilter));

        var request = Assert.Single(api.Requests);
        Assert.Equal("list_share", request.Method);
        Assert.Equal("name", request.Parameters["sort_by"]);
        Assert.Equal(expectedDirection, request.Parameters["sort_direction"]);
        Assert.DoesNotContain("folder_path", request.Parameters.Keys);
        Assert.DoesNotContain("filetype", request.Parameters.Keys);
    }

    [Fact]
    public async Task LegacyOverloadsDelegateToDefaultOptions()
    {
        var api = new FileListApiClient(EmptyPage("files"), EmptyPage("shares"));
        var repository = CreateRepository(api);

        await repository.ListFilesAsync("/fixture", 3, 25);
        await repository.ListFilesAsync(string.Empty);

        Assert.Collection(
            api.Requests,
            directory =>
            {
                Assert.Equal("list", directory.Method);
                Assert.Equal("3", directory.Parameters["offset"]);
                Assert.Equal("25", directory.Parameters["limit"]);
                Assert.Equal("name", directory.Parameters["sort_by"]);
                Assert.Equal("asc", directory.Parameters["sort_direction"]);
                Assert.DoesNotContain("filetype", directory.Parameters.Keys);
            },
            sharedRoot =>
            {
                Assert.Equal("list_share", sharedRoot.Method);
                Assert.Equal("0", sharedRoot.Parameters["offset"]);
                Assert.Equal("500", sharedRoot.Parameters["limit"]);
                Assert.Equal("name", sharedRoot.Parameters["sort_by"]);
                Assert.Equal("asc", sharedRoot.Parameters["sort_direction"]);
                Assert.DoesNotContain("filetype", sharedRoot.Parameters.Keys);
            });
    }

    [Fact]
    public async Task ResponsePreservesServerOffsetTotalAndItems()
    {
        var response = new JsonObject
        {
            ["offset"] = 37,
            ["total"] = 38,
            ["files"] = new JsonArray
            {
                new JsonObject
                {
                    ["path"] = "/fixture/final.txt",
                    ["name"] = "final.txt",
                    ["isdir"] = false,
                    ["size"] = 42,
                },
            },
        };
        var repository = CreateRepository(new FileListApiClient(response));

        var page = await repository.ListFilesAsync(
            "/fixture",
            37,
            1,
            new FileListOptions(FileListSortField.Size));

        Assert.Equal(37, page.Offset);
        Assert.Equal(38, page.Total);
        Assert.Equal("/fixture/final.txt", Assert.Single(page.Items).Path);
    }

    [Fact]
    public void SharedRootNormalizationIsStableAndTyped()
    {
        var requested = new FileListOptions(
            FileListSortField.Size,
            FileListSortDirection.Descending,
            FileListTypeFilter.Files);

        var effective = requested.NormalizeForSharedRoot();

        Assert.Equal(FileListSortField.Name, effective.SortField);
        Assert.Equal(FileListSortDirection.Descending, effective.SortDirection);
        Assert.Equal(FileListTypeFilter.All, effective.TypeFilter);
        Assert.Equal(effective, effective.NormalizeForSharedRoot());
    }

    private static DsmRepository CreateRepository(FileListApiClient api)
    {
        var profileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var capability = new ApiCapability(
            "SYNO.FileStation.List",
            "entry.cgi",
            2,
            2,
            "FORM");
        return new DsmRepository(
            new NasProfile(profileId, "测试 NAS", "nas.invalid", 5001, "tester"),
            new DsmSession(profileId, "synthetic-sid", null, null),
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                [capability.Name] = capability,
            });
    }

    private static JsonObject EmptyPage(string root) => new()
    {
        ["offset"] = 0,
        ["total"] = 0,
        [root] = new JsonArray(),
    };

    private sealed record Request(
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class FileListApiClient(params JsonObject[] responses) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _responses = new(responses);

        public List<Request> Requests { get; } = [];

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            Assert.Equal("SYNO.FileStation.List", capability.Name);
            Requests.Add(new Request(
                method,
                new Dictionary<string, string>(parameters!, StringComparer.Ordinal)));
            return Task.FromResult(_responses.Dequeue());
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
}
