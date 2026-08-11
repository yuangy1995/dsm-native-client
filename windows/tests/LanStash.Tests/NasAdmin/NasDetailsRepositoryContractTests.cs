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
        api.Responses["SYNO.Core.System"] = Json("""
            {"model":"DS-synthetic","firmware_ver":"7.2","up_time":"25:02:03","cpu_series":"Synthetic CPU","cpu_cores":"4","cpu_clock_speed":2400,"ram_size":4096,"sys_temp":42.5,"hostname":"private-host","serial":"system-secret"}
            """);
        api.Responses["SYNO.Storage.CGI.Storage"] = Json("""
            {"storagePools":[{"id":"private-pool-id","raidType":"raid1","summary_status":"normal","size":{"used":100,"total":200},"disks":["private-device"]}],"volumes":[{"uuid":"private-volume-id","vol_path":"/private/path","fs_type":"btrfs","is_encrypted":true,"status":"normal","size":{"used":50,"total":100}}],"disks":[{"device":"private-device","serial":"drive-secret","vendor":"private-vendor","model":"private-model","size_total":400,"smart_status":"normal","temp":37,"isSsd":true,"status":"normal"}]}
            """);
        api.Responses["SYNO.Core.Upgrade.Server"] = Json("""
            {"update":{"version":" 7.2.1 ","release_note":" Reliability improvements ","download_url":"https://private.invalid/update","serial":"update-secret"},"promotion":{"version":"9.9"},"task_id":"private-task"}
            """);
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
        var system = Assert.Single(snapshot.SystemOverview.Items);
        Assert.Equal("DS-synthetic", system.Model);
        Assert.Equal(90_123, system.UptimeSeconds);
        Assert.Equal(4L * 1024 * 1024 * 1024, system.MemoryBytes);
        var storage = snapshot.StorageHealth.Items;
        Assert.Equal(3, storage.Count);
        Assert.Equal(new[] { "pool-1", "volume-1", "drive-1" }, storage.Select(item => item.Id));
        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.True(update.IsUpdateAvailable);
        Assert.Equal("7.2", update.CurrentVersion);
        Assert.Equal("7.2.1", update.LatestVersion);
        Assert.Equal("Reliability improvements", update.ReleaseNotes);
        var safeProjection = snapshot.ToString();
        Assert.DoesNotContain("private-host", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("system-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-device", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-path", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("drive-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-vendor", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-model", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private.invalid", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("private-task", safeProjection, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("update-secret", safeProjection, StringComparison.OrdinalIgnoreCase);
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
                "SYNO.Core.System:3:info",
                "SYNO.Storage.CGI.Storage:1:load_info",
                "SYNO.Core.Upgrade.Server:3:check",
                "SYNO.Core.Package:2:list",
                "SYNO.Core.TaskScheduler:3:list",
                "SYNO.LogCenter.History:1:list",
                "SYNO.Core.CurrentConnection:1:list",
            },
            api.Calls.Select(call => $"{call.ApiName}:{call.Version}:{call.Method}").ToArray());
        var updateCall = api.Calls.Single(call => call.ApiName == "SYNO.Core.Upgrade.Server");
        Assert.Equal(
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["user_reading"] = "true",
                ["need_auto_smallupdate"] = "true",
                ["need_promotion"] = "false",
            },
            updateCall.Parameters);
    }

    [Fact]
    public async Task FailedSectionDoesNotBlockOtherSections()
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.Package"] = Json("""{"packages":[{"id":"pkg","name":"Drive","status":"running"}]}""");
        api.Errors["SYNO.Core.TaskScheduler"] = new DsmException("failed", "retry");
        api.Errors["SYNO.Storage.CGI.Storage"] = new DsmException("failed", "retry");
        api.Responses["SYNO.LogCenter.History"] = Json("""{"logs":[]}""");
        api.Responses["SYNO.Core.CurrentConnection"] = Json("""{"connections":[]}""");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemOverview.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.StorageHealth.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemUpdate.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.ScheduledTasks.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Logs.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Connections.Status);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{\"version\":\"7.2\",\"release_notes\":\"Same version\"}")]
    public async Task MissingOrSameCandidateDoesNotInventAnAvailableUpdate(string updateJson)
    {
        var api = new FakeApiClient();
        api.Responses["SYNO.Core.System"] = Json("""{"firmware_ver":"7.2"}""");
        api.Responses["SYNO.Core.Upgrade.Server"] = Json($"{{\"update\":{updateJson},\"promotion\":{{\"version\":\"9.9\"}}}}");

        var snapshot = await Repository(api).LoadDetailsAsync();

        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.False(update.IsUpdateAvailable);
        Assert.Equal("7.2", update.CurrentVersion);
    }

    [Fact]
    public async Task ExplicitCandidateRemainsVisibleWhenSystemOverviewFails()
    {
        var api = new FakeApiClient();
        api.Errors["SYNO.Core.System"] = new DsmException("failed", "retry");
        api.Responses["SYNO.Core.Upgrade.Server"] = Json("""
            {"update":{"version":"7.2.2","description":" New release "}}
            """);

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.SystemOverview.Status);
        var update = Assert.Single(snapshot.SystemUpdate.Items);
        Assert.True(update.IsUpdateAvailable);
        Assert.Null(update.CurrentVersion);
        Assert.Equal("7.2.2", update.LatestVersion);
        Assert.Equal("New release", update.ReleaseNotes);
    }

    [Fact]
    public async Task UpdateCheckFailureDoesNotBlockOtherSectionsOrReportCurrent()
    {
        var api = new FakeApiClient();
        api.Errors["SYNO.Core.Upgrade.Server"] = new DsmException("failed", "retry");

        var snapshot = await Repository(api).LoadDetailsAsync();

        Assert.Equal(NasDetailsSectionStatus.Failed, snapshot.SystemUpdate.Status);
        Assert.Empty(snapshot.SystemUpdate.Items);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.SystemOverview.Status);
        Assert.Equal(NasDetailsSectionStatus.Available, snapshot.Packages.Status);
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

    [Fact]
    public async Task StorageSectionUsesOneCombinedFiftyItemLimit()
    {
        var api = new FakeApiClient();
        var disks = string.Join(",", Enumerable.Range(0, 51)
            .Select(index => $$"""{"device":"private-{{index}}","status":"normal","size_total":100}"""));
        api.Responses["SYNO.Storage.CGI.Storage"] = Json($"{{\"storagePools\":[],\"volumes\":[],\"disks\":[{disks}]}}");
        var repository = Repository(api);

        var snapshot = await repository.LoadDetailsAsync();

        Assert.True(snapshot.StorageHealth.IsTruncated);
        Assert.Equal(50, snapshot.StorageHealth.Items.Count);
        Assert.Equal("drive-50", snapshot.StorageHealth.Items[^1].Id);
        Assert.DoesNotContain("private-", snapshot.StorageHealth.ToString(), StringComparison.Ordinal);
    }

    private static DsmRepository Repository(FakeApiClient api)
    {
        api.Responses.TryAdd("SYNO.Core.System", Json("""{"model":"DS-synthetic"}"""));
        api.Responses.TryAdd("SYNO.Storage.CGI.Storage", Json("""{"storagePools":[],"volumes":[],"disks":[]}"""));
        api.Responses.TryAdd("SYNO.Core.Upgrade.Server", Json("""{"update":null}"""));
        api.Responses.TryAdd("SYNO.Core.Package", Json("""{"packages":[]}"""));
        api.Responses.TryAdd("SYNO.Core.TaskScheduler", Json("""{"tasks":[]}"""));
        api.Responses.TryAdd("SYNO.LogCenter.History", Json("""{"logs":[]}"""));
        api.Responses.TryAdd("SYNO.Core.CurrentConnection", Json("""{"connections":[]}"""));
        return new(Profile, Session, api, new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
        {
            ["SYNO.Core.System"] = Capability("SYNO.Core.System", max: 3),
            ["SYNO.Storage.CGI.Storage"] = Capability("SYNO.Storage.CGI.Storage", max: 1),
            ["SYNO.Core.Upgrade.Server"] = Capability("SYNO.Core.Upgrade.Server", max: 3),
            ["SYNO.Core.Package"] = Capability("SYNO.Core.Package"),
            ["SYNO.Core.TaskScheduler"] = Capability("SYNO.Core.TaskScheduler", max: 4),
            ["SYNO.LogCenter.History"] = Capability("SYNO.LogCenter.History"),
            ["SYNO.Core.CurrentConnection"] = Capability("SYNO.Core.CurrentConnection"),
        });
    }

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
