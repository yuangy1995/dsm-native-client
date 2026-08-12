using System.Text.Json.Nodes;
using LanStash.App.Features.Files;
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
    public async Task ProductionBrowserReadsCompleteSharedRootWithinExistingRequest()
    {
        var api = new FileListApiClient(EmptyPage("shares"));
        var source = new RepositoryFileBrowserDataSource(CreateRepository(api));

        await source.LoadPageAsync(
            string.Empty,
            0,
            100,
            FileListOptions.Default,
            CancellationToken.None);

        var request = Assert.Single(api.Requests);
        Assert.Equal("list_share", request.Method);
        Assert.Equal("500", request.Parameters["limit"]);
    }

    [Fact]
    public async Task SharedRootAggregatesCapacityByVisibleVolumeWithoutExposingIdentity()
    {
        var response = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 3,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/homes/tester", "1000", "250"),
                Share("projects", "/projects", "/volume1/projects", 1000, 250,
                    totalKey: "total_space", remainingKey: "free_space"),
                Share("archive", "/archive", "/volume2/archive", 2000, 800,
                    totalKey: "total", remainingKey: "available"),
            },
        };
        var repository = CreateRepository(new FileListApiClient(response));

        var page = await repository.ListFilesAsync(string.Empty, 0, 500);
        var summary = Assert.IsType<StorageSpaceSummary>(page.StorageSpace);

        Assert.Equal(3000, summary.TotalBytes);
        Assert.Equal(1050, summary.RemainingBytes);
        Assert.Equal(1950, summary.UsedBytes);
        Assert.Equal(2, summary.VolumeCount);
        Assert.Equal(0.65, summary.UsedFraction, precision: 10);
        Assert.DoesNotContain("volume1", summary.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("tester", summary.ToString(), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task IncompleteOrInvalidSharedRootDoesNotPublishPartialCapacity()
    {
        var incomplete = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 2,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/home", 1000, 250),
            },
        };
        var invalid = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 1,
            ["shares"] = new JsonArray
            {
                Share("remote", "/remote", "/remote/server", 1000, 250),
            },
        };
        var repository = CreateRepository(new FileListApiClient(incomplete, invalid));

        var incompletePage = await repository.ListFilesAsync(string.Empty, 0, 1);
        var invalidPage = await repository.ListFilesAsync(string.Empty, 0, 1);

        Assert.Null(incompletePage.StorageSpace);
        Assert.Null(invalidPage.StorageSpace);
    }

    [Fact]
    public async Task MalformedLocalVolumeOrConflictingDuplicateDoesNotPublishPartialCapacity()
    {
        var malformed = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 2,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/home", 1000, 250),
                Share("archive", "/archive", "/volume2/archive", "invalid", 800),
            },
        };
        var conflicting = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 2,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/home", 1000, 250),
                Share("projects", "/projects", "/volume1/projects", 2000, 500),
            },
        };
        var repository = CreateRepository(new FileListApiClient(malformed, conflicting));

        Assert.Null((await repository.ListFilesAsync(string.Empty, 0, 500)).StorageSpace);
        Assert.Null((await repository.ListFilesAsync(string.Empty, 0, 500)).StorageSpace);
    }

    [Theory]
    [InlineData("offset", "invalid")]
    [InlineData("offset", "-1")]
    [InlineData("total", "invalid")]
    [InlineData("total", "-1")]
    public async Task InvalidPagingMetadataDoesNotPublishCapacity(string key, string value)
    {
        var response = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 1,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/home", 1000, 250),
            },
        };
        response[key] = value;
        var repository = CreateRepository(new FileListApiClient(response));

        var page = await repository.ListFilesAsync(string.Empty, 0, 500);

        Assert.Null(page.StorageSpace);
    }

    [Fact]
    public async Task MissingTotalAtFullPageLimitAndAggregateOverflowDoNotPublishCapacity()
    {
        var fullPage = new JsonObject
        {
            ["offset"] = 0,
            ["shares"] = new JsonArray(
                Enumerable.Range(0, 500)
                    .Select(index => (JsonNode?)Share(
                        $"share-{index}",
                        $"/share-{index}",
                        $"/volume{index + 1}/share",
                        1000,
                        250))
                    .ToArray()),
        };
        var overflow = new JsonObject
        {
            ["offset"] = 0,
            ["total"] = 2,
            ["shares"] = new JsonArray
            {
                Share("first", "/first", "/volume1/first", long.MaxValue, 0),
                Share("second", "/second", "/volume2/second", 1, 0),
            },
        };
        var repository = CreateRepository(new FileListApiClient(fullPage, overflow));

        Assert.Null((await repository.ListFilesAsync(string.Empty, 0, 500)).StorageSpace);
        Assert.Null((await repository.ListFilesAsync(string.Empty, 0, 500)).StorageSpace);
    }

    [Fact]
    public async Task MissingPagingMetadataCannotHideAFullSmallPageOrNonzeroOffset()
    {
        var smallFullPage = new JsonObject
        {
            ["shares"] = new JsonArray(
                Enumerable.Range(0, 100)
                    .Select(index => (JsonNode?)Share(
                        $"share-{index}",
                        $"/share-{index}",
                        $"/volume{index + 1}/share",
                        1000,
                        250))
                    .ToArray()),
        };
        var nonzeroPage = new JsonObject
        {
            ["total"] = 1,
            ["shares"] = new JsonArray
            {
                Share("home", "/home", "/volume1/home", 1000, 250),
            },
        };
        var repository = CreateRepository(new FileListApiClient(smallFullPage, nonzeroPage));

        Assert.Null((await repository.ListFilesAsync(string.Empty, 0, 100)).StorageSpace);
        Assert.Null((await repository.ListFilesAsync(string.Empty, 100, 100)).StorageSpace);
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

    private static JsonObject Share(
        string name,
        string path,
        string realPath,
        object total,
        object remaining,
        string totalKey = "totalspace",
        string remainingKey = "freespace") => new()
    {
        ["name"] = name,
        ["path"] = path,
        ["isdir"] = true,
        ["additional"] = new JsonObject
        {
            ["real_path"] = realPath,
            ["volume_status"] = new JsonObject
            {
                [totalKey] = JsonValue.Create(total),
                [remainingKey] = JsonValue.Create(remaining),
            },
        },
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
