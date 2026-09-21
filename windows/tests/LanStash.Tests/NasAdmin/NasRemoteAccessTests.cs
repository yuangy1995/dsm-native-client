using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasRemoteAccessTests
{
    private static async Task<NasServiceSettingsSaveRequest<NasRemoteAccessSettings>> Request(Fixture f, bool both = true)
    {
        var baseline = await f.Repository.LoadRemoteAccessSettingsAsync();
        return new(f.Profile.Id, baseline, baseline with { RelayEnabled = false, RouterConfigurationEnabled = both ? true : baseline.RouterConfigurationEnabled }, Guid.NewGuid(), true);
    }
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ReadsAndTwoWritesUseFixedVersionsAndOnlyChangedFields(string format)
    {
        using var f = new Fixture(format); var request = await Request(f);
        var result = await f.Repository.ExecuteRemoteAccessWriteAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(2, result.Counts.Succeeded);
        var writes = f.Writes.ToArray(); Assert.Equal(2, writes.Length);
        Assert.Equal("set_misc_config", writes[0]["method"]); Assert.Equal("3", writes[0]["version"]); Assert.Equal("false", writes[0]["relay_enabled"]);
        Assert.Equal("set", writes[1]["method"]); Assert.Equal("1", writes[1]["version"]); Assert.Equal("true", writes[1]["enabled"]);
        Assert.DoesNotContain("enabled", writes[0].Keys); Assert.DoesNotContain("relay_enabled", writes[1].Keys);
        Assert.Same(result, await f.Recreate().ExecuteRemoteAccessWriteAsync(request)); Assert.Equal(2, f.Writes.Count());
    }
    [Theory]
    [InlineData("\"true\"")] [InlineData("1")] [InlineData("null")] [InlineData("{}")]
    public async Task NonBooleanRelayNeverLooksDisabledAndRouterStillLoads(string value)
    {
        using var f = new Fixture(); f.Relay["relay_enabled"] = JsonNode.Parse(value);
        var settings = await f.Repository.LoadRemoteAccessSettingsAsync();
        Assert.Null(settings.RelayEnabled); Assert.False(settings.RouterConfigurationEnabled);
        Assert.Equal(NasRemoteAccessParts.Relay, settings.FailedParts); Assert.Equal(NasRemoteAccessParts.Router, settings.AvailableParts);
    }
    [Fact]
    public async Task MissingInterfaceAndReadFailureAreDifferentAndIndependent()
    {
        using var f = new Fixture(); f.ReadErrors[Fixture.RelayApi] = 105;
        var partial = await f.Repository.LoadRemoteAccessSettingsAsync(); Assert.Equal(NasRemoteAccessParts.Relay, partial.FailedParts);
        f.Capabilities.Remove(Fixture.RelayApi);
        var missing = await f.Repository.LoadRemoteAccessSettingsAsync(); Assert.Equal(NasRemoteAccessParts.None, missing.FailedParts);
        Assert.Null(missing.RelayEnabled); Assert.False(missing.RouterConfigurationEnabled);
        f.Capabilities.Clear(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadRemoteAccessSettingsAsync());
    }
    [Fact]
    public async Task AuthenticationAndCancellationDoNotLookLikePartialData()
    {
        using var f = new Fixture(); f.ReadErrors[Fixture.RelayApi] = 119;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadRemoteAccessSettingsAsync()); Assert.Single(f.Calls);
        using var cts = new CancellationTokenSource(); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadRemoteAccessSettingsAsync(cts.Token)); Assert.Single(f.Calls);
    }
    [Theory]
    [InlineData("synthetic.region.quickconnect.to")] [InlineData("synthetic.region.quickconnect.cn")]
    public async Task TrustedActiveRelayCannotBeDisabledEvenByForgedDraft(string host)
    {
        using var f = new Fixture(host: host); var baseline = await f.Repository.LoadRemoteAccessSettingsAsync(); Assert.False(baseline.CanDisableRelay);
        var forged = baseline with { CanDisableRelay = true };
        var result = await f.Repository.ExecuteRemoteAccessWriteAsync(new(f.Profile.Id, forged, forged with { RelayEnabled = false }, Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Empty(f.Writes);
        var routerOnly = new NasServiceSettingsSaveRequest<NasRemoteAccessSettings>(f.Profile.Id, baseline, baseline with { RouterConfigurationEnabled = true }, Guid.NewGuid(), true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteRemoteAccessWriteAsync(routerOnly)).Status);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task PermissionAndStaleBaselineStopBeforeAnyWrites()
    {
        using var f = new Fixture(); var request = await Request(f); f.Admin = false;
        Assert.Equal(MutationErrorCategory.Permission, (await f.Repository.ExecuteRemoteAccessWriteAsync(request)).ErrorCategory);
        f.Admin = true; f.Relay["relay_enabled"] = false;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteRemoteAccessWriteAsync(request)).ErrorCategory); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task AllNeededVersionsAreCheckedBeforeFirstWrite()
    {
        using var f = new Fixture(); var request = await Request(f); f.Capabilities[Fixture.RouterApi] = new(Fixture.RouterApi, "entry.cgi", 2, 9, "FORM");
        var result = await f.Repository.ExecuteRemoteAccessWriteAsync(request);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task FirstAmbiguousStepStopsLaterWriteAndOnlyReadbackCanResolveIt()
    {
        using var f = new Fixture { LoseReplyAt = 1, ApplyWrites = false }; var request = await Request(f);
        var unknown = await f.Repository.ExecuteRemoteAccessWriteAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, unknown.Status); Assert.Equal(1, unknown.Counts.Unknown); Assert.Equal(1, unknown.Counts.Failed);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteRemoteAccessWriteAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        f.Relay["relay_enabled"] = false;
        var reviewed = await f.Recreate().ReviewServiceSettingsAsync(NasServiceSettingsKind.RemoteAccess);
        Assert.Equal(MutationResultStatus.PartialSuccess, reviewed!.Status); Assert.Single(f.Writes); Assert.False(f.Router["enabled"]!.GetValue<bool>());
    }
    [Fact]
    public async Task ExplicitSecondRejectionProducesPartialNotFakeSuccess()
    {
        using var f = new Fixture { RejectAt = 2 }; var result = await f.Repository.ExecuteRemoteAccessWriteAsync(await Request(f));
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Failed);
        Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory); Assert.Equal(2, f.Writes.Count());
    }
    [Fact]
    public async Task ChangedReadbackAfterLostReplyConfirmsOnlySubmittedStep()
    {
        using var f = new Fixture { LoseReplyAt = 1 }; var result = await f.Repository.ExecuteRemoteAccessWriteAsync(await Request(f));
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(0, result.Counts.Unknown); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CancelAfterFirstSubmissionStopsSecondAndManualReviewNeverReplays()
    {
        using var f = new Fixture(); var request = await Request(f); using var cts = new CancellationTokenSource(); f.AfterWrite = cts.Cancel;
        var result = await f.Repository.ExecuteRemoteAccessWriteAsync(request, cts.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Status); Assert.Single(f.Writes);
        var recovered = await f.Repository.ReviewServiceSettingsAsync(NasServiceSettingsKind.RemoteAccess);
        Assert.Equal(MutationResultStatus.PartialSuccess, recovered!.Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task PartialBaselineAllowsKnownIndependentFieldButNeverFillsUnknowns()
    {
        using var f = new Fixture(); f.ReadErrors[Fixture.RelayApi] = 105;
        var baseline = await f.Repository.LoadRemoteAccessSettingsAsync();
        var valid = new NasServiceSettingsSaveRequest<NasRemoteAccessSettings>(f.Profile.Id, baseline, baseline with { RouterConfigurationEnabled = true }, Guid.NewGuid(), true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteRemoteAccessWriteAsync(valid)).Status);
        Assert.Single(f.Writes); Assert.False(NasRemoteAccessRules.IsValidChange(baseline, baseline with { RelayEnabled = true }));
    }
    [Fact]
    public async Task PublicRemoteAccessStillRequiresConfirmation()
    {
        using var f = new Fixture(); var request = await Request(f); await f.Repository.PrepareServiceSettingsAsync();
        Assert.True(((INasSettingsRepository)f.Repository).WriteAvailability.CanSaveRemoteAccess);
        Assert.False((await f.Repository.SaveRemoteAccessSettingsAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.False((await f.Repository.ExecuteRemoteAccessWriteAsync(request with { RiskConfirmed = false })).Submitted); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ReadTransportRejectsGuessedVersionAndWriteMethod()
    {
        using var f = new Fixture(); var capability = f.Capabilities[Fixture.RelayApi];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 1, "get_misc_config"));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 3, "set_misc_config"));
        Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task ConcurrentSaveAndPreCancelledSaveCannotSendDuplicateRequests()
    {
        using var f = new Fixture(); var request = await Request(f); using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteRemoteAccessWriteAsync(request, cancellation.Token)).Status);
        Assert.Empty(f.Writes);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); f.WaitWrite = () => release.Task;
        var active = f.Repository.ExecuteRemoteAccessWriteAsync(request); Assert.Single(f.Writes);
        var duplicate = await f.Recreate().ExecuteRemoteAccessWriteAsync(request with { RequestId = Guid.NewGuid() });
        Assert.Equal(MutationErrorCategory.Conflict, duplicate.ErrorCategory);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await active).Status); Assert.Equal(2, f.Writes.Count());
    }

    private sealed class Fixture : IDisposable
    {
        public const string RelayApi = "SYNO.Core.QuickConnect", RouterApi = "SYNO.Core.QuickConnect.Upnp";
        public NasProfile Profile { get; }
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public Dictionary<string,ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string,string>> Writes => Calls.Where(call => call["method"] is "set" or "set_misc_config");
        public Dictionary<string,int> ReadErrors { get; } = [];
        public JsonObject Relay { get; } = new() { ["relay_enabled"] = true };
        public JsonObject Router { get; } = new() { ["enabled"] = false };
        public bool Admin { get; set; } = true; public bool ApplyWrites { get; set; } = true;
        public int? RejectAt { get; set; } public int? LoseReplyAt { get; set; } public Action? AfterWrite { get; set; }
        public Func<Task>? WaitWrite { get; set; }
        public Fixture(string format = "FORM", string host = "nas.invalid")
        {
            Profile = new(Guid.NewGuid(), "Synthetic", host, 5001, "synthetic"); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            _http = new(new Handler(this)); Api = new(_http);
            foreach(var name in new[] { RelayApi, RouterApi, "SYNO.Core.Desktop.Initdata" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = new(Profile, Session, Api, Capabilities);
        }
        public DsmRepository Recreate() => new(Profile, Session, Api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=',2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject { ["productversion"] = "7.2.1", ["version"] = "69057", ["smallfixnumber"] = "12", ["is_admin"] = owner.Admin } });
                var relay = call["api"] == RelayApi; var data = relay ? owner.Relay : owner.Router; var field = relay ? "relay_enabled" : "enabled";
                if (call["method"] is "set" or "set_misc_config")
                {
                    if (owner.WaitWrite is not null) await owner.WaitWrite();
                    var index = owner.Writes.Count(); if (owner.RejectAt == index) return Error(105);
                    if (owner.ApplyWrites) data[field] = bool.Parse(call[field]);
                    owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseReplyAt == index) throw new HttpRequestException("合成回执丢失");
                    return Reply(new());
                }
                return owner.ReadErrors.TryGetValue(call["api"], out var error) ? Error(error) : Reply(data);
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            private static HttpResponseMessage Error(int code) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
