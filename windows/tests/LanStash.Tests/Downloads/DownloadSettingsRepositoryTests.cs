using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadSettingsRepositoryTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SavesBasicAndScheduleUsingInfoV2AndScheduleV1ThenVerifiesBoth(string format)
    {
        using var fixture = new Fixture(format);
        var original = await fixture.Repository.LoadSettingsAsync();
        var desired = original.Value with { BtDownloadLimitKb = 700, IsScheduleEnabled = true, DefaultDestination = "synthetic-folder" };
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, desired, Guid.NewGuid());
        var result = await fixture.Repository.SaveSettingsAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(desired, result.Confirmed!.Value);
        Assert.Equal(DownloadSettingsComponentState.Confirmed, result.Basic);
        Assert.Equal(DownloadSettingsComponentState.Confirmed, result.Schedule);
        await fixture.Repository.SaveSettingsAsync(request);
        var basic = Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
        var schedule = Assert.Single(fixture.Calls, call => call["method"] == "setconfig");
        Assert.Equal("2", basic["version"]); Assert.Equal("1", schedule["version"]);
        Assert.Equal(format == "JSON" ? "\"synthetic-folder\"" : "synthetic-folder", basic["default_destination"]);
        Assert.Equal(basic["http_max_download"], basic["ftp_max_download"]);
        Assert.Contains(fixture.Calls, call => call["api"] == "SYNO.FileStation.List");
    }

    [Fact]
    public async Task DeclaredWebapiRelativePathDoesNotDuplicateTheWebapiPrefix()
    {
        using var fixture = new Fixture("FORM", infoPath: "webapi/entry.cgi");
        await fixture.Repository.LoadSettingsAsync();
        Assert.All(fixture.InfoPaths, path => Assert.Equal("/webapi/entry.cgi", path));
        Assert.NotEmpty(fixture.InfoPaths);
    }

    [Fact]
    public async Task InfoV2MinimumIsSupportedAndUnrecognizedRequestFormatIsNotWritten()
    {
        using var fixture = new Fixture("FORM", infoMinVersion: 2);
        Assert.Contains(DownloadStationReadFeature.ServerSettings, fixture.Repository.Availability.SupportedFeatures);
        Assert.True((await fixture.Repository.LoadSettingsAsync()).CanEditDestination);
        using var unsupported = new Fixture("XML");
        await Assert.ThrowsAsync<DsmException>(() => unsupported.Repository.LoadSettingsAsync());
        Assert.Empty(unsupported.Calls);
    }

    [Fact]
    public async Task CancellationAfterBasicSubmissionCannotStartScheduleOrReplayBasic()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture("FORM") { AfterBasicApply = cancellation.Cancel };
        var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650, IsScheduleEnabled = true }, Guid.NewGuid());
        var result = await fixture.Repository.SaveSettingsAsync(request, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Result.Status);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "setconfig");
        result = await fixture.Repository.SaveSettingsAsync(request);
        Assert.True(result.CanContinue);
        Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
    }

    [Fact]
    public async Task AnotherAccountCannotReviewAnOldRequestWithTheSameId()
    {
        using var fixture = new Fixture("FORM") { BasicResponseLost = true };
        var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid());
        Assert.True((await fixture.Repository.SaveSettingsAsync(request)).RequiresReview);
        var count = fixture.Calls.Count;
        var result = await fixture.Recreate("different-user").SaveSettingsAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.Equal(count, fixture.Calls.Count);
    }

    [Fact]
    public async Task InfoV1DoesNotClaimDestinationSupportAndOnlyWritesOtherFields()
    {
        using var fixture = new Fixture("FORM", infoVersion: 1);
        var original = await fixture.Repository.LoadSettingsAsync();
        Assert.False(original.CanEditDestination); Assert.Null(original.Value.DefaultDestination);
        Assert.DoesNotContain(DownloadStationReadFeature.DefaultDestination, fixture.Repository.Availability.SupportedFeatures);
        var result = await fixture.Repository.SaveSettingsAsync(new(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 600 }, Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var write = Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
        Assert.Equal("1", write["version"]); Assert.False(write.ContainsKey("default_destination"));
    }

    [Fact]
    public async Task UnknownBasicWriteIsOnlyReviewedAndScheduleNeedsExplicitContinue()
    {
        using var fixture = new Fixture("JSON") { BasicResponseLost = true };
        var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650, IsScheduleEnabled = true }, Guid.NewGuid());
        var unknown = await fixture.Repository.SaveSettingsAsync(request);
        Assert.True(unknown.RequiresReview); Assert.False(unknown.CanContinue);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "setconfig");
        var review = await fixture.Recreate().SaveSettingsAsync(request);
        Assert.True(review.CanContinue); Assert.False(review.RequiresReview);
        await fixture.Repository.SaveSettingsAsync(request);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "setconfig");
        var continued = await fixture.Repository.SaveSettingsAsync(request with { ContinueRemaining = true });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, continued.Result.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
        Assert.Single(fixture.Calls, call => call["method"] == "setconfig");
    }

    [Fact]
    public async Task PendingSettingsCannotBeBypassedWithChangedDraftOrNewRequestId()
    {
        using var fixture = new Fixture("FORM") { BasicResponseLost = true, MalformedBasicAfterWrite = true };
        var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid());
        Assert.True((await fixture.Repository.SaveSettingsAsync(request)).RequiresReview);
        var changed = await fixture.Repository.SaveSettingsAsync(request with { ClientRequestId = Guid.NewGuid(), Desired = request.Desired with { BtDownloadLimitKb = 800 } });
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        Assert.True((await fixture.Repository.SaveSettingsAsync(request)).RequiresReview);
        Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
        fixture.MalformedBasicAfterWrite = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.SaveSettingsAsync(request)).Result.Status);
    }

    [Fact]
    public async Task StaleConfirmationAndReadOnlyDestinationProduceNoSettingsWrite()
    {
        using var stale = new Fixture("FORM");
        var original = await stale.Repository.LoadSettingsAsync(); stale.Config["bt_max_download"] = 900;
        var result = await stale.Repository.SaveSettingsAsync(new(stale.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.DoesNotContain(stale.Calls, IsWrite);
        using var readOnly = new Fixture("JSON") { FolderWritable = false };
        original = await readOnly.Repository.LoadSettingsAsync();
        result = await readOnly.Repository.SaveSettingsAsync(new(readOnly.Profile.Id, original, original.Value with { DefaultDestination = "synthetic-folder" }, Guid.NewGuid()));
        Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
        Assert.DoesNotContain(readOnly.Calls, IsWrite);
    }

    [Fact]
    public async Task ExplicitScheduleRejectionKeepsBasicSuccessAndNeverReplaysIt()
    {
        using var fixture = new Fixture("FORM") { RejectSchedule = true };
        var original = await fixture.Repository.LoadSettingsAsync();
        var request = new DownloadSettingsSaveRequest(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 750, IsScheduleEnabled = true }, Guid.NewGuid());
        var result = await fixture.Repository.SaveSettingsAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Result.Status);
        Assert.Equal(DownloadSettingsComponentState.Confirmed, result.Basic); Assert.Equal(DownloadSettingsComponentState.Rejected, result.Schedule);
        Assert.False(result.CanContinue); Assert.False(result.RequiresReview);
        await fixture.Repository.SaveSettingsAsync(request);
        Assert.Single(fixture.Calls, call => call["method"] == "setserverconfig");
        Assert.Single(fixture.Calls, call => call["method"] == "setconfig");
    }

    [Fact]
    public async Task MissingAdministratorFieldsAndUnequalWebFtpLimitsCannotCreateEditableSnapshot()
    {
        using var missing = new Fixture("FORM"); missing.Config.Remove("bt_max_download");
        await Assert.ThrowsAsync<DsmException>(() => missing.Repository.LoadSettingsAsync());
        using var unequal = new Fixture("JSON"); unequal.Config["ftp_max_download"] = 300;
        await Assert.ThrowsAsync<DsmException>(() => unequal.Repository.LoadSettingsAsync());
        Assert.DoesNotContain(missing.Calls, IsWrite); Assert.DoesNotContain(unequal.Calls, IsWrite);
    }

    [Fact]
    public async Task ScheduleFailureDoesNotPreventBasicChangesAndScheduleOnlyChangeDoesNotWriteBasic()
    {
        using var fixture = new Fixture("FORM") { ScheduleUnavailable = true };
        var original = await fixture.Repository.LoadSettingsAsync();
        Assert.Equal(DownloadStationSectionStatus.Failed, original.ScheduleStatus);
        Assert.Null(original.Value.IsScheduleEnabled);
        var result = await fixture.Repository.SaveSettingsAsync(new(fixture.Profile.Id, original, original.Value with { BtDownloadLimitKb = 650 }, Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "setconfig");
        using var schedule = new Fixture("FORM"); original = await schedule.Repository.LoadSettingsAsync();
        result = await schedule.Repository.SaveSettingsAsync(new(schedule.Profile.Id, original, original.Value with { IsScheduleEnabled = true }, Guid.NewGuid()));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.DoesNotContain(schedule.Calls, call => call["method"] == "setserverconfig");
    }

    private static bool IsWrite(Dictionary<string, string> call) => call["method"] is "setconfig" or "setserverconfig";
    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly Dictionary<string, ApiCapability> _capabilities;
        private readonly string _format;
        public IDownloadStationRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public List<string> InfoPaths { get; } = [];
        public bool BasicResponseLost { get; init; }
        public bool MalformedBasicAfterWrite { get; set; }
        public bool FolderWritable { get; init; } = true;
        public bool RejectSchedule { get; init; }
        public bool ScheduleUnavailable { get; init; }
        public Action? AfterBasicApply { get; init; }
        public JsonObject Config { get; } = new()
        {
            ["default_destination"] = "downloads", ["emule_enabled"] = false, ["unzip_service_enabled"] = false,
            ["bt_max_download"] = 500, ["bt_max_upload"] = 100, ["http_max_download"] = 200, ["ftp_max_download"] = 200,
            ["nzb_max_download"] = 300, ["emule_max_download"] = 0, ["emule_max_upload"] = 0,
        };
        private readonly JsonObject _schedule = new() { ["enabled"] = false, ["emule_enabled"] = false };
        public Fixture(string format, int infoVersion = 2, int infoMinVersion = 1, string infoPath = "DownloadStation/info.cgi")
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http);
            _capabilities = new()
            {
                ["SYNO.DownloadStation.Info"] = new("SYNO.DownloadStation.Info", infoPath, infoMinVersion, infoVersion, format),
                ["SYNO.DownloadStation.Schedule"] = new("SYNO.DownloadStation.Schedule", "DownloadStation/schedule.cgi", 1, 1, format),
                ["SYNO.DownloadStation.Task"] = new("SYNO.DownloadStation.Task", "DownloadStation/task.cgi", 1, 1, "FORM"),
                ["SYNO.FileStation.List"] = new("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"),
            };
            Repository = Recreate();
        }
        public IDownloadStationRepository Recreate() => new DsmRepository(Profile, new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, _capabilities);
        public IDownloadStationRepository Recreate(string username) => new DsmRepository(Profile with { Username = username }, new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, _capabilities);
        private JsonObject Reply(Dictionary<string, string> call)
        {
            var api = call["api"]; var method = call["method"];
            if (api == "SYNO.FileStation.List") return new() { ["shares"] = new JsonArray(new JsonObject
            { ["path"] = "/synthetic-folder", ["name"] = "synthetic-folder", ["isdir"] = true,
                ["additional"] = new JsonObject { ["perm"] = new JsonObject { ["write"] = FolderWritable } } }), ["offset"] = 0, ["total"] = 1 };
            if (api == "SYNO.DownloadStation.Schedule" && ScheduleUnavailable) throw new IOException("synthetic");
            var target = api == "SYNO.DownloadStation.Info" ? Config : _schedule;
            if (method == "getconfig") return api.EndsWith("Info", StringComparison.Ordinal) && MalformedBasicAfterWrite && Calls.Any(IsWrite) ? new() : target.DeepClone().AsObject();
            foreach (var (key, value) in call.Where(pair => target.ContainsKey(pair.Key)))
                target[key] = key == "default_destination" ? JsonValue.Create(_format == "JSON" ? JsonSerializer.Deserialize<string>(value) : value) : JsonNode.Parse(value);
            if (method == "setserverconfig") AfterBasicApply?.Invoke();
            if (method == "setserverconfig" && BasicResponseLost) throw new IOException("synthetic lost response");
            return new();
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var call = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["api"] == "SYNO.DownloadStation.Info") owner.InfoPaths.Add(request.RequestUri.AbsolutePath);
                var response = owner.RejectSchedule && call["method"] == "setconfig"
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = 105 } }
                    : new JsonObject { ["success"] = true, ["data"] = owner.Reply(call) };
                token.ThrowIfCancellationRequested();
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
