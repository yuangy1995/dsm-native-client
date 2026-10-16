using System.Collections.Immutable;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Files.Settings;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Settings;

public sealed class FileStationSettingsTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task GeneralDeltaUsesFixedVersionTypedValuesAndOwnReceipt(string format)
    {
        using var server = new Server(format); var old = await server.Repository.LoadFileStationSettingsAsync();
        var next = old with { RecordsTransfers = true, Sharing = FileStationAccess.Selected, SharingAccounts = [new(FileSharePrincipalKind.User, 1), new(FileSharePrincipalKind.Group, 2)],
            DefaultLinkLimit = 12, Bandwidth = FileStationBandwidthPolicy.Scheduled, Schedule = new('1', 168), UsesCustomSharingPage = true };
        var change = new FileStationSettingsChange(Guid.NewGuid(), old, next, true);
        var result = await server.Repository.SaveFileStationSettingAsync(change);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status); Assert.True(next.Equivalent(await server.Repository.LoadFileStationSettingsAsync()));
        var set = Assert.Single(server.Writes); Assert.Equal("1", set["version"]); Assert.Equal("true", set["transfer_log_enable"]);
        Assert.Equal("12", set["sharing_default_limit"]); Assert.Equal("1", server.Text(set["enabled_sharing_privilege"])); Assert.Equal("2", server.Text(set["enabled_sharing_group_privilege"]));
        Assert.DoesNotContain("use_unix_default_perm", set.Keys); Assert.DoesNotContain("file_request_allow", set.Keys);
        Assert.Equal("per_user", server.Text(set["sharing_allow"]));
        await server.Repository.SaveFileStationSettingAsync(change); Assert.Single(server.Writes);
    }
    [Theory]
    [InlineData("missing-bool")][InlineData("string-bool")][InlineData("bad-scope")][InlineData("selected-mount")]
    [InlineData("numeric-limit")][InlineData("negative-limit")][InlineData("bad-schedule")][InlineData("duplicate-member")]
    [InlineData("string-id")][InlineData("unknown-policy")]
    public async Task MalformedGeneralSettingsNeverBecomeEditableDefaults(string fault)
    {
        using var server = new Server(); server.Fault = fault;
        await Assert.ThrowsAsync<InvalidDataException>(() => server.Repository.LoadFileStationSettingsAsync()); Assert.Empty(server.Writes);
    }
    [Theory]
    [InlineData("false", false)][InlineData("true", true)][InlineData("unknown", null)]
    public async Task CustomSharingSwitchKeepsUnknownState(string text, bool? expected)
    { using var s = new Server(); s.General["enable_sharing_custom_setting"] = text; Assert.Equal(expected, (await s.Repository.LoadFileStationSettingsAsync()).UsesCustomSharingPage); }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task DirectoryRequestsUseRealDomainValueAndMountAcceptsStringIds(string format)
    {
        using var s = new Server(format) { Count = 401, StringIds = true };
        var sources = await s.Repository.LoadFileStationDirectoriesAsync(); Assert.False(sources.HasUnavailableSources);
        var domain = Assert.Single(sources.Items, v => v.Kind == FileStationDirectoryKind.Domain); Assert.Equal("directory-request", domain.Value); Assert.Equal("Directory display", domain.Name);
        var accounts = await s.Repository.ListFileStationMountAccountsAsync(domain, FileSharePrincipalKind.Group); Assert.Equal(401, accounts.Count);
        var calls = s.Calls.Where(v => v.GetValueOrDefault("api") == Server.MountApi && v.ContainsKey("domain")).ToArray();
        Assert.Equal(new[] { "0", "200", "400" }, calls.Select(v => v["offset"])); Assert.All(calls, v => Assert.Equal("directory-request", s.Text(v["domain"])));
        var a = accounts[0]; var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), a, a with { Enabled = true }, true));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        var settings = JsonNode.Parse(Assert.Single(s.Writes)["settings"])!; Assert.Equal(0, settings["group_settings"]![0]!["gid"]!.GetValue<int>());
        Assert.True(settings["group_settings"]![0]!["enabled"]!.GetValue<bool>()); Assert.Null(settings["domain"]);
    }
    [Theory]
    [InlineData("duplicate")][InlineData("total-change")][InlineData("offset")][InlineData("empty-page")]
    [InlineData("bad-id")][InlineData("string-permission")]
    public async Task AllPagesAndNativePermissionFieldsAreRequired(string fault)
    {
        using var s = new Server { Count = 401, PageFault = fault };
        await Assert.ThrowsAsync<InvalidDataException>(() => s.Repository.ListFileStationMountAccountsAsync(new(FileStationDirectoryKind.Local), FileSharePrincipalKind.User));
        Assert.Empty(s.Writes);
    }
    [Fact]
    public async Task FailedDirectoryIsReportedWithoutRemovingAvailableLocalAccounts()
    {
        using var s = new Server { DirectoryFailure = true };
        var sources = await s.Repository.LoadFileStationDirectoriesAsync(); Assert.True(sources.HasUnavailableSources); Assert.Contains(sources.Items, v => v.Kind == FileStationDirectoryKind.Local);
        Assert.NotEmpty(await s.Repository.ListFileStationMountAccountsAsync(new(FileStationDirectoryKind.Local), FileSharePrincipalKind.User));
    }
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task BandwidthPreservesInheritanceAndWritesOnlyChosenAccount(string format)
    {
        using var s = new Server(format) { Count = 201 };
        foreach (var owner in Enum.GetValues<FileStationBandwidthOwner>())
        {
            var items = await s.Repository.ListFileStationBandwidthAsync(owner); Assert.Equal(201, items.Count);
            var old = items[0]; Assert.Equal(FileStationBandwidthPolicy.NotConfigured, old.Policy);
            var next = old with { Policy = FileStationBandwidthPolicy.Scheduled, UploadLimit = 10, DownloadLimit = 999999999, Schedule = new('2', 168) };
            var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, next, true)); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
            var array = JsonNode.Parse(s.Writes[^1]["bandwidths"])!.AsArray(); Assert.Single(array); Assert.Equal("scheduled", array[0]!["policy"]!.GetValue<string>());
        }
        Assert.Equal(6, s.Writes.Count);
    }
    [Theory]
    [InlineData(1)][InlineData(9)][InlineData(-1)][InlineData(1000000000)]
    public async Task BadBandwidthRatesAreRejectedBeforeAnyRequest(int rate)
    {
        using var s = new Server(); var old = (await s.Repository.ListFileStationBandwidthAsync(FileStationBandwidthOwner.LocalUser))[0]; var before = s.Calls.Count;
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { Policy = FileStationBandwidthPolicy.Enabled, UploadLimit = rate }, true));
        Assert.Equal(MutationErrorCategory.Validation, result.Outcome.ErrorCategory); Assert.Equal(before, s.Calls.Count); Assert.Empty(s.Writes);
    }
    [Fact]
    public async Task UnconfiguredPolicyCannotBeWrittenAsReset()
    {
        using var s = new Server(); var old = (await s.Repository.ListFileStationBandwidthAsync(FileStationBandwidthOwner.LocalUser))[0];
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { UploadLimit = 10 }, true));
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Outcome.Status); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("role")][InlineData("file-access")][InlineData("logged-out")][InlineData("baseline")][InlineData("second-baseline")][InlineData("second-role")][InlineData("named-admin")]
    public async Task PermissionsAndFreshCompleteBaselineProtectGeneralWrite(string change)
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationSettingsAsync(); var next = old with { RecordsTransfers = true };
        if (change == "role") s.Administrator = false;
        if (change == "file-access") s.FileAccess = false;
        if (change == "logged-out") s.LoggedIn = false;
        if (change == "baseline") s.General["enable_list_usergrp"] = false;
        if (change == "second-baseline") s.ChangeOnRead = 3;
        if (change == "second-role") s.RevokeOnAccess = 2;
        if (change == "named-admin") { s.NamedAdmin = true; next = next with { SharingAccounts = [new(FileSharePrincipalKind.User, 0)] }; }
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, next, true));
        Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status); Assert.False(result.Outcome.Submitted); Assert.Empty(s.Writes);
    }
    [Fact]
    public async Task NoConfirmationOrForeignProfileCannotQueryOrWrite()
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationSettingsAsync(); var before = s.Calls.Count;
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { RecordsTransfers = true }, false));
        Assert.Equal(MutationErrorCategory.Validation, result.Outcome.ErrorCategory);
        var foreign = old with { ProfileId = Guid.NewGuid() }; await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), foreign, foreign with { RecordsTransfers = true }, true));
        Assert.Equal(before, s.Calls.Count); Assert.Empty(s.Writes);
    }
    [Theory]
    [InlineData("lost")][InlineData("read-fails")][InlineData("not-applied")]
    public async Task UnknownSaveLocksOnlyOriginalTargetAcrossRepositoriesAndNeverReplays(string failure)
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationSettingsAsync(); s.WriteFailure = failure;
        var change = new FileStationSettingsChange(Guid.NewGuid(), old, old with { RecordsTransfers = true }, true);
        var result = await s.Repository.SaveFileStationSettingAsync(change); Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status);
        s.WriteFailure = null; var repo = s.NewRepository();
        await repo.SaveFileStationSettingAsync(change); await repo.SaveFileStationSettingAsync(change with { RequestId = Guid.NewGuid() }); Assert.Single(s.Writes);
        var mount = await repo.LoadFileStationMountAccessAsync();
        await repo.SaveFileStationSettingAsync(new(Guid.NewGuid(), mount, mount with { Access = FileStationAccess.Selected }, true)); Assert.Equal(2, s.Writes.Count);
        var review = await repo.ReviewFileStationSettingAsync(change.RequestId);
        Assert.Equal(failure == "read-fails" ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, review!.Outcome.Status);
        if (failure == "not-applied") { s.General["transfer_log_enable"] = true; Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repo.ReviewFileStationSettingAsync(change.RequestId))!.Outcome.Status); }
        Assert.Equal(2, s.Writes.Count);
    }
    [Fact]
    public async Task ExplicitApiDenialDoesNotLeaveUnknownTargetLock()
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationSettingsAsync(); s.WriteFailure = "rejected";
        var result = await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { RecordsTransfers = true }, true));
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Outcome.Status); Assert.Empty(await s.Repository.GetFileStationSettingsOperationsAsync());
    }
    [Fact]
    public async Task CancelBeforeSubmissionDoesNotWriteAndCancelAfterDispatchRemainsUnknown()
    {
        using var s = new Server(); var old = await s.Repository.LoadFileStationSettingsAsync(); var change = new FileStationSettingsChange(Guid.NewGuid(), old, old with { RecordsTransfers = true }, true);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await s.Repository.SaveFileStationSettingAsync(change, cancelled.Token)).Outcome.Status); Assert.Empty(s.Writes);
        s.WriteFailure = "cancelled"; var result = await s.Repository.SaveFileStationSettingAsync(change); Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status); Assert.Single(s.Writes);
    }
    [Fact]
    public async Task SourceLossOrUnmodifiableAccountRejectsMountWrite()
    {
        using var s = new Server(); var source = (await s.Repository.LoadFileStationDirectoriesAsync()).Items.Single(d => d.Kind == FileStationDirectoryKind.Domain);
        var old = (await s.Repository.ListFileStationMountAccountsAsync(source, FileSharePrincipalKind.User))[0]; s.DirectoryFailure = true;
        Assert.False((await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { Enabled = true }, true))).Outcome.Submitted); Assert.Empty(s.Writes);
        s.DirectoryFailure = false; s.Modifiable = false; old = (await s.Repository.ListFileStationMountAccountsAsync(source, FileSharePrincipalKind.User))[0];
        Assert.False((await s.Repository.SaveFileStationSettingAsync(new(Guid.NewGuid(), old, old with { Enabled = true }, true))).Outcome.Submitted); Assert.Empty(s.Writes);
    }
    [Fact]
    public async Task ModelRequiresExplicitSaveAndRiskConfirmationThenKeepsUnknownDraft()
    {
        using var s = new Server(); using var model = new FileStationSettingsViewModel(s.Repository); await model.LoadAsync();
        var old = Assert.IsType<FileStationGeneralSettings>(model.Draft); model.UpdateDraft(old with { Sharing = FileStationAccess.Everyone });
        Assert.True(model.NeedsExpansionConfirmation); Assert.False(model.CanSave); Assert.Empty(s.Writes);
        model.ConfirmedExpansion = true; Assert.True(model.CanSave); s.WriteFailure = "not-applied"; await model.SaveAsync();
        Assert.True(model.IsPending); Assert.False(model.CanSave); s.WriteFailure = null; await model.LoadAsync();
        Assert.Equal(FileStationAccess.Everyone, Assert.IsType<FileStationGeneralSettings>(model.Draft).Sharing); Assert.False(model.CanEdit); Assert.Single(s.Writes);
        await model.SelectSectionAsync(FileStationSettingsSection.Bandwidth); model.Select(model.Items[0]); Assert.True(model.CanEdit);
        Assert.Equal(FileStationBandwidthPolicy.NotConfigured, Assert.IsType<FileStationBandwidth>(model.Draft).Policy);
    }
    [Fact]
    public async Task ModelFiltersAccountsAndDropsLateLoadAfterClose()
    {
        using var s = new Server(); using var model = new FileStationSettingsViewModel(s.Repository); await model.SelectSectionAsync(FileStationSettingsSection.MountAccounts);
        model.SetFilter("no-match"); Assert.Empty(model.VisibleItems); model.SetFilter("account-1"); Assert.Single(model.VisibleItems);
        s.ReadBlock = new(TaskCreationOptions.RunContinuationsAsynchronously); var loading = model.LoadAsync(); model.Dispose(); s.ReadBlock.SetResult(); await loading;
        Assert.Null(model.Draft); Assert.Empty(model.Items); Assert.False(model.CanEdit);
    }
    [Fact]
    public void ScheduleUsesSundayFirstAndRejectsOutOfBoundsOrWrongModes()
    {
        var schedule = FileStationSchedule.Set(new('0', 168), 6, 23, 2, true); Assert.Equal('2', schedule[167]); Assert.Equal('0', schedule[0]);
        Assert.False(FileStationSchedule.IsValid(schedule, false)); Assert.Throws<ArgumentException>(() => FileStationSchedule.Set(schedule, 7, 0, 1, true));
        Assert.Throws<ArgumentException>(() => FileStationSchedule.Set(new('0', 168), 0, 0, 2, false));
    }

    private sealed class Server : HttpMessageHandler
    {
        public const string SettingsApi = "SYNO.FileStation.Settings", MountApi = "SYNO.FileStation.VFS.User", BandwidthApi = "SYNO.Core.BandwidthControl";
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly string _format; private readonly Guid _id = Guid.NewGuid();
        private readonly Dictionary<string, JsonObject> _bandwidth = []; private readonly Dictionary<int, bool> _mount = [];
        public readonly DsmRepository Repository; public JsonObject General = JsonNode.Parse("""
            {"transfer_log_enable":false,"use_unix_default_perm":true,"enable_list_usergrp":true,"sharing_allow":"admin","file_request_allow":"admin","rf_allow":"admin","vd_allow":"admin",
            "sharing_privilege":{"items":[]},"sharing_group_privilege":{"items":[]},"file_request_privilege":{"items":[]},"file_request_group_privilege":{"items":[]},
            "sharing_default_limit":"0","bandwidth_enable":"bandwidth_disable","schedule_plan":"","enable_sharing_custom_setting":"false"}
            """)!.AsObject();
        public List<Dictionary<string, string>> Writes = [], Calls = []; public string? Fault, PageFault, WriteFailure; public string MountAccess = "admin";
        public int Count = 3, Reads, AccessReads, ChangeOnRead, RevokeOnAccess; public bool Administrator = true, FileAccess = true, LoggedIn = true, Modifiable = true, StringIds, NamedAdmin, DirectoryFailure;
        public TaskCompletionSource? ReadBlock;
        public Server(string format = "FORM") { _format = format; _http = new(this, false); _api = new(_http); Repository = NewRepository(); }
        public DsmRepository NewRepository() => new(new(_id, "Example", "nas.invalid", null, "sample"), new(_id, "synthetic-session", "synthetic-token", null), _api,
            new[] { SettingsApi, MountApi, BandwidthApi, "SYNO.FileStation.UserGrp", "SYNO.Core.Desktop.Initdata", "SYNO.Core.Directory.LDAP", "SYNO.Core.Directory.Domain" }
                .ToDictionary(a => a, a => new ApiCapability(a, "entry.cgi", 1, 9, _format)));
        public string Text(string value) => _format == "JSON" ? JsonSerializer.Deserialize<string>(value)! : value;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var raw = request.Method == HttpMethod.Get ? request.RequestUri!.Query.TrimStart('?') : await request.Content!.ReadAsStringAsync(token);
            var fields = raw.Split('&').Select(v => v.Split('=', 2)).ToDictionary(v => WebUtility.UrlDecode(v[0]), v => WebUtility.UrlDecode(v[1])); Calls.Add(fields);
            var api = fields["api"]; var method = fields["method"]; Assert.Equal(method == "get_domain_list" ? "2" : "1", fields["version"]);
            JsonObject data = new();
            if (method == "set")
            {
                Writes.Add(fields); if (WriteFailure == "rejected") return Reply(new() { ["success"] = false, ["error"] = new JsonObject { ["code"] = 105 } });
                if (WriteFailure != "not-applied") Apply(api, fields);
                if (WriteFailure == "lost") throw new HttpRequestException("synthetic lost receipt");
                if (WriteFailure == "cancelled") throw new OperationCanceledException();
            }
            else if (api == "SYNO.Core.Desktop.Initdata")
            { AccessReads++; data = new() { ["Session"] = new JsonObject { ["is_admin"] = Administrator && (RevokeOnAccess == 0 || AccessReads < RevokeOnAccess), ["isLogined"] = LoggedIn }, ["AppPrivilege"] = new JsonObject { ["SYNO.SDS.App.FileStation3.Instance"] = FileAccess } }; }
            else if (api.StartsWith("SYNO.Core.Directory.", StringComparison.Ordinal))
            {
                if (DirectoryFailure) throw new HttpRequestException("synthetic directory failure");
                data = api.EndsWith("LDAP") ? new() { ["enable_client"] = true } : method switch { "get" => new() { ["enable_domain"] = true }, "test_dc" => new() { ["test_join_success"] = true }, _ => new() { ["domain_list"] = new JsonArray(new JsonArray("Directory display", "directory-request", "")) } };
            }
            else if (api == SettingsApi)
            {
                Reads++; if (WriteFailure == "read-fails" && Writes.Count > 0) throw new HttpRequestException("synthetic read failure");
                if (ChangeOnRead == Reads) General["enable_list_usergrp"] = false;
                data = General.DeepClone().AsObject();
                switch (Fault)
                {
                    case "missing-bool": data.Remove("transfer_log_enable"); break;
                    case "string-bool": data["transfer_log_enable"] = "false"; break;
                    case "bad-scope": data["sharing_allow"] = "other"; break;
                    case "selected-mount": data["rf_allow"] = "per_user"; break;
                    case "numeric-limit": data["sharing_default_limit"] = 0; break;
                    case "negative-limit": data["sharing_default_limit"] = "-1"; break;
                    case "bad-schedule": data["schedule_plan"] = "1"; break;
                    case "unknown-policy": data["bandwidth_enable"] = "notexist"; break;
                    case "duplicate-member": data["sharing_privilege"]!["items"] = new JsonArray(new JsonObject { ["uid"] = 1, ["enabled"] = true }, new JsonObject { ["uid"] = 1, ["enabled"] = false }); break;
                    case "string-id": data["sharing_privilege"]!["items"] = new JsonArray(new JsonObject { ["uid"] = "1", ["enabled"] = true }); break;
                }
            }
            else if (api == MountApi && Text(fields["content"]) == "user_enabled_type") data["user_enabled_type"] = MountAccess;
            else
            {
                if (ReadBlock is not null) await ReadBlock.Task;
                var offset = int.Parse(fields["offset"]); var rows = new JsonArray(); var group = method == "list_group" || fields.TryGetValue("usergroup", out var kind) && Text(kind) == "group";
                for (var i = offset; i < Math.Min(Count, offset + 200); i++)
                {
                    var id = PageFault == "duplicate" && i == 400 ? 0 : i; var name = "account-" + id;
                    if (api == BandwidthApi)
                    {
                        var owner = Text(fields["owner_type"]); var key = owner + ":" + name;
                        rows.Add(_bandwidth.TryGetValue(key, out var saved) ? saved.DeepClone() : new JsonObject { ["name"] = name, ["protocol"] = "FileStation", ["owner_type"] = owner, ["policy"] = "notexist", ["schedule_plan"] = "",
                            ["upload_limit_1"] = 0, ["download_limit_1"] = 0, ["upload_limit_2"] = 0, ["download_limit_2"] = 0 });
                    }
                    else
                    {
                        var row = new JsonObject { ["name"] = name, ["is_admin"] = NamedAdmin && id == 0, ["enabled"] = _mount.GetValueOrDefault(id), ["is_modifiable"] = Modifiable };
                        row[group ? "gid" : "uid"] = StringIds ? JsonValue.Create(id.ToString()) : JsonValue.Create(id);
                        if (PageFault == "bad-id") row[group ? "gid" : "uid"] = "-1";
                        if (PageFault == "string-permission") row["is_modifiable"] = "true"; rows.Add(row);
                    }
                }
                if (PageFault == "empty-page") rows.Clear();
                data[api == BandwidthApi ? "bandwidths" : api == MountApi ? "usergrp_settings" : group ? "groups" : "users"] = rows;
                data["offset"] = PageFault == "offset" ? offset + 1 : offset; data["total"] = PageFault == "total-change" && offset > 0 ? Count + 1 : Count;
            }
            return Reply(new() { ["success"] = true, ["data"] = data });
        }
        private void Apply(string api, Dictionary<string, string> fields)
        {
            if (api == SettingsApi)
            {
                foreach (var (key, value) in fields.Where(p => !new[] { "api", "version", "method", "_sid", "SynoToken" }.Contains(p.Key)))
                {
                    if (key.StartsWith("enabled_") || key.StartsWith("disabled_"))
                    {
                        var enabled = key.StartsWith("enabled_"); var field = key[(enabled ? 8 : 9)..]; var idKey = field.Contains("group") ? "gid" : "uid";
                        var rows = General[field]!["items"]!.AsArray();
                        foreach (var id in Text(value).Split(',').Select(int.Parse))
                        { var existing = rows.OfType<JsonObject>().FirstOrDefault(v => v[idKey]!.GetValue<int>() == id); if (existing is not null) rows.Remove(existing); rows.Add(new JsonObject { [idKey] = id, ["enabled"] = enabled }); }
                    }
                    else if (key == "sharing_default_limit") General[key] = value;
                    else if (key == "enable_sharing_custom_setting") General[key] = value;
                    else if (key is "transfer_log_enable" or "use_unix_default_perm" or "enable_list_usergrp") General[key] = bool.Parse(value);
                    else General[key] = Text(value);
                }
            }
            else if (api == MountApi)
            {
                var settings = JsonNode.Parse(fields["settings"])!.AsObject();
                if (settings["user_enabled_type"] is { } scope) MountAccess = scope.GetValue<string>();
                else foreach (var row in (settings["user_settings"] ?? settings["group_settings"])!.AsArray().OfType<JsonObject>()) _mount[(row["uid"] ?? row["gid"])!.GetValue<int>()] = row["enabled"]!.GetValue<bool>();
            }
            else if (api == BandwidthApi) foreach (var row in JsonNode.Parse(fields["bandwidths"])!.AsArray().OfType<JsonObject>()) _bandwidth[row["owner_type"]!.GetValue<string>() + ":" + row["name"]!.GetValue<string>()] = row.DeepClone().AsObject();
        }
        private static HttpResponseMessage Reply(JsonObject body) => new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString()) };
        protected override void Dispose(bool disposing) { if (disposing) _http.Dispose(); base.Dispose(disposing); }
    }
}
