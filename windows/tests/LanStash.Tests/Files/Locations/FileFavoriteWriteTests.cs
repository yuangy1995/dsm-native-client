using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class FileFavoriteWriteTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ProductionRequestsMatchSharedFavoriteFixtures(string format)
    {
        using var fixture = new Fixture(format);
        const string path = "/<synthetic-path>"; const string name = "<synthetic-name>";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.AddFavoriteAsync(path, name)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.RemoveFavoriteAsync(path)).Status);
        foreach (var operation in new[] { "add-favorite", "remove-favorite" })
        {
            var sample = ReadFixture(operation); var method = sample["api"]!["method"]!.GetValue<string>();
            var call = Assert.Single(fixture.Calls, call => call["method"] == method);
            foreach (var parameter in sample["parameters"]!.AsArray())
            {
                var key = parameter!["name"]!.GetValue<string>(); var expected = parameter["encodedValue"]!.GetValue<string>();
                if (key == "path") expected = "/" + expected;
                Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(expected) : expected, call[key]);
            }
        }
    }

    private static JsonNode ReadFixture(string operation)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, $"contracts/request-fixtures/file-station/{operation}/synthetic-location/request.json");
            if (File.Exists(path)) return JsonNode.Parse(File.ReadAllText(path))!;
        }
        throw new FileNotFoundException("缺少共享收藏请求样例。");
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task RealTransportAddsAndRemovesWithExactReadbackAndNoDuplicateWrites(string format)
    {
        using var fixture = new Fixture(format);
        Assert.True(fixture.Repository.CanWriteFavorites); Assert.False(fixture.Repository.AllowsRemoteMountManagement);
        var added = await fixture.Repository.AddFavoriteAsync("/share/folder", " 收藏 +& ");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, added.Status);
        var write = Assert.Single(fixture.Calls, call => call["method"] == "add");
        Assert.Equal("2", write["version"]);
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("/share/folder") : "/share/folder", write["path"]);
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("收藏 +&") : "收藏 +&", write["name"]);
        // 沿用现有 HTTPS 表单/请求头会话策略；凭据值只能来自绑定会话，不能进入 URL。
        Assert.Equal("synthetic-sid", write["_sid"]); Assert.Equal("synthetic-token", write["SynoToken"]);
        Assert.False((await fixture.Repository.AddFavoriteAsync("/share/folder", "收藏 +&")).Submitted);
        var removed = await fixture.Repository.RemoveFavoriteAsync("/share/folder");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, removed.Status);
        Assert.False((await fixture.Repository.RemoveFavoriteAsync("/share/folder")).Submitted);
        Assert.Single(fixture.Calls, call => call["method"] == "add"); Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task OmittedNameUsesTheLastPathComponent()
    {
        using var fixture = new Fixture("FORM");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.AddFavoriteAsync("/share/folder")).Status);
        Assert.Equal("folder", Assert.Single(fixture.Calls, call => call["method"] == "add")["name"]);
    }

    [Fact]
    public async Task ConcurrentCallCannotSubmitTwice()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var fixture = new Fixture("FORM") { WriteStarted = started, WriteGate = release.Task };
        var first = fixture.Repository.AddFavoriteAsync("/share/folder", "wanted"); await started.Task;
        var duplicate = await fixture.Reconnect().AddFavoriteAsync("/share/folder", "wanted");
        Assert.False(duplicate.Submitted); Assert.Equal(MutationErrorCategory.Conflict, duplicate.ErrorCategory);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Status);
        Assert.Single(fixture.Calls, call => call["method"] == "add");
    }

    [Fact]
    public async Task RecoveryRecordsDoNotCrossProfileOrMismatchedSession()
    {
        using var fixture = new Fixture("FORM") { LoseResponse = true };
        await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted");
        Assert.Single(await fixture.Repository.GetFavoriteMutationRecoveriesAsync());
        Assert.Empty(await fixture.Reconnect(differentProfile: true).GetFavoriteMutationRecoveriesAsync());
        Assert.Empty(await fixture.Reconnect(wrongSession: true).GetFavoriteMutationRecoveriesAsync());
    }

    [Fact]
    public async Task WrongNameDoesNotConfirmAndUnknownBlocksOppositeOperation()
    {
        using var fixture = new Fixture("FORM") { WrongName = true };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted")).Status);
        var conflict = await fixture.Repository.RemoveFavoriteAsync("/share/folder");
        Assert.False(conflict.Submitted); Assert.Equal(MutationErrorCategory.Conflict, conflict.ErrorCategory);
        Assert.Single(await fixture.Reconnect().GetFavoriteMutationRecoveriesAsync());
        fixture.Favorites["/share/folder"] = "wanted";
        var result = await fixture.Reconnect().ReviewFavoriteMutationAsync("/share/folder");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.Status);
        Assert.Empty(await fixture.Repository.GetFavoriteMutationRecoveriesAsync());
        Assert.Single(fixture.Calls, call => call["method"] != "list");
    }

    [Fact]
    public async Task LostResponseIsOnlyReviewedAndCanRecoverWithoutResending()
    {
        using var fixture = new Fixture("JSON") { LoseResponse = true };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted")).Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Reconnect().AddFavoriteAsync("/share/folder", "wanted")).Status);
        fixture.Favorites["/share/folder"] = "wanted";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewFavoriteMutationAsync("/share/folder"))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "add");
    }

    [Fact]
    public async Task ExplicitRejectionCannotBeReinterpretedAsSuccess()
    {
        using var fixture = new Fixture("FORM") { Reject = true };
        var result = await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted");
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        Assert.Empty(await fixture.Repository.GetFavoriteMutationRecoveriesAsync());
        Assert.Single(fixture.Calls, call => call["method"] == "list");
    }

    [Fact]
    public async Task TruncatedCatalogNeverProvesAbsenceBeforeWriteOrAfterRemoval()
    {
        using var fixture = new Fixture("FORM") { LargeCatalog = true };
        Assert.False((await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted")).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list");
        fixture.LargeCatalog = false; fixture.Favorites["/share/folder"] = "wanted"; fixture.LargeAfterWrite = true;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.RemoveFavoriteAsync("/share/folder")).Status);
        fixture.LargeAfterWrite = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewFavoriteMutationAsync("/share/folder"))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task DuplicatePathWithDifferentNamesCannotBeUsedAsWriteEvidence()
    {
        using var fixture = new Fixture("JSON") { AmbiguousNames = true };
        fixture.Favorites["/share/folder"] = "wanted";
        var result = await fixture.Repository.RemoveFavoriteAsync("/share/folder");
        Assert.False(result.Submitted); Assert.DoesNotContain(fixture.Calls, call => call["method"] == "delete");
    }

    [Theory]
    [InlineData("/")]
    [InlineData("/share/../folder")]
    [InlineData("/share//folder")]
    [InlineData("/share/folder\n")]
    public async Task InvalidPathSendsNothing(string path)
    {
        using var fixture = new Fixture("FORM");
        Assert.False((await fixture.Repository.AddFavoriteAsync(path, "name")).Submitted);
        Assert.False((await fixture.Repository.RemoveFavoriteAsync(path)).Submitted); Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task CancellationAfterSubmissionKeepsReviewAndPreCancellationSendsNothing()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture("FORM") { OnWrite = cancellation.Cancel };
        var result = await fixture.Repository.AddFavoriteAsync("/share/folder", "wanted", cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Single(await fixture.Repository.GetFavoriteMutationRecoveriesAsync());
        var before = fixture.Calls.Count;
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await fixture.Repository.RemoveFavoriteAsync("/other", cancellation.Token)).Status);
        Assert.Equal(before, fixture.Calls.Count);
        fixture.Favorites["/share/folder"] = "wanted";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewFavoriteMutationAsync("/share/folder"))!.Status);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task TypedTransportCannotSendMountCommandsOrInjectedEnvelopeFields(bool injection)
    {
        using var fixture = new Fixture("FORM");
        var request = injection ? new FileLocationMutationRequest(FileLocationMutationKind.AddFavorite, "add",
            new Dictionary<string, string> { ["path"] = "/share/folder", ["name"] = "wanted", ["_sid"] = "override" }) :
            new(FileLocationMutationKind.CreateRemoteMount, "create", new Dictionary<string, string> { ["path"] = "/share/folder" });
        var result = await fixture.Api.SendFileLocationMutationAsync(fixture.Profile, fixture.Session, fixture.Capability, request);
        Assert.Equal(FileLocationMutationTransportStatus.Unsupported, result.Status); Assert.Empty(fixture.Calls);
    }

    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        public DsmSession Session => new(Profile.Id, "synthetic-sid", "synthetic-token", null);
        public ApiCapability Capability { get; }
        public IFileLocationsRepository Repository { get; }
        public DsmApiClient Api { get; }
        private readonly HttpClient _http;
        public Dictionary<string, string> Favorites { get; } = new(StringComparer.Ordinal);
        public List<Dictionary<string, string>> Calls { get; } = [];
        public bool WrongName { get; init; }
        public bool LoseResponse { get; init; }
        public bool Reject { get; init; }
        public bool AmbiguousNames { get; init; }
        public bool LargeCatalog { get; set; }
        public bool LargeAfterWrite { get; set; }
        public Action? OnWrite { get; init; }
        public TaskCompletionSource? WriteStarted { get; init; }
        public Task? WriteGate { get; init; }
        public Fixture(string format)
        { Capability = new("SYNO.FileStation.Favorite", "entry.cgi", 1, 3, format); _http = new(new Handler(this)); Api = new(_http); Repository = Reconnect(); }
        public IFileLocationsRepository Reconnect(bool differentProfile = false, bool wrongSession = false)
        {
            var profile = differentProfile ? new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user") : Profile;
            var session = new DsmSession(wrongSession ? Guid.NewGuid() : profile.Id, "synthetic-sid", "synthetic-token", null);
            return new DsmRepository(profile, session, Api, new Dictionary<string, ApiCapability>
                { [Capability.Name] = Capability, ["SYNO.FileStation.Mount"] = new("SYNO.FileStation.Mount", "entry.cgi", 1, 1, "FORM") });
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                Assert.True(WindowsCertificateTrustHandler.TryGetConnectionContext(request, out var id, out _)); Assert.Equal(owner.Profile.Id, id);
                Assert.Contains("id=synthetic-sid", string.Join(";", request.Headers.GetValues("Cookie")));
                var text = await request.Content!.ReadAsStringAsync(token);
                var form = text.Split('&').Select(pair => pair.Split('=', 2)).ToDictionary(pair => WebUtility.UrlDecode(pair[0]), pair => WebUtility.UrlDecode(pair[1]));
                owner.Calls.Add(form); Assert.Equal("SYNO.FileStation.Favorite", form["api"]); Assert.Equal("2", form["version"]);
                var data = new JsonObject();
                if (form["method"] == "list")
                {
                    var offset = int.Parse(form["offset"]); var limit = int.Parse(form["limit"]);
                    var large = owner.LargeCatalog || owner.LargeAfterWrite && owner.Calls.Any(call => call["method"] != "list");
                    var pairs = large ? Enumerable.Range(offset, Math.Min(limit, 5001 - offset)).Select(index => new KeyValuePair<string, string>($"/share/f{index}", $"f{index}")) : owner.Favorites.Skip(offset).Take(limit);
                    var rows = new JsonArray(pairs.Select(pair => (JsonNode?)new JsonObject { ["path"] = pair.Key, ["name"] = pair.Value }).ToArray());
                    if (owner.AmbiguousNames && offset == 0) rows.Add(new JsonObject { ["path"] = "/share/folder", ["name"] = "other" });
                    data["favorites"] = rows; data["offset"] = offset; data["total"] = large ? 5001 : owner.Favorites.Count + (owner.AmbiguousNames ? 1 : 0);
                }
                else
                {
                    owner.WriteStarted?.TrySetResult(); if (owner.WriteGate is { } gate) await gate.WaitAsync(token);
                    owner.OnWrite?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.Reject) return Reply("{\"success\":false,\"error\":{\"code\":105}}");
                    if (owner.LoseResponse) throw new HttpRequestException("synthetic");
                    string Value(string key) => owner.Capability.RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(form[key])! : form[key];
                    if (form["method"] == "add") owner.Favorites[Value("path")] = owner.WrongName ? "other" : Value("name");
                    else if (form["method"] == "delete") owner.Favorites.Remove(Value("path"));
                    else throw new InvalidOperationException("未知收藏方法");
                }
                return Reply(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
            }
            private static HttpResponseMessage Reply(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
