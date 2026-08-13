using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Preview;

public sealed class FileMD5RepositoryTests
{
    [Fact]
    public async Task UsesFixedV2FormContractAndReturnsWhitelistedDigest()
    {
        var api = new FakeApi(call => Task.FromResult(call.Method switch
        {
            "start" => Data(("taskid", "md5-task")),
            "status" => new JsonObject
            {
                ["finished"] = true,
                ["md5"] = "ABCDEF0123456789ABCDEF0123456789",
                ["path"] = "/private/not-exposed",
            },
            _ => throw new InvalidOperationException(),
        }));
        var repository = Repository(api);

        var digest = await repository.CalculateMD5Async(" /share/docs/file.txt ");

        Assert.Equal("abcdef0123456789abcdef0123456789", digest);
        Assert.Equal(["start", "status"], api.Calls.Select(call => call.Method));
        var start = api.Calls[0];
        Assert.Equal("/share/docs/file.txt", start.Parameters["file_path"]);
        Assert.DoesNotContain("path", start.Parameters.Keys);
        Assert.All(api.Calls, call =>
        {
            Assert.Equal(2, call.Capability.MinVersion);
            Assert.Equal(2, call.Capability.MaxVersion);
            Assert.Equal("FORM", call.Capability.RequestFormat);
        });
    }

    [Fact]
    public async Task CancellationAfterStartStopsTaskOnce()
    {
        var statusEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeApi(async call =>
        {
            if (call.Method == "start")
            {
                return Data(("taskid", "cancel-task"));
            }
            if (call.Method == "status")
            {
                statusEntered.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, call.Token);
            }
            return new JsonObject();
        });
        var repository = Repository(api);
        using var cancellation = new CancellationTokenSource();
        var calculation = repository.CalculateMD5Async("/share/file.bin", cancellation.Token);
        await statusEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => calculation);
        Assert.Equal(1, api.Calls.Count(call => call.Method == "stop"));
        Assert.Equal("cancel-task", api.Calls.Single(call => call.Method == "stop")
            .Parameters["taskid"]);
    }

    [Fact]
    public async Task CancellationWhileStartIsInFlightWaitsForTaskIdThenStops()
    {
        var startEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStart = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeApi(async call =>
        {
            if (call.Method == "start")
            {
                startEntered.TrySetResult();
                await releaseStart.Task.WaitAsync(call.Token);
                return Data(("taskid", "late-start-task"));
            }
            return new JsonObject();
        });
        var repository = Repository(api);
        using var cancellation = new CancellationTokenSource();
        var calculation = repository.CalculateMD5Async("/share/file.bin", cancellation.Token);
        await startEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        cancellation.Cancel();
        releaseStart.TrySetResult();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => calculation);
        Assert.Equal(["start", "stop"], api.Calls.Select(call => call.Method));
        Assert.Equal("late-start-task", api.Calls[1].Parameters["taskid"]);
    }

    [Fact]
    public async Task SameProfileAllowsOnlyOneActiveTask()
    {
        var statusEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeApi(async call =>
        {
            if (call.Method == "start")
            {
                return Data(("taskid", "active-task"));
            }
            if (call.Method == "status")
            {
                statusEntered.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, call.Token);
            }
            return new JsonObject();
        });
        var firstRepository = Repository(api);
        var secondRepository = Repository(api);
        using var cancellation = new CancellationTokenSource();
        var first = firstRepository.CalculateMD5Async("/share/first.bin", cancellation.Token);
        await statusEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var error = await Assert.ThrowsAsync<FileMD5Exception>(
            () => secondRepository.CalculateMD5Async("/share/second.bin"));

        Assert.Equal(FileMD5Failure.AlreadyRunning, error.Failure);
        Assert.Equal(1, api.Calls.Count(call => call.Method == "start"));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
    }

    [Theory]
    [InlineData("")]
    [InlineData("share/file.bin")]
    [InlineData("/share/../private")]
    [InlineData("/share\\file.bin")]
    public async Task InvalidPathSendsNoRequest(string path)
    {
        var api = new FakeApi();
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<FileMD5Exception>(
            () => repository.CalculateMD5Async(path));

        Assert.Equal(FileMD5Failure.InvalidPath, error.Failure);
        Assert.Empty(api.Calls);
    }

    private static DsmRepository Repository(FakeApi api)
    {
        var profile = new NasProfile(ProfileId, "NAS", "nas.example.invalid", null, "user");
        var capability = new ApiCapability(ApiName, "entry.cgi", 1, 4, "FORM");
        return new DsmRepository(
            profile,
            new DsmSession(ProfileId, "synthetic-sid", null, null),
            api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                [ApiName] = capability,
            })
        {
            FileMD5InitialPollDelay = TimeSpan.Zero,
            FileMD5MaximumPollDelay = TimeSpan.Zero,
        };
    }

    private static JsonObject Data(params (string Key, object? Value)[] values)
    {
        var result = new JsonObject();
        foreach (var (key, value) in values)
        {
            result[key] = JsonValue.Create(value);
        }
        return result;
    }

    private const string ApiName = "SYNO.FileStation.MD5";
    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    private sealed record ApiCall(
        ApiCapability Capability,
        string Method,
        IReadOnlyDictionary<string, string> Parameters,
        CancellationToken Token);

    private sealed class FakeApi(
        Func<ApiCall, Task<JsonObject>>? handler = null) : IDsmApiClient
    {
        private readonly Func<ApiCall, Task<JsonObject>> _handler =
            handler ?? (_ => throw new InvalidOperationException("Unexpected request."));
        private readonly ConcurrentQueue<ApiCall> _calls = new();

        public IReadOnlyList<ApiCall> Calls => _calls.ToArray();

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            var call = new ApiCall(
                capability,
                method,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(),
                    StringComparer.Ordinal),
                cancellationToken);
            _calls.Enqueue(call);
            return _handler(call);
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.example.invalid/");
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
