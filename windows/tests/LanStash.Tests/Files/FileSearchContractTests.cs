using System.Text.Json.Nodes;
using LanStash.App.Features.Files;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files;

public sealed class FileSearchContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("33333333-3333-3333-3333-333333333333"),
        "SearchTest",
        "nas.invalid",
        null,
        "tester");

    private static readonly DsmSession Session = new(Profile.Id, "sid-search", null, null);

    private static readonly ApiCapability SearchCapability = new(
        "SYNO.FileStation.Search", "entry.cgi", 1, 3, "FORM");

    [Fact]
    public async Task SearchAsync_StartPollListCleanLifecycle_ReturnsResults()
    {
        var api = new SearchScriptedApi();
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "*.txt", Recursive: true);
        var result = await repository.SearchAsync(request);

        Assert.Equal(2, result.TotalCount);
        Assert.False(result.IsTruncated);
        Assert.Equal(2, result.Items.Count);
        Assert.Contains(result.Items, item => item.Name == "doc1.txt");
        Assert.Contains(result.Items, item => item.Name == "doc2.txt");

        // 核对启动、轮询、列出结果和清理的完整生命周期。
        Assert.Contains(api.Calls, call => call == "start");
        Assert.Contains(api.Calls, call => call == "list");
        Assert.Contains(api.Calls, call => call == "stop");
        // 轮询阶段至少有一次返回完成状态的 list 调用。
        var listCalls = api.Calls.Count(call => call == "list");
        Assert.True(listCalls >= 1);
        var stopCalls = api.Calls.Count(call => call == "stop");
        Assert.Equal(1, stopCalls);
    }

    [Fact]
    public async Task SearchAsync_NoResults_ReturnsEmptyList()
    {
        var api = new SearchScriptedApi(fileCount: 0);
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "nonexistent", Recursive: true);
        var result = await repository.SearchAsync(request);

        Assert.Empty(result.Items);
        Assert.Equal(0, result.TotalCount);
        Assert.False(result.IsTruncated);
        Assert.Contains(api.Calls, call => call == "stop");
    }

    [Fact]
    public async Task SearchAsync_TruncatedResults_ReturnsTruncatedFlag()
    {
        var api = new SearchScriptedApi(fileCount: 2000, totalFileCount: 3000);
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "*.log", Recursive: true);
        var result = await repository.SearchAsync(request);

        Assert.Equal(2000, result.TotalCount);
        Assert.True(result.IsTruncated);
        Assert.Equal(2000, result.Items.Count);
    }

    [Fact]
    public async Task SearchAsync_EmptyQuery_ReturnsEmpty()
    {
        var api = new SearchScriptedApi();
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "", Recursive: true);
        var result = await repository.SearchAsync(request);

        Assert.Empty(result.Items);
        Assert.Equal(0, result.TotalCount);
        Assert.False(result.IsTruncated);
        // 空查询不应发出任何请求。
        Assert.DoesNotContain(api.Calls, call => call == "start");
    }

    [Fact]
    public async Task SearchAsync_WithoutCapability_ThrowsNotSupported()
    {
        var api = new SearchScriptedApi();
        IFileSearchRepository repository = new DsmRepository(
            Profile, Session, api, new Dictionary<string, ApiCapability>());

        Assert.False(repository.IsSearchAvailable);

        var request = new FileSearchRequest("/share", "test", Recursive: true);
        await Assert.ThrowsAsync<NotSupportedException>(() => repository.SearchAsync(request));
    }

    [Fact]
    public async Task SearchAsync_Cancellation_RespectsCancellation()
    {
        var api = new SearchScriptedApi(delayPerCall: TimeSpan.FromMilliseconds(500));
        var repository = SearchRepository(api);

        using var cts = new CancellationTokenSource();
        cts.CancelAfter(100);

        var request = new FileSearchRequest("/share", "test", Recursive: true);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => repository.SearchAsync(request, cts.Token));

        // 取消后仍应尽力清理服务端任务。
        Assert.Contains(api.Calls, call => call == "stop");
    }

    [Fact]
    public async Task SearchAsync_NonRecursive_DoesNotSearchSubfolders()
    {
        var api = new SearchScriptedApi();
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "*.txt", Recursive: false);
        var result = await repository.SearchAsync(request);

        Assert.NotNull(result);
        var startCall = api.StartParameters.FirstOrDefault();
        Assert.NotNull(startCall);
        Assert.Equal("false", startCall!["recursive"]);
    }

    [Fact]
    public async Task SearchAsync_StopFailure_StillReturnsResults()
    {
        var api = new SearchScriptedApi(throwOnStop: true);
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "test", Recursive: true);
        var result = await repository.SearchAsync(request);

        Assert.Equal(2, result.TotalCount);
        // 即使清理失败，也确实尝试过 stop。
        Assert.Contains(api.Calls, call => call == "stop");
    }

    [Fact]
    public async Task SearchAsync_StartReturnsNoTaskId_ThrowsDsmException()
    {
        var api = new ScriptedApi(request => request.Method switch
        {
            "start" => new JsonObject(),
            _ => throw new InvalidOperationException(),
        });
        var repository = SearchRepository(api);

        var request = new FileSearchRequest("/share", "test", Recursive: true);
        await Assert.ThrowsAsync<DsmException>(() => repository.SearchAsync(request));
    }

    [Fact]
    public void SearchViewModelClearsStaleStateAcrossSuccessRetryAndFailure()
    {
        using var model = new FileBrowserViewModel(new ImmediateSource());
        var result = new FileItem(
            "/share/result.txt", "result.txt", false, 42, null, null, true, true);

        model.SetAsyncSearchResults([result], 2500, isTruncated: true);
        Assert.True(model.HasSearchTruncationNotice);
        Assert.Equal(2500, model.SearchResultCount);

        model.BeginAsyncSearch();
        Assert.True(model.IsSearching);
        Assert.False(model.HasSearchTruncationNotice);
        Assert.False(model.HasSearchError);
        Assert.Equal(0, model.SearchResultCount);

        model.SetAsyncSearchError();
        Assert.False(model.IsSearching);
        Assert.True(model.HasSearchError);
        Assert.False(model.HasSearchTruncationNotice);
        Assert.Equal(0, model.SearchResultCount);
    }

    private static IFileSearchRepository SearchRepository(IDsmApiClient api)
    {
        var capabilities = new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.Search"] = SearchCapability,
        };
        return new DsmRepository(Profile, Session, api, capabilities);
    }

    /// <summary>
    /// 用于文件搜索测试的脚本化 API 客户端，可配置完整任务生命周期行为。
    /// </summary>
    private sealed class SearchScriptedApi : IDsmApiClient
    {
        private readonly int _fileCount;
        private readonly int _totalFileCount;
        private readonly TimeSpan _delayPerCall;
        private readonly bool _throwOnStop;
        private bool _hasReturnedFinished;

        public List<string> Calls { get; } = new();
        public List<Dictionary<string, string>> StartParameters { get; } = new();

        public SearchScriptedApi(
            int fileCount = 2,
            int totalFileCount = 2,
            TimeSpan? delayPerCall = null,
            bool throwOnStop = false)
        {
            _fileCount = fileCount;
            _totalFileCount = totalFileCount;
            _delayPerCall = delayPerCall ?? TimeSpan.Zero;
            _throwOnStop = throwOnStop;
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return method switch
            {
                "start" => StartAsync(parameters ?? new Dictionary<string, string>(), cancellationToken),
                "list" => ListAsync(cancellationToken),
                "stop" => StopAsync(cancellationToken),
                _ => throw new NotSupportedException(),
            };
        }

        private async Task<JsonObject> StartAsync(
            IReadOnlyDictionary<string, string> parameters,
            CancellationToken cancellationToken)
        {
            Calls.Add("start");
            StartParameters.Add(new Dictionary<string, string>(parameters));
            return new JsonObject { ["taskid"] = "search-task-42" };
        }

        private async Task<JsonObject> ListAsync(CancellationToken cancellationToken)
        {
            Calls.Add("list");
            await Task.Delay(_delayPerCall, cancellationToken);

            if (!_hasReturnedFinished)
            {
                _hasReturnedFinished = true;
                // 首次 list 调用返回已完成状态。
                return new JsonObject
                {
                    ["files"] = new JsonArray(),
                    ["offset"] = 0,
                    ["total"] = 0,
                    ["finished"] = true,
                };
            }

            // 后续 list 调用返回实际结果。
            var boundedCount = Math.Min(_fileCount, _totalFileCount);
            var items = new JsonArray();
            for (var i = 0; i < boundedCount; i++)
            {
                items.Add(new JsonObject
                {
                    ["path"] = $"/share/doc{i + 1}.txt",
                    ["name"] = $"doc{i + 1}.txt",
                    ["isdir"] = false,
                    ["size"] = 1024 + (i * 512),
                    ["mtime"] = 1710000000 + i,
                    ["owner"] = new JsonObject { ["name"] = "tester" },
                });
            }

            var displayCount = Math.Min(boundedCount, 2000);
            var truncated = _totalFileCount > 2000;

            return new JsonObject
            {
                ["files"] = items,
                ["offset"] = 0,
                ["total"] = truncated ? Math.Max(_totalFileCount, 2000) : boundedCount,
            };
        }

        private async Task<JsonObject> StopAsync(CancellationToken cancellationToken)
        {
            Calls.Add("stop");
            if (_throwOnStop)
            {
                throw new DsmException("cleanup", "stop_failed", 500);
            }
            await Task.Delay(_delayPerCall, cancellationToken);
            return new JsonObject { ["success"] = true };
        }

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    /// <summary>
    /// 基础测试使用的单处理器脚本化 API 客户端。
    /// </summary>
    private sealed class ScriptedApi : IDsmApiClient
    {
        private readonly Func<ApiRequest, JsonObject> _handler;

        public ScriptedApi(Func<ApiRequest, JsonObject> handler) => _handler = handler;

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid/");

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
                capability.Name,
                method,
                parameters ?? new Dictionary<string, string>());
            return Task.FromResult(_handler(request));
        }

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed record ApiRequest(
        string ApiName,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class ImmediateSource : IFileBrowserDataSource
    {
        public Task<FilePage> LoadPageAsync(
            string path,
            int offset,
            int limit,
            FileListOptions options,
            CancellationToken cancellationToken) =>
            Task.FromResult(new FilePage([], 0, offset));
    }
}
