using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosFolderSharingTests
{
    [Fact]
    public async Task ReadsOnlySharedManagementAndKeepsLinkLookupReadOnly()
    {
        using var test = new Fixture { Link = "", Shared = false }; var repo = await test.Repository();
        var value = await repo.FolderSharingAsync(test.Target); Assert.Equal(SynologyPhotoFolderAccess.Management, value.Access);
        Assert.Equal("http://example.invalid/folder", value.Url!.AbsoluteUri); Assert.Empty(test.Writes);
        Assert.Single(test.Http.Requests, call => call.Method == "get_folder_link");
        Assert.All(test.Http.Requests.Where(call => call.Api.Contains("Folder", StringComparison.Ordinal)), call => Assert.StartsWith("SYNO.FotoTeam.", call.Api));
        test.Http.TeamPermission = "entry"; await repo.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.FolderSharingAsync(test.Target)); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoFolderAccess.Management, "management")]
    [InlineData(SynologyPhotoFolderAccess.Invited, "private")]
    [InlineData(SynologyPhotoFolderAccess.View, "public-view")]
    [InlineData(SynologyPhotoFolderAccess.Download, "public-download")]
    public async Task SavesEveryAccessModeWithReceiptAndReadback(SynologyPhotoFolderAccess access, string privacy)
    {
        using var test = new Fixture(); var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), access, false));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.True(result.PermissionsSaved);
        var write = Assert.Single(test.Writes); Assert.Equal("update", write.Method); Assert.Equal(1, write.Version);
        Assert.Equal(JsonSerializer.Serialize(privacy), write.Values["privacy_type"]); Assert.Equal("2", write.Values["folder_id"]);
        Assert.False(write.Values.ContainsKey("permission")); Assert.False(write.Values.ContainsKey("password"));
    }
    [Fact]
    public async Task FlatMemberDeltaRetainsAllDesiredAndRemovedRoleWithTypedIdentities()
    {
        using var test = new Fixture(); test.Members.Add(Fixture.Member("user", 44, "download")); test.Members.Add(Fixture.Member("group", "legacy", "future-role"));
        var repo = await test.Repository(); var original = await repo.FolderSharingAsync(test.Target);
        var added = new SynologyPhotoShareGrant(new(new("group", "44"), "Synthetic new group"), "manage");
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.Invited, false)
        { Members = [original.Members![1], added] });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var delta = JsonNode.Parse(Assert.Single(test.Writes).Values["permission"])!.AsArray(); Assert.Equal(3, delta.Count);
        Assert.All(delta, entry => Assert.Null(entry!["member"]));
        Assert.Equal("delete", delta[0]!["action"]!.GetValue<string>()); Assert.Equal("download", delta[0]!["role"]!.GetValue<string>());
        Assert.Equal(44, delta[0]!["id"]!.GetValue<int>()); Assert.Equal("future-role", delta[1]!["role"]!.GetValue<string>());
        Assert.Equal("44", delta[2]!["id"]!.GetValue<string>()); Assert.Equal("manage", delta[2]!["role"]!.GetValue<string>());
        var candidateReads = test.Http.Requests.Where(call => call.Method == "list_user_group").ToArray(); Assert.NotEmpty(candidateReads);
        Assert.All(candidateReads, call => Assert.Equal("true", call.Values["team_space_sharable_list"]));
    }
    [Theory]
    [InlineData("view")][InlineData("download")][InlineData("upload")][InlineData("manage")]
    public async Task FolderMembersSupportAllRecordedRoles(string role)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var old = await repo.FolderSharingAsync(test.Target);
        var added = new SynologyPhotoShareGrant(new(new("group", "44"), "Synthetic"), role);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditFolderSharingAsync(Guid.NewGuid(), new(old, old.Access, false) { Members = [added] })).State);
    }
    [Theory]
    [InlineData(1)][InlineData(2)]
    public async Task LostReceiptCannotBeReplacedByMatchingStateOrRestart(int stage)
    {
        using var test = new Fixture { DropAt = stage }; var repo = await test.Repository();
        var edit = new SynologyPhotoFolderSharingEdit(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, true);
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), edit); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone());
        Assert.True((await cold.ReviewFolderSharingAsync(result.Id)).Pending);
        Assert.True((await cold.ContinueFolderSharingAsync(result.Id)).Pending);
        Assert.True((await cold.CancelFolderSharingAsync(result.Id)).Pending); Assert.Equal(stage, test.Writes.Count);
    }
    [Theory]
    [InlineData(1)][InlineData(2)]
    public async Task AcceptedStageReadFailureRecoversReadOnlyAndExplicitContinue(int stage)
    {
        using var test = new Fixture { FailReadAfter = stage }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, true));
        Assert.True(result.Pending); test.FailReadAfter = 0; var cold = await test.Repository(test.Store.Clone());
        var review = await cold.ReviewFolderSharingAsync(result.Id); Assert.Equal(stage, test.Writes.Count);
        if (stage == 1) { Assert.True(review.CanContinue); Assert.True(review.PermissionsSaved); Assert.False(review.NeedsInput); review = await cold.ContinueFolderSharingAsync(result.Id); }
        Assert.Equal(SynologyPhotoChangeState.Completed, review.State); Assert.Equal(2, test.Writes.Count);
        Assert.Equal(new[] { "update", "set_config" }, test.Writes.Select(value => value.Method));
    }
    [Fact]
    public async Task RejectedDefaultPreservesSavedPermissionsAndOnlyRetriesDefault()
    {
        using var test = new Fixture { RejectAt = 2 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, true));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.PermissionsSaved); Assert.True(result.CanContinue);
        test.RejectAt = 0; var cold = await test.Repository(test.Store.Clone());
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueFolderSharingAsync(result.Id)).State);
        Assert.Equal(new[] { "update", "set_config", "set_config" }, test.Writes.Select(value => value.Method));
    }
    [Fact]
    public async Task CancelAfterPermissionsLeavesPermissionsAndDoesNotSaveDefault()
    {
        using var test = new Fixture { FailReadAfter = 1 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, true));
        test.FailReadAfter = 0; await repo.ReviewFolderSharingAsync(result.Id);
        var stopped = await repo.CancelFolderSharingAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Cancelled, stopped.State);
        Assert.True(stopped.PermissionsSaved); await repo.ContinueFolderSharingAsync(result.Id); Assert.Single(test.Writes); Assert.False(test.Apply);
    }
    [Fact]
    public async Task ColdUnsentInputIsNotPersistedOrReplayed()
    {
        using var test = new Fixture { RejectAt = 1 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, false)
        { PasswordChange = SynologyPhotoPasswordChange.Replace, Password = " synthetic-secret " });
        var record = Encoding.UTF8.GetString(test.Store.Records[result.Id]);
        foreach (var secret in new[] { "synthetic-secret", "/Synthetic", "example.invalid", "Synthetic recipient" }) Assert.DoesNotContain(secret, record);
        var cold = await test.Repository(test.Store.Clone()); var restored = (await cold.FolderSharingChangesAsync()).Single();
        Assert.True(restored.NeedsInput); Assert.False(restored.CanContinue); await cold.ContinueFolderSharingAsync(result.Id); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelFolderSharingAsync(result.Id)).State);
    }
    [Theory]
    [InlineData(SynologyPhotoPasswordChange.Keep)][InlineData(SynologyPhotoPasswordChange.Clear)][InlineData(SynologyPhotoPasswordChange.Replace)]
    public async Task PasswordOperationsPreserveExactInput(SynologyPhotoPasswordChange mode)
    {
        using var test = new Fixture { Password = true }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, false)
        { PasswordChange = mode, Password = mode == SynologyPhotoPasswordChange.Replace ? " space preserved " : null });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var write = Assert.Single(test.Writes);
        if (mode == SynologyPhotoPasswordChange.Keep) Assert.False(write.Values.ContainsKey("password"));
        else Assert.Equal(JsonSerializer.Serialize(mode == SynologyPhotoPasswordChange.Clear ? "" : " space preserved "), write.Values["password"]);
    }
    [Fact]
    public async Task SecondLevelInheritanceAndHiddenDefaultCannotBeChanged()
    {
        using var test = new Fixture { Depth = 2, ParentShared = false }; var repo = await test.Repository();
        var original = await repo.FolderSharingAsync(test.Target); Assert.True(original.InheritsManagementOnly);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.View, false)));
        test.ParentShared = true; original = await repo.FolderSharingAsync(test.Target);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.View, true)));
        Assert.Empty(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.View, false))).State);
    }
    [Theory]
    [InlineData("/")][InlineData("/Synthetic/Child/Deep")][InlineData("/Synthetic/")]
    public async Task RootAndUnsupportedDepthAreRejected(string path)
    {
        using var test = new Fixture(); var repo = await test.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.FolderSharingAsync(test.Target with { Path = path })); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData("path")][InlineData("parent")][InlineData("password")][InlineData("members")][InlineData("config")][InlineData("forged")]
    public async Task FullOriginalSnapshotChangesRejectBeforeWrite(string change)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var original = await repo.FolderSharingAsync(test.Target);
        switch (change)
        {
            case "path": test.Path = "/Changed"; break;
            case "parent": test.ParentShared = false; break;
            case "password": test.Password = true; break;
            case "members": test.Members.Add(Fixture.Member("group", "44", "view")); break;
            case "config": test.Apply = true; break;
            case "forged": original = original with { HasPassword = true }; break;
        }
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.View, false)));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task LastPermissionReadAfterPersistenceBlocksRevocation()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var original = await repo.FolderSharingAsync(test.Target);
        test.Store.AfterSave = value => { if (value["FolderSharing"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) test.Http.TeamPermission = "entry"; return Task.CompletedTask; };
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.View, false));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task CandidateAndSelfChangesAreRejectedAndUnknownMembersStayUnknown()
    {
        using var test = new Fixture(); test.Members.Add(Fixture.Member("user", 101, "manage"));
        var repo = await test.Repository(); var original = await repo.FolderSharingAsync(test.Target);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, original.Access, false) { Members = [] }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, original.Access, false)
        { Members = [.. original.Members!, new(new(new("group", "absent"), "Synthetic"), "view")] }));
        test.MembersKnown = false; original = await repo.FolderSharingAsync(test.Target); Assert.Null(original.Members);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, original.Access, false) { Members = [] })); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SafetyFlagDoesNotBlockReadButBlocksAllWrites()
    {
        using var test = new Fixture(); var repo = await test.Repository(safety: false); var original = await repo.FolderSharingAsync(test.Target);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoFolderAccess.Management, false)));
        Assert.Empty(test.Writes); Assert.Empty(test.Store.Records);
    }
    [Fact]
    public async Task DuplicateCallsAndAnotherFolderCannotBypassGlobalDefaultLock()
    {
        using var test = new Fixture { DropAt = 1 }; var repo = await test.Repository(); var edit = new SynologyPhotoFolderSharingEdit(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, false);
        var id = Guid.NewGuid(); await repo.EditFolderSharingAsync(id, edit); await repo.EditFolderSharingAsync(id, edit);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderSharingAsync(Guid.NewGuid(), edit)); Assert.Single(test.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, test.Target) { Name = "Changed" }));
    }
    [Fact]
    public async Task CrossOwnerCannotReadOrContinueOriginalRecord()
    {
        using var test = new Fixture { DropAt = 1 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, false));
        var profile = test.Http.Profile with { Username = "another-synthetic" };
        var other = new SynologyPhotosRepository(profile, test.Http.Session, test.Http.Api, test.Http.Capabilities, managementStore: test.Store.Clone(), sharingSafety: new(FolderPermissions: true));
        await other.AccessAsync(); Assert.Empty(await other.FolderSharingChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinueFolderSharingAsync(result.Id)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task DefaultStageRefusesConcurrentWebModification()
    {
        using var test = new Fixture { FailReadAfter = 1 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.View, true));
        test.FailReadAfter = 0; await repo.ReviewFolderSharingAsync(result.Id); test.Password = true;
        result = await repo.ContinueFolderSharingAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.True(result.PermissionsSaved); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task AcceptedWithoutRequestedPermissionChangeRemainsPending()
    {
        using var test = new Fixture { IgnoreUpdate = true }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, true));
        Assert.True(result.Pending); Assert.False(result.PermissionsSaved); await repo.ContinueFolderSharingAsync(result.Id); Assert.Single(test.Writes); Assert.False(test.Apply);
    }
    [Fact]
    public async Task ParallelDuplicateSubmissionOnlySendsOnce()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = new SynologyPhotoFolderSharingEdit(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, false);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.TrySetResult(); await release.Task; }; var id = Guid.NewGuid();
        var first = repo.EditFolderSharingAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try { Assert.True((await repo.EditFolderSharingAsync(id, edit)).Running); Assert.Single(test.Writes); }
        finally { release.TrySetResult(); }
        Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CorruptRecoveryIsRejectedBeforeAnyWrite()
    {
        using var test = new Fixture { DropAt = 1 }; var repo = await test.Repository();
        var result = await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, false));
        var store = test.Store.Clone(); var node = JsonNode.Parse(store.Records[result.Id])!; node["FolderSharing"]!["PathAncestors"] = new JsonArray("invalid");
        store.Records[result.Id] = JsonSerializer.SerializeToUtf8Bytes(node); var cold = await test.Repository(store);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.FolderSharingChangesAsync()); Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, error.Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task OperationIdentifierCannotOverwriteFolderPermissionRecord()
    {
        using var test = new Fixture { DropAt = 1 }; var repo = await test.Repository(); var id = Guid.NewGuid();
        await repo.EditFolderSharingAsync(id, new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, false));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(id, new(SynologyPhotoFolderEditKind.Rename, test.Target) { Name = "Other" }));
        Assert.Single(test.Store.Records); Assert.NotNull(JsonNode.Parse(test.Store.Records[id])!["FolderSharing"]); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task PendingFolderPermissionsBlockSameTargetButLeaveSiblingRequestsAvailable()
    {
        using var test = new Fixture { DropAt = 1 }; var repo = await test.Repository();
        await repo.EditFolderSharingAsync(Guid.NewGuid(), new(await repo.FolderSharingAsync(test.Target), SynologyPhotoFolderAccess.Download, false));
        var sibling = new SynologyPhotoRequestSettings("Synthetic collection", "", SynologyPhotoSpace.Shared, "/Other") { FolderId = 4 };
        await repo.PreparePhotoRequestAsync(new(SynologyPhotoRequestEditKind.Create, Settings: sibling));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PreparePhotoRequestAsync(new(SynologyPhotoRequestEditKind.Create,
            Settings: sibling with { FolderId = 2, FolderPath = test.Target.Path })));
        Assert.Single(test.Writes);
    }
    private sealed class Fixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly JsonArray Members = [];
        internal bool Shared = true, ParentShared = true, Apply, Password, MembersKnown = true, IgnoreUpdate;
        internal Func<Task>? BeforeWrite;
        internal string Privacy = "private", Path = "/Synthetic", Link = "https://example.invalid/folder";
        internal int Depth = 1, DropAt, RejectAt, FailReadAfter;
        internal SynologyPhotoFolder Target => new(SynologyPhotoSpace.Shared, 2, Depth == 1 ? 1 : 3, Depth == 1 ? Path : Path + "/Child");
        internal Fixture()
        {
            Http.Capabilities["SYNO.FotoTeam.Sharing.FolderPermission"] = new("SYNO.FotoTeam.Sharing.FolderPermission", "entry.cgi", 1, 1, "JSON");
            Http.AccessResponse = api => api == "SYNO.Foto.UserInfo" ? new() { ["enabled"] = true, ["id"] = 19, ["uid"] = 101 } : null;
            Http.Respond = Respond;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, sharingSafety: new(Requests: true, FolderPermissions: safety));
            await repo.AccessAsync(); return repo;
        }
        internal static JsonObject Member(string type, object id, string role) => new()
        { ["id"] = JsonSerializer.SerializeToNode(id), ["type"] = type, ["role"] = role, ["name"] = "Synthetic recipient" };
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Api == "SYNO.FotoTeam.Sharing.FolderPermission" && call.Method is "update" or "set_config")
            {
                Writes.Add(call); if (BeforeWrite is not null) await BeforeWrite();
                if (Writes.Count == RejectAt) return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                if (call.Method == "set_config") Apply = JsonSerializer.Deserialize<bool>(call.Values["set_to_subfolder"]);
                else if (!IgnoreUpdate)
                {
                    Privacy = JsonSerializer.Deserialize<string>(call.Values["privacy_type"])!; Shared = Privacy != "management";
                    if (call.Values.TryGetValue("password", out var password)) Password = JsonSerializer.Deserialize<string>(password)!.Length > 0;
                    if (call.Values.TryGetValue("permission", out var delta)) foreach (var entry in JsonNode.Parse(delta)!.AsArray())
                    {
                        var old = Members.FirstOrDefault(value => value!["type"]!.ToJsonString() == entry!["type"]!.ToJsonString() && JsonNode.DeepEquals(value["id"], entry["id"]));
                        if (old is not null) Members.Remove(old);
                        if (entry!["action"]!.GetValue<string>() != "delete") { var value = entry.DeepClone().AsObject(); value.Remove("action"); value["name"] = "Synthetic recipient"; Members.Add(value); }
                    }
                }
                if (Writes.Count == DropAt) throw new HttpRequestException();
                return SynologyPhotosHttpFixture.Json(new());
            }
            if (FailReadAfter > 0 && Writes.Count >= FailReadAfter) throw new HttpRequestException();
            JsonObject result = call.Method switch
            {
                "get_config" => new() { ["set_to_subfolder"] = Apply },
                "get_folder_link" => new() { ["folder_link"] = "http://example.invalid/folder" },
                "list_user_group" => SynologyPhotosHttpFixture.List(Member("group", "44", "view"), Member("user", 101, "manage")),
                "get" when call.Api.EndsWith("Browse.Folder", StringComparison.Ordinal) => new() { ["folder"] = Folder(JsonSerializer.Deserialize<long>(call.Values["id"])) },
                _ => throw new InvalidOperationException(call.Api + ":" + call.Method),
            };
            return SynologyPhotosHttpFixture.Json(result);
        }
        private JsonObject Folder(long id) => id == 2 ? new()
        {
            ["id"] = 2, ["name"] = Target.Path, ["parent"] = Target.ParentId, ["shared"] = Shared, ["sort_by"] = "takentime", ["sort_direction"] = "asc",
            ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = true },
                ["sharing_info"] = new JsonObject { ["privacy_type"] = Privacy, ["sharing_link"] = Link, ["enable_password"] = Password, ["permission"] = MembersKnown ? Members.DeepClone() : null } },
        } : new() { ["id"] = id, ["name"] = id == 1 ? "/" : id == 4 ? "/Other" : Path, ["parent"] = id == 1 ? 0 : 1, ["shared"] = ParentShared };
        public void Dispose() => Http.Dispose();
    }
}
