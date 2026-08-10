using System.IO;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDetailsRepositoryContractTests
{
    private static readonly Guid ProfileId = Guid.NewGuid();
    private static readonly NasProfile Profile = new(
        ProfileId,
        "Synthetic NAS",
        "nas.invalid",
        5001,
        "tester");
    private static readonly DsmSession Session = new(
        ProfileId,
        "synthetic-sid",
        "synthetic-token",
        "synthetic-device");

    [Fact]
    public async Task LoadDetailsUsesFixedReadVersionsAndReturnsSafeProjection()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.Package"] = Json("""
            {"packages":[{"id":"pkg-drive","name":"Drive","version":"3.0","status":"running","description":"hidden"}]}
            """);
        api.Responses["SYNO.Core.TaskScheduler"] = Json("""
            {"tasks":[{"id":"task-1","name":"Backup","enable":true,"next_trigger_time":"Tonight","script":"secret"}]}
            """);
        api.Responses["SYNO.LogCenter.History"] = Json("""
            {"logs":[{"id":"log-1","source":"System","level":"info","message":"sensitive log body","user":"admin","time":0}]}
            """);
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""
            {"connections":[{"id":"conn-1","protocol":"DSM","type":"web","source":"192.0.2.1","device_id":"secret","is_current":true,"time":0}]}
            """);
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.Equal(ProfileId, snapshot.ProfileId);
        Assert.Equal("Drive", Assert.Single(snapshot.Packages.Items).Name);
        Assert.Equal("Backup", Assert.Single(snapshot.ScheduledTasks.Items).Name);
        var log = Assert.Single(snapshot.Logs.Items);
        Assert.Equal("System", log.Source);
        Assert.DoesNotContain("sensitive", log.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("admin", log.ToString(), StringComparison.OrdinalIgnoreCase);
        var connection = Assert.Single(snapshot.Connections.Items);
        Assert.Equal("DSM", connection.Protocol);
        Assert.DoesNotContain("192.0.2.1", connection.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("secret", connection.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            new[]
            {
                "SYNO.Core.Package:2:list",
                "SYNO.Core.TaskScheduler:3:list",
                "SYNO.LogCenter.History:1:list",
                "SYNO.Core.CurrentConnection:1:list",
            },
            api.Calls.Select(call => $"{call.ApiName}:{call.Version}:{call.Method}").ToArray());
    }

    [Fact]
    public async Task FailedSectionDoesNotBlockOtherSections()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.Package"] = Json("""{"packages":[{"id":"pkg","name":"Drive","status":"running"}]}""");
        api.Errors["SYNO.Core.TaskScheduler"] = new DsmException("failed", "retry");
        api.Responses["SYNO.LogCenter.History"] = Json("""{"logs":[]}""");
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""{"connections":[]}""");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.ScheduledTasks.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Logs.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Connections.Status);
    }

    [Fact]
    public async Task SectionsAreLimitedToFirstFiftyItems()
    {
        var api = new FakeApiClient();
        var packageItems = string.Join(",", Enumerable.Range(0, 51)
            .Select(index => $$"""{"id":"pkg-{{index}}","name":"Package {{index}}","status":"running"}"""));
        api.Responses["SYNO.Core.Package"] = Json($"{{\"packages\":[{packageItems}]}}");
        api.Responses["SYNO.Core.TaskScheduler"] = Json("""{"tasks":[]}""");
        api.Responses["SYNO.LogCenter.History"] = Json("""{"logs":[]}""");
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""{"connections":[]}""");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.True(snapshot.Packages.IsTruncated);
        Assert.Equal(50, snapshot.Packages.Items.Count);
        Assert.Equal("pkg-49", snapshot.Packages.Items[^1].Id);
    }

    private static DsmRepository Repository(FakeApiClient api) =>
        new(Profile, Session, api, new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
        {
            ["SYNO.Core.Package"] = Capability("SYNO.Core.Package"),
            ["SYNO.Core.TaskScheduler"] = Capability("SYNO.Core.TaskScheduler", max: 4),
            ["SYNO.LogCenter.History"] = Capability("SYNO.LogCenter.History"),
            ["SYNO.Core.CurrentConnection"] = Capability("SYNO.Core.CurrentConnection"),
        });

    private static ApiCapability Capability(string name, int max = 2) =>
        new(name, "entry.cgi", 1, max, "FORM");

    private static JsonObject Json(string source) =>
        JsonNode.Parse(source) as JsonObject ?? throw new InvalidDataException();

    private sealed class FakeApiClient : IDsmApiClient
    {
        public Dictionary<string, JsonObject> Responses { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, Exception> Errors { get; } = new(StringComparer.Ordinal);
        public List<ReadCall> Calls { get; } = [];

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            int requiredVersion,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            Calls.Add(new ReadCall(
                capability.Name,
                requiredVersion,
                method,
                parameters ?? new Dictionary<string, string>(StringComparer.Ordinal)));
            if (Errors.TryGetValue(capability.Name, out var error))
            {
                return Task.FromException<JsonObject>(error);
            }
            return Task.FromResult(Responses[capability.Name]);
        }

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }

    private sealed record ReadCall(
        string ApiName,
        int Version,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);
}
