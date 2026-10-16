using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosSharedMembersTests
{
    private static readonly SynologyPhotoShareIdentity Guest = new("user", "31", true);
    private static SynologyPhotoSharedMember[] Target(SynologyPhotoSharedMembers original) => original.Members.Select(x => x.Id == Guest ? x with { AutoBackup = !x.AutoBackup } : x).ToArray();
    private static async Task<SynologyPhotoMemberFolderEdit> Edit(SynologyPhotosRepository repo) => new(Guest, await repo.SharedMemberFoldersAsync(Guest),
        new(true, SynologyPhotoFolderMemberRole.Download), [new(3, SynologyPhotoFolderMemberRole.Upload)]);

    [Fact]
    public async Task ReadsTypedMembersSelfCandidatesAndCompleteTwoLevelsWithoutWrites()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var members = await repo.SharedMembersAsync(); var candidates = await repo.SharedMemberCandidatesAsync();
        Assert.Equal(3, members.Members.Count); Assert.Contains(candidates, x => x.Id == new SynologyPhotoShareIdentity("user", "19", true));
        Assert.Contains(candidates, x => x.Id == new SynologyPhotoShareIdentity("user", "31"));
        var folders = await repo.SharedMemberFoldersAsync(Guest); Assert.Equal(new long[] { 2, 4, 3 }, folders.Select(x => x.Id));
        Assert.Equal("view", folders.Single(x => x.Id == 2).DirectRole); Assert.Equal(1, folders.Single(x => x.Id == 4).PublicLevel);
        Assert.All(f.FolderReads.Where(x => x.Method == "list"), x => { Assert.Equal("\"filename\"", x.Values["sort_by"]); Assert.Equal("\"asc\"", x.Values["sort_direction"]); Assert.Equal("200", x.Values["limit"]); }); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task FullPaginationIsRequiredBeforeBatchAndParentMustStayUnchanged()
    {
        using var f = new Fixture(); f.Folders.Clear(); for (var i = 2; i <= 202; i++) f.Folders.Add(Fixture.Folder(i, 1, "view"));
        var repo = await f.Repository(); var all = await repo.SharedMemberFoldersAsync(Guest); Assert.Equal(201, all.Count);
        Assert.Contains(f.FolderReads, x => x.Method == "list" && x.Values["id"] == "1" && x.Values["offset"] == "200");
        var original = await repo.SharedMembersAsync(); var incomplete = new SynologyPhotoMemberFolderEdit(Guest, all.Take(200).ToArray(), new(true, SynologyPhotoFolderMemberRole.Manage));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), original, Target(original), [incomplete], true)); Assert.Empty(f.Writes);
        f.ChangeParent = true; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SharedMemberFoldersAsync(Guest));
    }
    [Theory]
    [InlineData("duplicate")][InlineData("permission")][InlineData("backup")][InlineData("id")][InlineData("envelope")]
    public async Task MalformedMemberDataIsAnError(string bad)
    {
        using var f = new Fixture(); var repo = await f.Repository();
        if (bad == "duplicate") f.Members.Add(f.Members[0]!.DeepClone()); if (bad == "permission") f.Members[0]!["permission"] = "";
        if (bad == "backup") f.Members[0]!["auto_backup"] = "false"; if (bad == "id") f.Members[0]!["id"] = 0;
        if (bad == "envelope") f.BadArray = true;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SharedMembersAsync()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("parent")][InlineData("duplicate")][InlineData("privacy")][InlineData("role")][InlineData("identity")]
    public async Task MalformedFolderDataNeverBecomesAnEmptyPermission(string bad)
    {
        using var f = new Fixture(); var repo = await f.Repository();
        if (bad == "parent") f.WrongParent = true; if (bad == "duplicate") f.Folders.Add((JsonObject)f.Folders[0].DeepClone());
        if (bad == "privacy") Fixture.Sharing(f.Folders[0])["privacy_type"] = "";
        if (bad == "role") Fixture.Sharing(f.Folders[0])["permission"]![0]!["role"] = "";
        if (bad == "identity") Fixture.Sharing(f.Folders[0])["permission"]![0]!["id"] = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SharedMemberFoldersAsync(Guest)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task CombinedSaveUsesMemberDeltaThenBatchThenOverridesAndStoresNoNames()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.SharedMembersAsync(); var edit = await Edit(repo);
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), original, Target(original), [edit], true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(3, result.CompletedSteps); Assert.True(result.HasMemberChanges); Assert.NotNull(result.SharedResult);
        Assert.Equal(new[] { "update_permission", "update_all_by_member", "update_by_member" }, f.Writes.Select(x => x.Method));
        Assert.Equal("SYNO.Foto.Setting.TeamSpace", f.Writes[0].Api); Assert.All(f.Writes.Skip(1), x => Assert.Equal("SYNO.FotoTeam.Sharing.FolderBatchPermission", x.Api));
        var delta = JsonNode.Parse(f.Writes[0].Values["list"])!.AsArray(); Assert.Single(delta); Assert.Equal(31, delta[0]!["id"]!.GetValue<int>()); Assert.True(delta[0]!["auto_backup"]!.GetValue<bool>());
        var stored = Encoding.UTF8.GetString(f.Store.Records[result.Id]); foreach (var privateText in new[] { "Synthetic Guest", "Synthetic folder", "synthetic-sid", "nas.invalid", "administrators" }) Assert.DoesNotContain(privateText, stored);
        var cold = await f.Repository(f.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewSettingsChangeAsync(result.Id)).State); Assert.Equal(3, f.Writes.Count);
    }
    [Theory]
    [InlineData("admin")][InlineData("disabled")][InlineData("role")][InlineData("name")][InlineData("folder")][InlineData("otherPermission")][InlineData("candidate")][InlineData("capability")]
    public async Task ChangedSnapshotPermissionOrCapabilityStopsBeforeAnyWrite(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.SharedMembersAsync(); var edit = await Edit(repo); var target = Target(original).ToList();
        if (cause == "admin") f.IsAdmin = false; if (cause == "disabled") f.TeamEnabled = false; if (cause == "role") f.Members[0]!["permission"] = "management";
        if (cause == "name") f.Members[0]!["name"] = "Changed"; if (cause == "folder") f.Folders[0]["name"] = "/Changed";
        if (cause == "otherPermission") Fixture.Sharing(f.Folders[0])["permission"]!.AsArray().Add(new JsonObject { ["type"] = "group", ["id"] = 88, ["role"] = "manage" });
        if (cause == "candidate") target.Add(new(new(new("user", "404", true), "Unavailable"), "entry", false));
        if (cause == "capability") { f.Http.Capabilities.Remove("SYNO.FotoTeam.Sharing.FolderBatchPermission"); repo = await f.Repository(); }
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), original, target, [edit], true)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("protected")][InlineData("unknown")][InlineData("managementBackup")][InlineData("duplicate")][InlineData("managementFolders")][InlineData("unknownFolder")]
    public async Task InvalidDraftCannotOverwriteProtectedOrUnknownValues(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.SharedMembersAsync(); var target = Target(original).ToList(); var edit = await Edit(repo);
        if (cause == "protected") target.RemoveAt(1); if (cause == "unknown") target[2] = target[2] with { Role = "entry" };
        if (cause == "managementBackup") target[0] = target[0] with { Role = "management", AutoBackup = false };
        if (cause == "duplicate") target.Add(target[0]); if (cause == "managementFolders") target[0] = target[0].ChangingRole("management");
        if (cause == "unknownFolder") edit = edit with { Original = edit.Original.Select(x => x.Id == 2 ? x with { DirectRole = "future" } : x).ToArray() };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), original, target, [edit], true)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("admin")][InlineData("generation")][InlineData("cancel")][InlineData("snapshot")]
    public async Task PersistingIntentDoesNotBypassFinalValidation(string cause)
    {
        using var f = new Fixture(); using var token = new CancellationTokenSource(); var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var edit = await Edit(repo);
        f.Store.AfterSave = async raw =>
        { if (raw["Settings"]?["State"]?.GetValue<int>() != (int)SynologyPhotoChangeState.Submitting) return;
          if (cause == "admin") f.IsAdmin = false; if (cause == "generation") await repo.AccessAsync(); if (cause == "cancel") token.Cancel(); if (cause == "snapshot") f.Members[0]!["auto_backup"] = true; };
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [edit], true, token.Token);
        Assert.False(result.Pending); Assert.NotEqual(SynologyPhotoChangeState.Completed, result.State); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(1)][InlineData(2)][InlineData(3)]
    public async Task LostReceiptNeverReplaysAndOnlyAttemptedStepsCanComplete(int stop)
    {
        using var f = new Fixture { StopAt = stop }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var edit = await Edit(repo);
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [edit], true); Assert.True(result.Pending); Assert.Equal(stop, f.Writes.Count);
        var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [edit], true));
        f.Apply(f.Writes[^1]); result = await cold.ReviewSettingsChangeAsync(result.Id);
        Assert.Equal(stop == 3 ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed, result.State); Assert.Equal(stop, result.CompletedSteps); Assert.Equal(stop < 3, result.PartiallySaved); Assert.Equal(stop, f.Writes.Count);
    }
    [Theory]
    [InlineData(1, false)][InlineData(1, true)][InlineData(2, false)][InlineData(2, true)][InlineData(3, false)][InlineData(3, true)]
    public async Task StructuredRejectionStillReadsActualPartialChanges(int stop, bool apply)
    {
        using var f = new Fixture { StopAt = stop, Status = SynologyPhotoWriteStatus.Rejected, ApplyStopped = apply }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var edit = await Edit(repo);
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [edit], true);
        Assert.Equal(stop == 3 && apply ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed, result.State);
        Assert.Equal(stop - (apply ? 0 : 1), result.CompletedSteps); Assert.NotNull(result.SharedResult); Assert.Equal(stop, f.Writes.Count);
    }
    [Fact]
    public async Task PartialIndividualFailurePreservesBatchAndReportsActualChange()
    {
        using var f = new Fixture { StopAt = 3, Status = SynologyPhotoWriteStatus.Rejected }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var baseEdit = await Edit(repo);
        var edit = baseEdit with { Changes = [new(2, SynologyPhotoFolderMemberRole.Upload), new(3, SynologyPhotoFolderMemberRole.Manage)] };
        f.AfterWrite = () => { if (f.Writes.Count == 3) f.SetRole(2, "upload"); };
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [edit], true);
        Assert.True(result.PartiallySaved); Assert.Equal(2, result.CompletedSteps); Assert.True(result.MemberChangesObserved);
    }
    [Fact]
    public async Task PrivateParentRevocationClearsChildAndDeleteOmitsRole()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var folders = await repo.SharedMemberFoldersAsync(Guest);
        var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, a.Members, [new(Guest, folders, Changes: [new(2, null)])], true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var item = JsonNode.Parse(Assert.Single(f.Writes).Values["permission"])!["list"]![0]!;
        Assert.Equal("delete", item["action"]!.GetValue<string>()); Assert.Null(item["role"]); Assert.Null((await repo.SharedMemberFoldersAsync(Guest)).Single(x => x.Id == 3).DirectRole);
    }
    [Fact]
    public async Task NewEntryIsOneFinalCommandAndRemovalCarriesOriginalGrant()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var candidate = (await repo.SharedMemberCandidatesAsync()).Single(x => x.Id == new SynologyPhotoShareIdentity("user", "31"));
        var target = a.Members.Where(x => x.Id != Guest).Append(new(candidate, "entry", false)).ToArray();
        Assert.Empty(f.Writes); var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, target, [], true); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var list = JsonNode.Parse(Assert.Single(f.Writes).Values["list"])!.AsArray(); Assert.Equal(2, list.Count);
        Assert.Equal("delete", list[0]!["action"]!.GetValue<string>()); Assert.Equal("entry", list[0]!["permission"]!.GetValue<string>()); Assert.False(list[0]!["auto_backup"]!.GetValue<bool>());
        Assert.Equal("31", list[1]!["id"]!.GetValue<string>());
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task DefaultSafetyOrMissingConfirmationPreventsWrites(bool safety)
    {
        using var f = new Fixture(); var repo = await f.Repository(safety: safety); var a = await repo.SharedMembersAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [], !safety)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task DuplicateCallsAndOtherSettingsDoNotRepeatInFlightWrites()
    {
        using var f = new Fixture { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var id = Guid.NewGuid();
        var first = repo.SetSharedMembersAsync(id, a, Target(a), [], true); await f.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.SetSharedMembersAsync(id, a, Target(a), [], true)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [], true));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true));
        Assert.Single(f.Writes); f.Hold.TrySetResult(); Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State);
    }
    [Fact]
    public async Task UnknownMembersBlockSharedWritesButAllowPersonalPreparation()
    {
        using var f = new Fixture { StopAt = 1 }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync();
        Assert.True((await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [], true)).Pending);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.CreateTag, []) { Space = SynologyPhotoSpace.Shared, Text = "Synthetic tag" }));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure);
        await repo.PrepareEditAsync(new(SynologyPhotoEditKind.CreateTag, []) { Space = SynologyPhotoSpace.Personal, Text = "Synthetic tag" }); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task UnknownSharedTagPreventsMemberPermissionChange()
    {
        using var f = new Fixture { StopAt = 1 }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync();
        await repo.EditAsync(Guid.NewGuid(), new(SynologyPhotoEditKind.CreateTag, []) { Space = SynologyPhotoSpace.Shared, Text = "Synthetic tag" });
        Assert.Equal("create", Assert.Single(f.Writes).Method);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [], true));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("count")][InlineData("receipt")][InlineData("folder")][InlineData("identity")][InlineData("name")]
    public async Task CorruptRecoveryCannotUnlockUnknownWrite(string bad)
    {
        using var f = new Fixture { StopAt = 1 }; var repo = await f.Repository(); var a = await repo.SharedMembersAsync(); var result = await repo.SetSharedMembersAsync(Guid.NewGuid(), a, Target(a), [await Edit(repo)], true);
        var store = f.Store.Clone(); var raw = JsonNode.Parse(store.Records[result.Id])!; var record = raw["Settings"]!;
        if (bad == "count") record["CompletedSteps"] = 99; if (bad == "receipt") record["Members"]!["Facts"]![0] = 999;
        if (bad == "folder") record["Members"]!["Plan"]!["Edits"]![0]!["Original"]![0]!["IdentityHash"] = "invalid";
        if (bad == "identity") record["Members"]!["Plan"]!["Before"]![0]!["Id"]!["Value"] = "0";
        if (bad == "name") record["Members"]!["Plan"]!["Edits"]![0]!["Original"]![0]!["Name"] = "Unexpected persisted name";
        store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(store);
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SettingsChangesAsync())).Failure); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(true, -1, 0, 0)][InlineData(true, 3, 1, 3)][InlineData(true, 0, 2, 2)]
    [InlineData(false, 3, 0, -1)][InlineData(false, 3, 2, 1)][InlineData(false, 0, 2, 0)][InlineData(false, -1, 0, -1)]
    public void BatchFollowsPermissionHierarchy(bool grant, int before, int level, int after)
    {
        var batch = new SynologyPhotoMemberFolderBatch(grant, (SynologyPhotoFolderMemberRole)level);
        Assert.Equal(after, SynologyPhotoMemberFolder.Level(batch.Applying(before < 0 ? null : SynologyPhotoMemberFolder.RoleText((SynologyPhotoFolderMemberRole)before))));
    }
    [Fact]
    public async Task RepeatedBatchComposesDraftAndProtectedRoleRulesRemainStable()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var members = await repo.SharedMembersAsync(); var guest = members.Members[0];
        Assert.True(guest.ChangingRole("management").AutoBackup); Assert.True(guest.ChangingRole("management").ChangingRole("entry").AutoBackup);
        Assert.Equal(members.Members[1], members.Members[1].ChangingRole("entry"));
        var edit = new SynologyPhotoMemberFolderEdit(Guest, await repo.SharedMemberFoldersAsync(Guest));
        edit = edit.Applying(new(true, SynologyPhotoFolderMemberRole.Manage)).Applying(new(false, SynologyPhotoFolderMemberRole.Upload));
        Assert.All(edit.Original, x => Assert.Equal("download", edit.Expected(x))); Assert.True(edit.CanSave); Assert.Empty(f.Writes);
    }

    [Theory]
    [InlineData("[]", true)][InlineData("{}", false)][InlineData("{\"list\":[]}", false)][InlineData("null", false)]
    public async Task ActualMemberTransportRequiresRawArray(string data, bool valid)
    {
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.EndsWith("/entry.cgi/SYNO.Foto.Setting.TeamSpace", request.RequestUri!.AbsolutePath);
            var body = await request.Content!.ReadAsStringAsync(); Assert.Contains("method=list_permission", body); Assert.Contains("version=1", body); Assert.DoesNotContain("team_space_sharable_list", body);
            return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":true,\"data\":" + data + "}", Encoding.UTF8, "application/json") };
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic"); var api = new DsmApiClient(http);
        Task<JsonArray> Read() => api.CallPhotoArrayAsync(profile, new(profile.Id, "synthetic", null, null), new("SYNO.Foto.Setting.TeamSpace", "entry.cgi", 1, 1, "JSON"), 1, "list_permission");
        if (valid) Assert.Empty(await Read()); else await Assert.ThrowsAsync<SynologyPhotoException>(Read);
    }
    [Theory]
    [InlineData("SYNO.Foto.Setting.TeamSpace", "update_permission", "{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("SYNO.FotoTeam.Sharing.FolderBatchPermission", "update_all_by_member", "{\"success\":true}", SynologyPhotoWriteStatus.Accepted)]
    [InlineData("SYNO.FotoTeam.Sharing.FolderBatchPermission", "update_by_member", "{\"success\":true,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Unknown)]
    [InlineData("SYNO.FotoTeam.Sharing.FolderBatchPermission", "update_by_member", "{\"success\":false,\"error\":{\"code\":105}}", SynologyPhotoWriteStatus.Rejected)]
    public async Task ActualMemberWritesUseVersionOneAndStrictReceipts(string apiName, string method, string body, SynologyPhotoWriteStatus expected)
    {
        using var http = new HttpClient(new Handler(async request =>
        {
            Assert.EndsWith("/entry.cgi/" + apiName, request.RequestUri!.AbsolutePath); var fields = await request.Content!.ReadAsStringAsync();
            Assert.Contains("version=1", fields); Assert.Contains("method=" + method, fields);
            return new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }));
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", null, "synthetic");
        var result = await new DsmApiClient(http).WritePhotoAsync(profile, new(profile.Id, "synthetic", null, null), new(apiName, "entry.cgi", 1, 1, "JSON"), 1, method, new Dictionary<string,string>());
        Assert.Equal(expected, result.Status);
    }
    private sealed class Handler(Func<HttpRequestMessage,Task<HttpResponseMessage>> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request); }
    private sealed record Write(string Api, int Version, string Method, IReadOnlyDictionary<string,string> Values);
    private sealed class Fixture : IDsmApiClient, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new(); internal readonly List<Write> Writes = [], FolderReads = [];
        internal bool IsAdmin = true, TeamEnabled = true, BadArray, ChangeParent, WrongParent, ApplyStopped; internal int StopAt;
        internal SynologyPhotoWriteStatus Status = SynologyPhotoWriteStatus.Unknown; internal Action? AfterWrite;
        internal TaskCompletionSource? Hold; internal readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly JsonArray Members = new(Member(31, "Synthetic Guest", "entry", false), Member(5, "administrators", "management", true, "group"), Member(8, "Synthetic Unknown", "future", false, "group"));
        internal readonly List<JsonObject> Folders = [Folder(2, 1, "view"), Folder(3, 2, "view"), Folder(4, 1, null, "public-download")];
        internal Fixture()
        {
            Http.Capabilities.Add("SYNO.FotoTeam.Sharing.FolderBatchPermission", new("SYNO.FotoTeam.Sharing.FolderBatchPermission", "entry.cgi", 1, 1, "JSON"));
            Http.AccessResponse = api => api switch
            { "SYNO.Foto.UserInfo" => new() { ["enabled"] = true, ["id"] = Http.UserId, ["is_admin"] = IsAdmin },
              "SYNO.Foto.Setting.User" => new() { ["enable_home_service"] = true, ["team_space_permission"] = "management" },
              "SYNO.Foto.Setting.TeamSpace" => new() { ["enabled"] = TeamEnabled }, _ => null };
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store, settingsSafety: new(SharedMembers: safety)); await repo.AccessAsync(); return repo; }
        private static JsonObject Member(long id, string name, string role, bool backup, string type = "user") => new() { ["id"] = id, ["name"] = name, ["type"] = type, ["permission"] = role, ["auto_backup"] = backup };
        internal static JsonObject Folder(long id, long parent, string? role, string privacy = "private") => new()
        { ["id"] = id, ["parent"] = parent, ["name"] = "/Synthetic folder " + id, ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject
            { ["privacy_type"] = privacy, ["permission"] = role is null ? new JsonArray() : new JsonArray(new JsonObject { ["type"] = "user", ["id"] = 31L, ["role"] = role }) } } };
        internal static JsonObject Sharing(JsonObject folder) => folder["additional"]!["sharing_info"]!.AsObject();
        internal void SetRole(long id, string? role)
        { var folder = Folders.Single(x => x["id"]!.GetValue<long>() == id); Sharing(folder)["permission"] = role is null ? new JsonArray() : new JsonArray(new JsonObject { ["type"] = "user", ["id"] = 31L, ["role"] = role }); }
        private static bool SameId(JsonNode a, JsonNode b) => a["type"]!.ToJsonString() == b["type"]!.ToJsonString() && a["id"]!.ToJsonString() == b["id"]!.ToJsonString();
        internal void Apply(Write write)
        {
            if (write.Method == "update_permission")
            {
                foreach (var item in JsonNode.Parse(write.Values["list"])!.AsArray().Select(x => x!))
                {
                    var old = Members.FirstOrDefault(x => SameId(x!, item)); var remove = item["action"]!.GetValue<string>() == "delete";
                    if (old is not null) { if (remove) Members.Remove(old); else { old["permission"] = item["permission"]!.DeepClone(); old["auto_backup"] = item["auto_backup"]!.DeepClone(); } }
                    else if (!remove) { var added = item.DeepClone(); added["name"] = "Synthetic String"; Members.Add(added); }
                }
            }
            else
            {
                var permission = JsonNode.Parse(write.Values["permission"])!;
                if (write.Method == "update_all_by_member")
                {
                    var batch = new SynologyPhotoMemberFolderBatch(permission["action"]!.GetValue<string>() == "check_all", (SynologyPhotoFolderMemberRole)SynologyPhotoMemberFolder.Level(permission["role"]!.GetValue<string>()));
                    foreach (var folder in Folders) { var role = Sharing(folder)["permission"]!.AsArray().FirstOrDefault()?["role"]?.GetValue<string>(); SetRole(folder["id"]!.GetValue<long>(), batch.Applying(role)); }
                }
                else foreach (var item in permission["list"]!.AsArray().Select(x => x!))
                {
                    var id = item["folder_id"]!.GetValue<long>(); var role = item["role"]?.GetValue<string>(); SetRole(id, role);
                    if (role is null && Sharing(Folders.Single(x => x["id"]!.GetValue<long>() == id))["privacy_type"]!.GetValue<string>() == "private")
                        foreach (var child in Folders.Where(x => x["parent"]!.GetValue<long>() == id).ToArray()) SetRole(child["id"]!.GetValue<long>(), null);
                }
            }
        }
        public async Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int version, string method, IReadOnlyDictionary<string,string> parameters, CancellationToken cancellationToken = default)
        { var write = new Write(capability.Name, version, method, new Dictionary<string,string>(parameters)); Writes.Add(write); var stop = Writes.Count == StopAt;
          if (!stop || ApplyStopped) Apply(write); AfterWrite?.Invoke(); Started.TrySetResult(); if (Hold is { } hold) await hold.Task;
          return new(stop ? Status : SynologyPhotoWriteStatus.Accepted); }
        public Task<JsonArray> CallPhotoArrayAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, CancellationToken cancellationToken = default)
        { Assert.Equal("SYNO.Foto.Setting.TeamSpace", capability.Name); Assert.Equal("list_permission", method); Assert.Equal(1, requiredVersion);
          if (BadArray) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse); return Task.FromResult((JsonArray)Members.DeepClone()); }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default)
        {
            if (capability.Name == "SYNO.Foto.Sharing.Misc")
            { Assert.True(parameters is null || parameters.Count == 0); var candidates = Members.Select(x => (JsonObject)x!.DeepClone()).ToList(); candidates.Add(Member(19, "Synthetic Self", "entry", false)); var text = Member(31, "Synthetic String", "entry", false); text["id"] = "31"; candidates.Add(text); return Task.FromResult(SynologyPhotosHttpFixture.List(candidates.ToArray())); }
            if (capability.Name != "SYNO.FotoTeam.Browse.Folder") return Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
            Assert.Equal(2, requiredVersion); FolderReads.Add(new(capability.Name, requiredVersion, method, parameters ?? new Dictionary<string,string>()));
            if (method == "get")
            {
                if (parameters is null || parameters.Count == 0) return Task.FromResult(new JsonObject { ["folder"] = new JsonObject { ["id"] = 1L } });
                var folder = (JsonObject)Folders.Single(x => x["id"]!.GetValue<long>().ToString() == parameters["id"]).DeepClone(); if (ChangeParent) folder["name"] = "Changed";
                return Task.FromResult(new JsonObject { ["folder"] = folder });
            }
            var list = Folders.Where(x => x["parent"]!.GetValue<long>().ToString() == parameters!["id"]).Skip(int.Parse(parameters!["offset"])).Take(200).Select(x => (JsonObject)x.DeepClone()).ToArray();
            if (WrongParent && list.Length > 0) list[0]["parent"] = 999; return Task.FromResult(SynologyPhotosHttpFixture.List(list));
        }
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string,ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string,string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
