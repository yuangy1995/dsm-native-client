using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Locations;

public sealed class FileVfsWorkflowTests
{
    private static FileVfsConfiguration Config(string protocol = "sftp") => new(protocol, "remote.invalid", 22, "Example", "sample", Folder: "folder");
    private static FileVfsChange Create(Server server) => new(server.Repository.ProfileId, Guid.NewGuid(), FileVfsAction.Create, Configuration: Config(), Confirmed: true);

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task CreateUsesTwoSeparateFixedVersionWritesAndFullConfigurationReadback(string format)
    {
        using var server = new Server(format);
        var result = await server.Repository.ChangeVfsAsync(Create(server), "synthetic-password");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        Assert.Equal(2, server.Writes.Count);
        Assert.Equal("SYNO.FileStation.VFS.Connection", server.Writes[0].Api);
        Assert.Equal("SYNO.FileStation.VFS.Profile", server.Writes[1].Api);
        Assert.Equal("false", server.Writes[0].Values["force"]); Assert.False(server.Writes[1].Values.ContainsKey("force"));
        Assert.All(server.Writes, row => { Assert.Equal("1", row.Values["version"]); Assert.Equal("create", row.Method);
            Assert.Equal(format == "JSON" ? "\"synthetic-password\"" : "synthetic-password", row.Values["password"]);
            Assert.Equal("22", row.Values["port"]); Assert.Equal("0", row.Values["max_connection"]); });
        Assert.All(server.Requests.Where(r => r.Api == "SYNO.Core.Desktop.Initdata"), r => Assert.Equal(HttpMethod.Get, r.HttpMethod));
        Assert.DoesNotContain(server.Requests, r => r.Api == "SYNO.Core.System");
        Assert.Contains(server.Requests, r => r.Method == "get");
        Assert.Empty(await server.Repository.GetVfsOperationsAsync());
    }

    [Theory]
    [InlineData("FORM", false)]
    [InlineData("JSON", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", true)]
    public async Task UpdateSendsOnlyChangedFieldsAndPasswordKeepVersusExplicitEmpty(string format, bool replace)
    {
        using var server = new Server(format); server.Seed();
        var baseline = await server.Repository.LoadVfsDetailAsync(server.Profile!);
        var change = new FileVfsChange(server.Repository.ProfileId, Guid.NewGuid(), FileVfsAction.Update,
            baseline.Profile, baseline, baseline.Configuration with { Alias = "Renamed" }, true);
        var result = await server.Repository.ChangeVfsAsync(change, replace ? "" : null);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        Assert.Equal(2, server.Writes.Count);
        Assert.All(server.Writes, row =>
        {
            Assert.Equal("set", row.Method); Assert.False(row.Values.ContainsKey("hostname")); Assert.False(row.Values.ContainsKey("protocol"));
            Assert.False(row.Values.ContainsKey("uri_path")); Assert.False(row.Values.ContainsKey("max_connection"));
            Assert.Equal(replace, row.Values.ContainsKey("password"));
            if (replace) Assert.Equal(format == "JSON" ? "\"\"" : "", row.Values["password"]);
        });
        Assert.DoesNotContain("never-display", baseline.ToString());
        Assert.DoesNotContain("never-display", baseline.Configuration.ToString());
    }

    [Theory]
    [InlineData("ftp")]
    [InlineData("dav")]
    public async Task CleartextRequiresIndependentRiskAndHasServerFalseStillSupportsSetup(string protocol)
    {
        using var server = new Server();
        var change = Create(server) with { Configuration = Config(protocol) with { Folder = protocol == "dav" ? "/folder" : "folder" } };
        Assert.False((await server.Repository.ChangeVfsAsync(change, "")).Outcome.Submitted);
        Assert.Empty(server.Requests);
        var result = await server.Repository.ChangeVfsAsync(change with { ConfirmedCleartext = true }, "");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        Assert.False((await server.Repository.ListVfsProtocolsAsync()).Single(p => p.Id == protocol).HasConnections);
        Assert.Equal("folder", server.Writes[0].Values["uri_path"]);
    }

    [Theory]
    [InlineData("confirmation")]
    [InlineData("foreign")]
    [InlineData("invalid-host")]
    [InlineData("invalid-port")]
    [InlineData("unknown-protocol")]
    public async Task InvalidInputMakesNoRequests(string kind)
    {
        using var server = new Server(); var change = Create(server);
        change = kind switch
        {
            "confirmation" => change with { Confirmed = false }, "foreign" => change with { ProfileId = Guid.NewGuid() },
            "invalid-host" => change with { Configuration = Config() with { Hostname = "remote.invalid/path" } },
            "invalid-port" => change with { Configuration = Config() with { Port = 0 } },
            _ => change with { Configuration = Config("unlisted") },
        };
        Assert.False((await server.Repository.ChangeVfsAsync(change, "")).Outcome.Submitted); Assert.Empty(server.Requests);
    }

    [Theory]
    [InlineData("http")]
    [InlineData("access")]
    [InlineData("protocol")]
    [InlineData("changed-list")]
    [InlineData("changed-access")]
    public async Task FreshAuthorizationProtocolAndConfigurationAreRequired(string kind)
    {
        using var server = new Server { Failure = kind };
        var repository = kind == "http" ? server.NewRepository(address: "http://nas.invalid") : server.Repository;
        var result = await repository.ChangeVfsAsync(Create(server), "");
        Assert.False(result.Outcome.Submitted); Assert.Empty(server.Writes);
        if (kind == "http") { Assert.Equal(FileVfsNotice.SecureConnectionRequired, result.Notice); Assert.Empty(server.Requests); }
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("total")]
    [InlineData("string-state")]
    [InlineData("string-port")]
    public async Task MalformedInventoryFailsInsteadOfReturningEmptyOrPartial(string kind)
    {
        using var server = new Server { Failure = kind }; server.Seed();
        await Assert.ThrowsAsync<InvalidDataException>(() => server.Repository.ListVfsProfilesAsync());
    }

    [Fact]
    public async Task UnknownConnectionStateRemainsUnknownAndCannotDisconnectOrDelete()
    {
        using var server = new Server { Failure = "unknown-state" }; server.Seed();
        var profile = Assert.Single(await server.Repository.ListVfsProfilesAsync()); Assert.Equal(FileVfsState.Unknown, profile.State);
        foreach (var action in new[] { FileVfsAction.Connect, FileVfsAction.Disconnect, FileVfsAction.RemoveSavedProfile })
            Assert.False((await server.Repository.ChangeVfsAsync(new(server.Repository.ProfileId, Guid.NewGuid(), action, profile, Confirmed: true), null)).Outcome.Submitted);
        Assert.Empty(server.Writes);
    }

    [Theory]
    [InlineData("connection-lost")]
    [InlineData("profile-lost")]
    [InlineData("profile-rejected")]
    public async Task PartialOrUnknownTwoStepResultNeverReplaysOrClaimsMatchingState(string failure)
    {
        using var server = new Server { Failure = failure }; var change = Create(server);
        var result = await server.Repository.ChangeVfsAsync(change, "synthetic-password");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status);
        Assert.Equal(failure == "connection-lost" ? 1 : 2, server.Writes.Count);
        var count = server.Writes.Count; server.Failure = null;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await server.NewRepository().ReviewVfsAsync(change.RequestId))!.Outcome.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await server.Repository.ChangeVfsAsync(change, "other-secret")).Outcome.Status);
        Assert.False((await server.Repository.ChangeVfsAsync(Create(server) with { Configuration = Config() with { Alias = "Changed" } }, "")).Outcome.Submitted);
        Assert.Equal(count, server.Writes.Count);
        var pending = Assert.Single(await server.Repository.GetVfsOperationsAsync());
        Assert.DoesNotContain("synthetic-password", JsonSerializer.Serialize(pending));
        var queries = server.Requests.Count;
        Assert.Null(await server.NewRepository("another").ReviewVfsAsync(change.RequestId));
        Assert.Equal(queries, server.Requests.Count);
    }

    [Fact]
    public async Task AcceptedWritesCanRecoverReadbackWithoutResubmission()
    {
        using var server = new Server { Failure = "readback" }; var change = Create(server);
        Assert.True((await server.Repository.ChangeVfsAsync(change, "")).Outcome.RequiresRefresh);
        server.Failure = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ReviewVfsAsync(change.RequestId))!.Outcome.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(change, "")).Outcome.Status);
        Assert.Equal(2, server.Writes.Count);
    }

    [Theory]
    [InlineData(2107)]
    [InlineData(2112)]
    [InlineData(2115)]
    public async Task IdentityWarningDoesNotForceOrContinueAndExplicitFailureAllowsFreshAttempt(int code)
    {
        using var server = new Server { RejectionCode = code };
        var result = await server.Repository.ChangeVfsAsync(Create(server), "");
        Assert.Equal(FileVfsNotice.IdentityWarning, result.Notice); Assert.Single(server.Writes);
        Assert.Empty(await server.Repository.GetVfsOperationsAsync());
        server.RejectionCode = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(Create(server), "")).Outcome.Status);
        Assert.All(server.Writes.Where(w => w.Api.EndsWith("Connection", StringComparison.Ordinal)), w => Assert.Equal("false", w.Values["force"]));
    }

    [Fact]
    public async Task DisconnectThenRemoveAreIndependentAndConnectUsesOriginalOpaqueId()
    {
        using var server = new Server(); server.Seed();
        FileVfsChange Action(FileVfsAction action) => new(server.Repository.ProfileId, Guid.NewGuid(), action, server.Profile, Confirmed: true);
        Assert.False((await server.Repository.ChangeVfsAsync(Action(FileVfsAction.RemoveSavedProfile), null)).Outcome.Submitted);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(Action(FileVfsAction.Disconnect), null)).Outcome.Status);
        Assert.NotNull(server.Profile); Assert.Equal(FileVfsState.Disconnected, server.Profile.State);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(Action(FileVfsAction.Connect), null)).Outcome.Status);
        Assert.Equal("opaque-1", server.Writes[1].Values["profile_id"]);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(Action(FileVfsAction.Disconnect), null)).Outcome.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await server.Repository.ChangeVfsAsync(Action(FileVfsAction.RemoveSavedProfile), null)).Outcome.Status);
        Assert.Null(server.Profile); Assert.Equal("SYNO.FileStation.VFS.Profile", server.Writes[^1].Api);
        Assert.DoesNotContain(server.Requests, r => r.Api.Contains("Delete", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(FileVfsAction.Connect)]
    [InlineData(FileVfsAction.Disconnect)]
    [InlineData(FileVfsAction.RemoveSavedProfile)]
    public async Task SingleStepLostReceiptRemainsUnknownEvenIfResultMatches(FileVfsAction action)
    {
        using var server = new Server { Failure = "single-lost" }; server.Seed(action == FileVfsAction.Disconnect ? FileVfsState.Connected : FileVfsState.Disconnected);
        var change = new FileVfsChange(server.Repository.ProfileId, Guid.NewGuid(), action, server.Profile, Confirmed: true);
        Assert.True((await server.Repository.ChangeVfsAsync(change, null)).Outcome.RequiresRefresh);
        Assert.True((await server.Repository.ReviewVfsAsync(change.RequestId))!.Outcome.RequiresRefresh); Assert.Single(server.Writes);
    }

    [Fact]
    public async Task StaleDetailAndChangedReturnedIdentityDoNotReportSuccess()
    {
        using var server = new Server(); server.Seed();
        var baseline = await server.Repository.LoadVfsDetailAsync(server.Profile!);
        server.Configuration = server.Configuration! with { Folder = "other" };
        var change = new FileVfsChange(server.Repository.ProfileId, Guid.NewGuid(), FileVfsAction.Update, baseline.Profile,
            baseline, baseline.Configuration with { Alias = "New" }, true);
        Assert.False((await server.Repository.ChangeVfsAsync(change, null)).Outcome.Submitted); Assert.Empty(server.Writes);
        server.Configuration = baseline.Configuration; server.Failure = "changed-id";
        Assert.True((await server.Repository.ChangeVfsAsync(change, null)).Outcome.RequiresRefresh);
    }

    [Fact]
    public async Task PrecancelAndConcurrentDuplicateDoNotSubmit()
    {
        using var server = new Server { WriteRelease = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var change = Create(server);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await server.Repository.ChangeVfsAsync(change, "", new(true))).Outcome.Status);
        Assert.Empty(server.Requests);
        var saving = server.Repository.ChangeVfsAsync(change, ""); await server.WriteStarted.Task;
        Assert.False((await server.Repository.ChangeVfsAsync(change, "")).Outcome.Submitted);
        server.WriteRelease.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await saving).Outcome.Status); Assert.Equal(2, server.Writes.Count);
    }

    [Fact]
    public async Task ViewModelKeepsOriginalPendingActionAndResetsCleartextConfirmation()
    {
        using var server = new Server { Failure = "profile-lost" };
        using var model = new FileVfsViewModel(server.Repository);
        await model.LoadAsync(); model.NewConnection("ftp"); model.UpdateDraft(Config("ftp"), true);
        Assert.False(model.CanSave); model.ConfirmedCleartext = true; Assert.True(model.CanSave);
        model.UpdateDraft(Config("ftp") with { Alias = "Changed" }, true); Assert.False(model.ConfirmedCleartext);
        model.ConfirmedCleartext = true; await model.SaveAsync(""); Assert.True(model.IsPending); Assert.False(model.CanSave);
        model.NewConnection("sftp"); Assert.Equal(FileVfsAction.Create, model.Action); Assert.Equal("ftp", model.Draft!.Protocol);
        var count = server.Writes.Count; await model.LoadAsync(); Assert.Equal(count, server.Writes.Count);
    }

    [Fact]
    public async Task DisposedViewModelIgnoresLateInventory()
    {
        using var server = new Server { ListRelease = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var model = new FileVfsViewModel(server.Repository); var loading = model.LoadAsync();
        await server.ListStarted.Task; model.Dispose(); server.ListRelease.SetResult(); await loading;
        Assert.Empty(model.Profiles); Assert.False(model.CanSave);
    }

    private sealed record Request(string Api, string Method, HttpMethod HttpMethod, Dictionary<string, string> Values);
    private sealed class Server : HttpMessageHandler
    {
        private readonly Guid _id = Guid.NewGuid();
        private readonly DsmApiClient _api;
        private readonly string _format;
        public DsmRepository Repository { get; }
        public List<Request> Requests { get; } = [];
        public List<Request> Writes { get; } = [];
        public FileVfsProfile? Profile;
        public FileVfsConfiguration? Configuration;
        public string? Failure;
        public int? RejectionCode;
        private int _lists, _access;
        public TaskCompletionSource? WriteRelease, ListRelease;
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource ListStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Server(string format = "FORM") { _format = format; _api = new(new HttpClient(this)); Repository = NewRepository(); }
        public DsmRepository NewRepository(string username = "tester", string address = "nas.invalid") => new(new(_id, "Synthetic", address, 5001, username),
            new(_id, "synthetic-sid", "synthetic-token", null), _api,
            new[] { "SYNO.FileStation.VFS.Protocol", "SYNO.FileStation.VFS.Profile", "SYNO.FileStation.VFS.Connection", "SYNO.Core.Desktop.Initdata" }
                .Select(name => new ApiCapability(name, "entry.cgi", 1, 9, _format)).ToDictionary(c => c.Name));
        public void Seed(FileVfsState state = FileVfsState.Connected) { Configuration = Config(); SetProfile(state); }
        private void SetProfile(FileVfsState state)
        {
            var c = Configuration!; Profile = new(_id, "opaque-1", c.Protocol, c.Protocol.ToUpperInvariant(),
                c.Protocol + "://opaque-1", c.Hostname, c.Port, c.Alias, c.Account, c.Codepage, state);
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var body = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
            var values = body.Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => Uri.UnescapeDataString(p[0].Replace('+', ' ')), p => Uri.UnescapeDataString(p[1].Replace('+', ' ')));
            var api = values["api"]; var method = values["method"]; var row = new Request(api, method, request.Method, values); Requests.Add(row);
            string Scalar(string key) => _format == "JSON" ? JsonSerializer.Deserialize<string>(values[key])! : values[key];
            JsonObject data;
            if (Writes.Count > 0 && Failure == "readback" && method is "list" or "get") throw new HttpRequestException();
            if (api == "SYNO.Core.Desktop.Initdata")
            {
                _access++; data = new() { ["Session"] = new JsonObject { ["isLogined"] = true, ["is_admin"] = false },
                    ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = Failure != "access" && !(Failure == "changed-access" && _access > 1) } };
            }
            else if (api.EndsWith("Protocol", StringComparison.Ordinal))
            {
                var protocols = new JsonArray();
                foreach (var protocol in new[] { "sftp", "ftp", "dav", "davs" })
                    if (Failure != "protocol" || protocol != "sftp") protocols.Add(new JsonObject { ["protocol"] = protocol, ["name"] = protocol.ToUpperInvariant(), ["default_port"] = 22, ["has_server"] = false });
                data = new() { ["protocols"] = protocols };
            }
            else if (method == "list")
            {
                _lists++; ListStarted.TrySetResult(); if (ListRelease is not null) await ListRelease.Task;
                if (Failure == "changed-list" && _lists > 1) Seed();
                var profiles = new JsonArray();
                if (Profile is { } p)
                {
                    var item = new JsonObject { ["id"] = p.Id, ["protocol"] = p.Protocol, ["protocol_name"] = p.ProtocolName, ["uri"] = p.Uri,
                        ["hostname"] = p.Hostname, ["port"] = p.Port, ["alias"] = p.Alias, ["account"] = p.Account, ["codepage"] = p.Codepage,
                        ["connect_status"] = Failure == "unknown-state" ? 7 : p.State == FileVfsState.Connected ? 1 : 0 };
                    if (Failure == "string-state") item["connect_status"] = "1";
                    if (Failure == "string-port") item["port"] = "22";
                    profiles.Add(item); if (Failure == "duplicate") profiles.Add(item.DeepClone());
                }
                data = new() { ["profiles"] = profiles, ["total"] = Failure == "total" ? 99 : profiles.Count };
            }
            else if (method == "get")
            {
                var c = Configuration!;
                data = new() { ["hostname"] = c.Hostname, ["port"] = c.Port, ["alias"] = c.Alias, ["account"] = c.Account,
                    ["codepage"] = c.Codepage, ["uri_path"] = c.Folder, ["max_connection"] = c.UsesOneConnection ? 1 : 0, ["password"] = "never-display" };
            }
            else
            {
                Writes.Add(row); WriteStarted.TrySetResult(); if (WriteRelease is not null) await WriteRelease.Task;
                if (RejectionCode is { } code || Failure == "profile-rejected" && api.EndsWith("Profile", StringComparison.Ordinal))
                    return Reply(new() { ["success"] = false, ["error"] = new JsonObject { ["code"] = RejectionCode ?? 105 } });
                if (method == "delete")
                { if (api.EndsWith("Profile", StringComparison.Ordinal)) Profile = null; else Profile = Profile! with { State = FileVfsState.Disconnected }; }
                else if (values.ContainsKey("profile_id")) Profile = Profile! with { State = FileVfsState.Connected };
                else
                {
                    string Get(string key, string? old) => values.ContainsKey(key) ? Scalar(key) : old ?? "";
                    Configuration = new(Get("protocol", Configuration?.Protocol), Get("hostname", Configuration?.Hostname), values.ContainsKey("port") ? int.Parse(values["port"]) : Configuration!.Port,
                        Get("alias", Configuration?.Alias), Get("account", Configuration?.Account), Get("codepage", Configuration?.Codepage), Get("uri_path", Configuration?.Folder),
                        values.ContainsKey("max_connection") ? values["max_connection"] == "1" : Configuration?.UsesOneConnection == true);
                    SetProfile(FileVfsState.Connected);
                    if (Failure == "changed-id") Profile = Profile! with { Id = "different-id" };
                }
                if (Failure == "single-lost" || Failure == "connection-lost" && api.EndsWith("Connection", StringComparison.Ordinal) || Failure == "profile-lost" && api.EndsWith("Profile", StringComparison.Ordinal)) throw new HttpRequestException();
                data = new();
            }
            return Reply(new() { ["success"] = true, ["data"] = data });
        }
        private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(data.ToJsonString(), Encoding.UTF8, "application/json") };
    }
}
