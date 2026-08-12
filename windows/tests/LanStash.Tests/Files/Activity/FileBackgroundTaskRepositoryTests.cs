using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Activity;

public sealed class FileBackgroundTaskRepositoryTests
{
    [Fact]
    public async Task UsesExactBoundedPublicV3Request()
    {
        var api = new RecordingApi(_ => Page(0, 0));
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(-20, 5_000);

        Assert.Empty(page.Tasks);
        var request = Assert.Single(api.Requests);
        Assert.Equal("SYNO.FileStation.BackgroundTask", request.ApiName);
        Assert.Equal(3, request.Version);
        Assert.Equal("list", request.Method);
        Assert.Equal(new Dictionary<string, string>
        {
            ["offset"] = "0",
            ["limit"] = "100",
            ["sort_by"] = "crtime",
            ["sort_direction"] = "desc",
            ["api_filter"] = "[\"SYNO.FileStation.CopyMove\",\"SYNO.FileStation.Delete\",\"SYNO.FileStation.Extract\",\"SYNO.FileStation.Compress\"]",
        }, request.Parameters);
    }

    [Fact]
    public async Task ClampsNonPositiveLimitToOne()
    {
        var api = new RecordingApi(_ => Page(8, 8));
        var repository = Repository(api);

        await repository.ListTasksAsync(8, 0);

        var request = Assert.Single(api.Requests);
        Assert.Equal("1", request.Parameters["limit"]);
        Assert.Equal("8", request.Parameters["offset"]);
    }

    [Theory]
    [InlineData(null, 0, 0, "FORM")]
    [InlineData("SYNO.FileStation.BackgroundTask", 1, 2, "FORM")]
    [InlineData("SYNO.FileStation.BackgroundTask", 4, 5, "FORM")]
    [InlineData("SYNO.FileStation.BackgroundTask", 3, 3, "JSON")]
    [InlineData("SYNO.FileStation.Other", 3, 3, "FORM")]
    public async Task UnavailableCapabilityMakesNoRequest(
        string? capabilityName,
        int minimumVersion,
        int maximumVersion,
        string requestFormat)
    {
        var api = new RecordingApi(_ => throw new InvalidOperationException());
        var capabilities = capabilityName is null
            ? new Dictionary<string, ApiCapability>()
            : new Dictionary<string, ApiCapability>
            {
                ["SYNO.FileStation.BackgroundTask"] = new ApiCapability(
                    capabilityName, "entry.cgi", minimumVersion, maximumVersion, requestFormat),
            };
        var repository = Repository(api, capabilities);

        Assert.False(repository.IsAvailable);
        await Assert.ThrowsAsync<NotSupportedException>(() => repository.ListTasksAsync(0, 100));
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task MapsWhitelistAndDoesNotRetainPrivateFieldsOrInferFinishedSuccess()
    {
        var api = new RecordingApi(_ => Page(0, 4,
            Task("SYNO.FileStation.CopyMove", "copy-1", false,
                ("progress", 0.25), ("crtime", 1_700_000_000),
                ("processed_num", 2), ("processed_size", 1_024), ("total", 4_096),
                ("params", new JsonObject { ["password"] = "PRIVATE_PASSWORD" }),
                ("path", "/volume1/private/source.txt"),
                ("processing_path", "/volume1/private/current.txt"), ("message", "PRIVATE_MESSAGE")),
            Task("SYNO.FileStation.Delete", "delete-1", true,
                ("processed_num", 3), ("processed_size", 2_048), ("total", 9)),
            Task("SYNO.FileStation.Extract", "extract-1", false, ("total", 99)),
            Task("SYNO.FileStation.Compress", "compress-1", true, ("total", 88))));
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(0, 100);

        Assert.Equal(4, page.Tasks.Count);
        Assert.Equal(FileBackgroundTaskKind.CopyOrMove, page.Tasks[0].Kind);
        Assert.Equal(FileBackgroundTaskState.Active, page.Tasks[0].State);
        Assert.Equal(0.25, page.Tasks[0].Progress);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), page.Tasks[0].CreatedAt);
        Assert.Equal(4_096, page.Tasks[0].TotalBytes);
        Assert.Null(page.Tasks[0].TotalItemCount);
        Assert.Equal(FileBackgroundTaskKind.Delete, page.Tasks[1].Kind);
        Assert.Equal(FileBackgroundTaskState.Finished, page.Tasks[1].State);
        Assert.Equal(9, page.Tasks[1].TotalItemCount);
        Assert.Null(page.Tasks[1].TotalBytes);
        Assert.All(page.Tasks.Skip(2), task =>
        {
            Assert.Null(task.TotalItemCount);
            Assert.Null(task.TotalBytes);
        });
        var description = page.ToString();
        Assert.DoesNotContain("/volume1", description, StringComparison.Ordinal);
        Assert.DoesNotContain("PRIVATE_PASSWORD", description, StringComparison.Ordinal);
        Assert.DoesNotContain("PRIVATE_MESSAGE", description, StringComparison.Ordinal);
    }

    [Fact]
    public void DomainSummaryExposesOnlyTheApprovedWhitelist()
    {
        Assert.Equal(
            ["CreatedAt", "Id", "Kind", "ProcessedBytes", "ProcessedItemCount", "Progress", "State", "TotalBytes", "TotalItemCount"],
            typeof(FileBackgroundTaskSummary).GetProperties().Select(property => property.Name).Order().ToArray());
    }

    [Fact]
    public async Task AcceptsDocumentedNumericAndBooleanStringVariants()
    {
        var api = new RecordingApi(_ => new JsonObject
        {
            ["offset"] = "7",
            ["total"] = "8",
            ["tasks"] = new JsonArray
            {
                Task("SYNO.FileStation.Delete", "variant-1", "1",
                    ("progress", "0.5"), ("crtime", "1700000000"),
                    ("processed_num", "3"), ("processed_size", "2048"), ("total", "6")),
            },
        });
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(7, 1);

        var task = Assert.Single(page.Tasks);
        Assert.Equal(FileBackgroundTaskState.Finished, task.State);
        Assert.Equal(0.5, task.Progress);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000), task.CreatedAt);
        Assert.Equal(3, task.ProcessedItemCount);
        Assert.Equal(2_048, task.ProcessedBytes);
        Assert.Equal(6, task.TotalItemCount);
        Assert.Equal(8, page.NextOffset);
    }

    [Fact]
    public async Task DropsUnknownUnsafeDuplicateAndMalformedTasksWhileAdvancingRawRows()
    {
        var api = new RecordingApi(_ => Page(10, 15,
            Task("SYNO.FileStation.CopyMove", "safe-1", false),
            Task("SYNO.FileStation.Future", "future-1", false),
            Task("SYNO.FileStation.Delete", "/volume1/private/task", false),
            Task("SYNO.FileStation.CopyMove", "safe-1", true),
            Task("SYNO.FileStation.Delete", "safe-2", false, ("processed_num", 4), ("total", 9))));
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(10, 100);

        Assert.Equal(["safe-1", "safe-2"], page.Tasks.Select(task => task.Id));
        Assert.Equal(15, page.NextOffset);
        Assert.False(page.HasMore);
    }

    [Fact]
    public async Task InvalidOptionalValuesBecomeUnavailableWithoutDroppingTask()
    {
        var api = new RecordingApi(_ => Page(0, 1,
            Task("SYNO.FileStation.CopyMove", "safe-1", false,
                ("progress", 0), ("crtime", long.MaxValue),
                ("processed_num", -1), ("processed_size", "9223372036854775808"),
                ("total", -5))));
        var repository = Repository(api);

        var task = Assert.Single((await repository.ListTasksAsync(0, 100)).Tasks);

        Assert.Null(task.Progress);
        Assert.Null(task.CreatedAt);
        Assert.Null(task.ProcessedItemCount);
        Assert.Null(task.ProcessedBytes);
        Assert.Null(task.TotalBytes);
    }

    [Fact]
    public async Task MaliciousPaginationIsBoundedAndCannotOverflow()
    {
        var tasks = Enumerable.Range(0, 150)
            .Select(index => Task("SYNO.FileStation.Delete", $"task-{index}", false))
            .ToArray();
        var api = new RecordingApi(_ => new JsonObject
        {
            ["offset"] = "9223372036854775808",
            ["total"] = long.MaxValue,
            ["tasks"] = new JsonArray(tasks),
        });
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(int.MaxValue, 100);

        Assert.Equal(100, page.Tasks.Count);
        Assert.Equal(int.MaxValue, page.Offset);
        Assert.Equal(int.MaxValue, page.NextOffset);
        Assert.Equal(int.MaxValue, page.Total);
        Assert.False(page.HasMore);
    }

    [Fact]
    public async Task OversizedResponseIsBoundedAndReportsMoreWithoutTrustingTotal()
    {
        var tasks = Enumerable.Range(0, 101)
            .Select(index => Task("SYNO.FileStation.Delete", $"task-{index}", false))
            .ToArray();
        var api = new RecordingApi(_ => new JsonObject
        {
            ["tasks"] = new JsonArray(tasks),
        });
        var repository = Repository(api);

        var page = await repository.ListTasksAsync(0, 100);

        Assert.Equal(100, page.Tasks.Count);
        Assert.Equal(100, page.NextOffset);
        Assert.True(page.HasMore);
    }

    [Fact]
    public async Task EmptyPageNeverClaimsMoreWork()
    {
        var repository = Repository(new RecordingApi(_ => Page(20, 100)));

        var page = await repository.ListTasksAsync(20, 100);

        Assert.Equal(20, page.NextOffset);
        Assert.False(page.HasMore);
    }

    private static IFileBackgroundTaskRepository Repository(
        RecordingApi api,
        IReadOnlyDictionary<string, ApiCapability>? capabilities = null)
    {
        var profile = new NasProfile(Guid.NewGuid(), "NAS", "nas.invalid", 5001, "user");
        capabilities ??= new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.BackgroundTask"] = new ApiCapability(
                "SYNO.FileStation.BackgroundTask", "entry.cgi", 3, 3, "FORM"),
        };
        return new DsmRepository(
            profile,
            new DsmSession(profile.Id, "synthetic-session", null, null),
            api,
            capabilities);
    }

    private static JsonObject Page(int offset, int total, params JsonObject[] tasks) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["tasks"] = new JsonArray(tasks),
    };

    private static JsonObject Task(string api, string id, object finished, params (string Key, object? Value)[] fields)
    {
        var item = new JsonObject
        {
            ["api"] = api,
            ["taskid"] = id,
            ["finished"] = JsonValue.Create(finished),
        };
        foreach (var (key, value) in fields)
        {
            item[key] = value as JsonNode ?? JsonValue.Create(value);
        }
        return item;
    }

    private sealed record ApiRequest(
        string ApiName,
        int Version,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class RecordingApi(Func<ApiRequest, JsonObject> response) : IDsmApiClient
    {
        public ConcurrentQueue<ApiRequest> Requests { get; } = new();

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
                requiredVersion,
                method,
                new Dictionary<string, string>(parameters ?? new Dictionary<string, string>()));
            Requests.Enqueue(request);
            return System.Threading.Tasks.Task.FromResult(response(request));
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
