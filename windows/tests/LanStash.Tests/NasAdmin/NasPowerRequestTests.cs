using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPowerRequestTests
{
    private static NasPowerRequest Request(Fixture f, NasPowerAction action = NasPowerAction.Reboot) => new(f.Profile.Id, action, Guid.NewGuid(), true);

    [Theory]
    [InlineData("FORM", NasPowerAction.Shutdown)] [InlineData("JSON", NasPowerAction.Shutdown)]
    [InlineData("FORM", NasPowerAction.Reboot)] [InlineData("JSON", NasPowerAction.Reboot)]
    public async Task AcceptedRequestUsesV3EmptyParametersAndNeverPollsFinalState(string format, NasPowerAction action)
    {
        using var f = new Fixture(format); var request = Request(f, action);
        var result = await f.Repository.ExecutePowerRequestAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal("power." + action.ToString().ToLowerInvariant() + ".accepted", result.DiagnosticTag);
        Assert.Equal(new[] { "get_user_service", "info", action.ToString().ToLowerInvariant() }, f.Calls.Select(call => call["method"]));
        var write = Assert.Single(f.Writes); Assert.Equal("3", write["version"]); Assert.Equal("SYNO.Core.System", write["api"]);
        Assert.Empty(write.Keys.Except(new[] { "api", "version", "method", "_sid", "SynoToken" }));
        var root = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "contracts"))) root = root.Parent;
        var fixture = JsonNode.Parse(File.ReadAllText(Path.Combine(root!.FullName, "contracts/request-fixtures/system-power", action.ToString().ToLowerInvariant(), "synthetic-nas/request.json")))!;
        Assert.Equal(fixture["api"]!["resolvedVersion"]!.ToString(), write["version"]); Assert.Empty(fixture["parameters"]!.AsArray());
        var recovery = await f.Recreate().GetPowerRecoveryAsync(); Assert.NotNull(recovery); Assert.False(recovery.HasFreshSession);
        Assert.DoesNotContain("synthetic-sid", JsonSerializer.Serialize(recovery));
        var count = f.Calls.Count; await f.Recreate().ExecutePowerRequestAsync(request); Assert.Equal(count, f.Calls.Count);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecutePowerRequestAsync(Request(f, action == NasPowerAction.Reboot ? NasPowerAction.Shutdown : NasPowerAction.Reboot))).ErrorCategory);
        Assert.Single(f.Writes);
    }

    [Fact]
    public async Task InvalidUnconfirmedMissingVersionAndClosedGateMakeNoRequests()
    {
        using var f = new Fixture(); var request = Request(f);
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { RequestId = Guid.Empty }, request with { ProfileId = Guid.NewGuid() }, request with { Action = (NasPowerAction)99 } })
            Assert.False((await f.Repository.ExecutePowerRequestAsync(invalid)).Submitted);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ExecutePowerActionAsync(request)).Status);
        f.Capabilities["SYNO.Core.System"] = new("SYNO.Core.System", "entry.cgi", 1, 2, "FORM");
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ExecutePowerRequestAsync(request)).Status); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task PreflightFailureAndUnknownAdministratorNeverSendPower()
    {
        using var f = new Fixture { InfoError = 105 };
        var result = await f.Repository.ExecutePowerRequestAsync(Request(f)); Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory);
        Assert.Empty(f.Writes);
        using var other = new Fixture { Administrator = false };
        Assert.False((await other.Repository.ExecutePowerRequestAsync(Request(other))).Submitted); Assert.Single(other.Calls); Assert.Empty(other.Writes);
    }

    [Theory]
    [InlineData(0)] [InlineData(109)] [InlineData(503)]
    public async Task LostBusyOrHttpFailureRemainsUnknownAndDoesNotReadAfterward(int failure)
    {
        using var f = new Fixture { LoseWrite = failure == 0, WriteError = failure == 109 ? 109 : null, HttpFailure = failure == 503 };
        var result = await f.Repository.ExecutePowerRequestAsync(Request(f));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.NotNull(await f.Repository.GetPowerRecoveryAsync());
        Assert.Equal(3, f.Calls.Count); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ExplicitRejectionDoesNotCreatePendingState()
    {
        using var f = new Fixture { WriteError = 105 };
        var result = await f.Repository.ExecutePowerRequestAsync(Request(f));
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status); Assert.Null(await f.Repository.GetPowerRecoveryAsync()); Assert.Equal(3, f.Calls.Count);
    }

    [Fact]
    public async Task CancellationPhasesAreDistinctWithoutWriteReplay()
    {
        using var f = new Fixture(); using var before = new CancellationTokenSource(); before.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecutePowerRequestAsync(Request(f), before.Token)).Status); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterWrite = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecutePowerRequestAsync(Request(f), after.Token)).Status);
        Assert.Equal(3, f.Calls.Count); Assert.NotNull(await f.Repository.GetPowerRecoveryAsync());
    }

    [Fact]
    public async Task OnlyFreshSessionAndDeviceConfirmationCanClearTheGuard()
    {
        using var f = new Fixture(); var request = Request(f); await f.Repository.ExecutePowerRequestAsync(request); var count = f.Calls.Count;
        Assert.False(await f.Repository.AcknowledgePowerRecoveryAsync(true)); Assert.Equal(count, f.Calls.Count);
        var fresh = f.Recreate(sid: "fresh-synthetic-sid"); Assert.True((await fresh.GetPowerRecoveryAsync())!.HasFreshSession);
        Assert.False(await fresh.AcknowledgePowerRecoveryAsync(false)); Assert.Equal(count, f.Calls.Count);
        Assert.True(await fresh.AcknowledgePowerRecoveryAsync(true)); Assert.Null(await fresh.GetPowerRecoveryAsync());
        Assert.Single(f.Writes); Assert.Equal(new[] { "get_user_service", "info" }, f.Calls.Skip(count).Select(call => call["method"]));
        count = f.Calls.Count; await fresh.ExecutePowerRequestAsync(request); Assert.Equal(count, f.Calls.Count);
        await fresh.ExecutePowerRequestAsync(Request(f, NasPowerAction.Shutdown)); Assert.Equal(2, f.Writes.Count());
    }

    [Fact]
    public async Task FailedNewSessionCheckAndOtherAccountCannotClearRecovery()
    {
        using var f = new Fixture(); await f.Repository.ExecutePowerRequestAsync(Request(f));
        Assert.Null(await f.Recreate(account: "other").GetPowerRecoveryAsync());
        f.InfoError = 105; var fresh = f.Recreate(sid: "fresh-synthetic-sid");
        await Assert.ThrowsAsync<DsmException>(() => fresh.AcknowledgePowerRecoveryAsync(true));
        Assert.NotNull(await fresh.GetPowerRecoveryAsync()); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task ShutdownAndRebootShareOneInFlightGuard()
    {
        using var f = new Fixture(); var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = async () => { entered.SetResult(); await finish.Task; };
        var active = f.Repository.ExecutePowerRequestAsync(Request(f)); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecutePowerRequestAsync(Request(f, NasPowerAction.Shutdown))).ErrorCategory);
        finish.SetResult(); await active; Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http; private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-admin");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "shutdown" or "reboot");
        public DsmRepository Repository { get; }
        public bool Administrator { get; init; } = true;
        public int? InfoError { get; set; } public int? WriteError { get; init; }
        public bool LoseWrite { get; init; } public bool HttpFailure { get; init; }
        public Action? AfterWrite { get; set; } public Func<Task>? WaitWrite { get; set; }
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http);
            foreach (var name in new[] { "SYNO.Core.System", "SYNO.Core.Desktop.Initdata" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string sid = "synthetic-sid", string? account = null) => new(Profile with { Username = account ?? Profile.Username },
            new(Profile.Id, sid, "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query); Assert.Equal(HttpMethod.Post, request.Method);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new { Session = new { productversion = "7.2.1", version = "69057", smallfixnumber = "12", is_admin = owner.Administrator } });
                if (call["method"] == "info") return owner.InfoError is int info ? Reject(info) : Reply(new { model = "Synthetic" });
                if (owner.WaitWrite is not null) await owner.WaitWrite(); owner.AfterWrite?.Invoke();
                token.ThrowIfCancellationRequested(); if (owner.LoseWrite) throw new HttpRequestException("合成响应丢失");
                if (owner.HttpFailure) return new(HttpStatusCode.ServiceUnavailable) { Content = new StringContent("{}") };
                return owner.WriteError is int error ? Reject(error) : Response("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(object data) => Response(JsonSerializer.Serialize(new { success = true, data }));
            private static HttpResponseMessage Reject(int code) => Response(JsonSerializer.Serialize(new { success = false, error = new { code } }));
            private static HttpResponseMessage Response(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
