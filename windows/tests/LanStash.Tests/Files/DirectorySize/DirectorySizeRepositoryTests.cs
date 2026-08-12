using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.DirectorySize;

public sealed class DirectorySizeRepositoryTests
{
    [Theory]
    [InlineData(1, 2, "FORM", true)]
    [InlineData(2, 4, "form", true)]
    [InlineData(1, 1, "FORM", false)]
    [InlineData(3, 4, "FORM", false)]
    [InlineData(2, 2, "JSON", false)]
    public void AvailabilityRequiresOfficialVersionTwoFormCapability(
        int minVersion,
        int maxVersion,
        string requestFormat,
        bool expected)
    {
        var repository = Repository(new FakeApi(), ProfileId,
            Capability(minVersion, maxVersion, requestFormat));

        Assert.Equal(expected, repository.DirectorySizeAvailability.CanCalculate);
        Assert.Equal(expected ? 2 : null, repository.DirectorySizeAvailability.Version);
        Assert.Equal(expected, ((IDirectorySizeRepository)repository).Availability.IsAvailable);
    }

    [Fact]
    public async Task CalculatesWithOneFixedV2StartAndReturnsOnlyWhitelistedCounts()
    {
        var api = new FakeApi(call => call.Method switch
        {
            "start" => Task.FromResult(Data(("taskid", "dirsize-task"))),
            "status" when call.Sequence == 2 => Task.FromResult(new JsonObject
            {
                ["finished"] = false,
                ["processing_path"] = "/private/source",
                ["password"] = "PRIVATE_VALUE",
            }),
            "status" => Task.FromResult(new JsonObject
            {
                ["finished"] = true,
                ["total_size"] = "4096",
                ["num_file"] = 3,
                ["num_dir"] = "2",
                ["processing_path"] = "/private/source",
            }),
            _ => throw new InvalidOperationException(),
        });
        var repository = Repository(api);

        var result = await repository.CalculateDirectorySizeAsync(" /share//docs/ ");

        Assert.Equal(new DirectorySizeResult(4096, 3, 2), result);
        Assert.Equal(["start", "status", "status"], api.Calls.Select(call => call.Method));
        Assert.All(api.Calls, call =>
        {
            Assert.Equal(2, call.Capability.MinVersion);
            Assert.Equal(2, call.Capability.MaxVersion);
        });
        var paths = JsonSerializer.Deserialize<string[]>(api.Calls[0].Parameters!["path"]);
        Assert.NotNull(paths);
        Assert.Equal(["/share/docs"], paths);
        Assert.Equal("dirsize-task", api.Calls[1].Parameters!["taskid"]);
        Assert.DoesNotContain("private", result.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("dirsize-task", result.ToString(), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("")]
    [InlineData("share/docs")]
    [InlineData("/share/../private")]
    [InlineData("/share/./docs")]
    [InlineData("/share\\docs")]
    public async Task InvalidPathIsRejectedBeforeAnyRequest(string path)
    {
        var api = new FakeApi();
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync(path));

        Assert.Equal(DirectorySizeFailure.InvalidPath, error.Failure);
        Assert.Empty(api.Calls);
        if (path.Length > 0)
        {
            Assert.DoesNotContain(path, error.ToString(), StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task UnsupportedCapabilitySendsNoRequest()
    {
        var api = new FakeApi();
        var repository = Repository(api, ProfileId, Capability(3, 4, "FORM"));

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync("/share/docs"));

        Assert.Equal(DirectorySizeFailure.Unsupported, error.Failure);
        Assert.Empty(api.Calls);
    }

    [Fact]
    public async Task UnsafeTaskIdentifierStopsBeforeStatusAndIsNotEchoed()
    {
        const string unsafeTaskId = "unsafe/task/private";
        var api = new FakeApi(call => Task.FromResult(Data(("taskid", unsafeTaskId))));
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync("/share/docs"));

        Assert.Equal(DirectorySizeFailure.InvalidResponse, error.Failure);
        Assert.Equal(["start"], api.Calls.Select(call => call.Method));
        Assert.DoesNotContain(unsafeTaskId, error.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task TimeoutUsesBoundedPollingThenBestEffortStopWithoutReplayingStart()
    {
        var api = new FakeApi(call => Task.FromResult(call.Method switch
        {
            "start" => Data(("taskid", "timeout-task")),
            "status" => Data(("finished", false)),
            "stop" => new JsonObject(),
            _ => throw new InvalidOperationException(),
        }));
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync("/share/docs"));

        Assert.Equal(DirectorySizeFailure.Timeout, error.Failure);
        Assert.Equal(1, api.Calls.Count(call => call.Method == "start"));
        Assert.Equal(30, api.Calls.Count(call => call.Method == "status"));
        var stop = Assert.Single(api.Calls, call => call.Method == "stop");
        Assert.True(stop.Token.CanBeCanceled);
        Assert.False(stop.Token.IsCancellationRequested);
    }

    [Fact]
    public async Task CancellationAfterSubmissionUsesIndependentStopToken()
    {
        var statusEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeApi(async call =>
        {
            if (call.Method == "start")
            {
                return Data(("taskid", "cancel-task"));
            }
            if (call.Method == "status")
            {
                statusEntered.TrySetResult(true);
                await Task.Delay(Timeout.InfiniteTimeSpan, call.Token);
            }
            return new JsonObject();
        });
        var repository = Repository(api);
        using var cancellation = new CancellationTokenSource();
        var operation = repository.CalculateDirectorySizeAsync("/share/docs", cancellation.Token);
        await statusEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operation);
        var stop = Assert.Single(api.Calls, call => call.Method == "stop");
        Assert.True(stop.Token.CanBeCanceled);
        Assert.False(stop.Token.IsCancellationRequested);
        Assert.Equal(["start", "status", "stop"], api.Calls.Select(call => call.Method));
    }

    [Fact]
    public async Task PollingFailureStopsAndDoesNotLeakPathTaskOrInnerError()
    {
        const string privatePath = "/share/private-folder";
        const string taskId = "private-task";
        var api = new FakeApi(call => call.Method switch
        {
            "start" => Task.FromResult(Data(("taskid", taskId))),
            "status" => Task.FromException<JsonObject>(
                new InvalidOperationException($"{privatePath}:{taskId}")),
            "stop" => Task.FromResult(new JsonObject()),
            _ => throw new InvalidOperationException(),
        });
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync(privatePath));

        Assert.Equal(DirectorySizeFailure.PollingFailed, error.Failure);
        Assert.Equal(["start", "status", "stop"], api.Calls.Select(call => call.Method));
        Assert.DoesNotContain(privatePath, error.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain(taskId, error.ToString(), StringComparison.Ordinal);
        Assert.Null(error.InnerException);
    }

    [Theory]
    [InlineData(-1L, 1L, 1L)]
    [InlineData(1L, -1L, 1L)]
    [InlineData(1L, 1L, -1L)]
    public async Task InvalidCompletedResponseDoesNotStopFinishedTask(
        long totalBytes,
        long fileCount,
        long directoryCount)
    {
        var api = new FakeApi(call => Task.FromResult(call.Method switch
        {
            "start" => Data(("taskid", "finished-task")),
            "status" => new JsonObject
            {
                ["finished"] = true,
                ["total_size"] = totalBytes,
                ["num_file"] = fileCount,
                ["num_dir"] = directoryCount,
            },
            _ => throw new InvalidOperationException(),
        }));
        var repository = Repository(api);

        var error = await Assert.ThrowsAsync<DirectorySizeException>(
            () => repository.CalculateDirectorySizeAsync("/share/docs"));

        Assert.Equal(DirectorySizeFailure.InvalidResponse, error.Failure);
        Assert.Equal(["start", "status"], api.Calls.Select(call => call.Method));
    }

    [Fact]
    public async Task CompletedResponseMissingAWhitelistedCountDoesNotStopFinishedTask()
    {
        var api = new FakeApi(call => Task.FromResult(call.Method switch
        {
            "start" => Data(("taskid", "finished-task")),
            "status" => Data(
                ("finished", true),
                ("num_file", 1),
                ("num_dir", 1)),
            _ => throw new InvalidOperationException(),
        }));

        var error = await Assert.ThrowsAsync<DirectorySizeException>(() =>
            Repository(api).CalculateDirectorySizeAsync("/share/docs"));

        Assert.Equal(DirectorySizeFailure.InvalidResponse, error.Failure);
        Assert.Equal(["start", "status"], api.Calls.Select(call => call.Method));
    }

    [Fact]
    public async Task SameProfileAndNormalizedPathAllowsOnlyOneActiveCalculation()
    {
        var statusEntered = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeApi(async call =>
        {
            if (call.Method == "start")
            {
                return Data(("taskid", "active-task"));
            }
            if (call.Method == "status")
            {
                statusEntered.TrySetResult(true);
                await Task.Delay(Timeout.InfiniteTimeSpan, call.Token);
            }
            return new JsonObject();
        });
        var firstRepository = Repository(api);
        var secondRepository = Repository(api);
        using var cancellation = new CancellationTokenSource();
        var first = firstRepository.CalculateDirectorySizeAsync("/share/docs/", cancellation.Token);
        await statusEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        var duplicate = await Assert.ThrowsAsync<DirectorySizeException>(
            () => secondRepository.CalculateDirectorySizeAsync("/share//docs"));

        Assert.Equal(DirectorySizeFailure.AlreadyRunning, duplicate.Failure);
        Assert.Equal(1, api.Calls.Count(call => call.Method == "start"));
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
    }

    private static DsmRepository Repository(
        FakeApi api,
        Guid? profileId = null,
        ApiCapability? capability = null)
    {
        var id = profileId ?? ProfileId;
        var profile = new NasProfile(id, "NAS", "nas.example.invalid", null, "user");
        var capabilities = capability is null
            ? new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            : new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                [capability.Name] = capability,
            };
        if (capability is null)
        {
            capabilities[ApiName] = Capability(1, 4, "FORM");
        }
        return new DsmRepository(
            profile,
            new DsmSession(id, "sid", null, null),
            api,
            capabilities)
        {
            DirectorySizeInitialPollDelay = TimeSpan.Zero,
            DirectorySizeMaximumPollDelay = TimeSpan.Zero,
        };
    }

    private static ApiCapability Capability(int min, int max, string requestFormat) =>
        new(ApiName, "entry.cgi", min, max, requestFormat);

    private static JsonObject Data(params (string Key, object? Value)[] values)
    {
        var result = new JsonObject();
        foreach (var (key, value) in values)
        {
            result[key] = JsonValue.Create(value);
        }
        return result;
    }

    private const string ApiName = "SYNO.FileStation.DirSize";
    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    private sealed record ApiCall(
        int Sequence,
        ApiCapability Capability,
        string Method,
        IReadOnlyDictionary<string, string>? Parameters,
        CancellationToken Token);

    private sealed class FakeApi(
        Func<ApiCall, Task<JsonObject>>? handler = null) : IDsmApiClient
    {
        private readonly Func<ApiCall, Task<JsonObject>> _handler =
            handler ?? (_ => throw new InvalidOperationException("Unexpected request."));
        private readonly ConcurrentQueue<ApiCall> _calls = new();
        private int _sequence;

        public IReadOnlyList<ApiCall> Calls => _calls.ToArray();

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

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            var call = new ApiCall(
                Interlocked.Increment(ref _sequence),
                capability,
                method,
                parameters is null
                    ? null
                    : new Dictionary<string, string>(parameters, StringComparer.Ordinal),
                cancellationToken);
            _calls.Enqueue(call);
            return _handler(call);
        }
    }
}
