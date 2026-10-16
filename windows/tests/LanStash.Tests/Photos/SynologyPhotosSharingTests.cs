using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Fact]
    public async Task SharingUsesCloseConfigureOpenAndKeepsSecretsOutOfRecovery()
    {
        using var test = new SharingFixture(); var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61);
        var edit = new SynologyPhotoSharingEdit(original, SynologyPhotoLinkAccess.Download)
        {
            PasswordChange = SynologyPhotoPasswordChange.Replace, Password = "  synthetic-password 密码  ", Expiration = 1893455999,
            Members = [new(new(new("user", "44", true), "Synthetic member"), "upload"), new(new(new("group", "44"), "Synthetic group"), "view")],
        };
        var result = await repo.EditSharingAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(SynologyPhotoSharingStage.Finished, result.Stage);
        Assert.Equal(new[] { "set_shared", "update", "set_shared" }, test.Writes.Select(item => item.Method));
        Assert.Equal("false", test.Writes[0].Values["enabled"]); Assert.Equal("true", test.Writes[2].Values["enabled"]);
        var update = test.Writes[1]; Assert.Equal(JsonSerializer.Serialize(edit.Password), update.Values["password"]);
        var permissions = JsonNode.Parse(update.Values["permission"])!.AsArray();
        Assert.Equal(3, permissions.Count); Assert.Equal(JsonValueKind.Number, permissions[0]!["member"]!["id"]!.GetValueKind());
        Assert.Equal(JsonValueKind.String, permissions[1]!["member"]!["id"]!.GetValueKind()); Assert.Null(permissions[0]!["member"]!["name"]);
        Assert.All(test.Writes, item => { Assert.Equal(1, item.Version); Assert.Equal(HttpMethod.Post, item.HttpMethod); Assert.Equal("SYNO.Foto.Sharing.Passphrase", item.Api); });
        var saved = Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value);
        foreach (var secret in new[] { "synthetic-password", "synthetic-passphrase", "nas.invalid", "Synthetic member", "Synthetic group", "original-album", "synthetic-token", "synthetic-sid" }) Assert.DoesNotContain(secret, saved);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ContinueSharingChangeAsync(result.Id)).State); Assert.Equal(3, test.Writes.Count);
    }
    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task SharingLostReceiptNeverAdvancesOrReplaysEvenWhenDesiredStateAppears(int stage)
    {
        using var test = new SharingFixture { DropAt = stage }; var repo = await test.Repository();
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.Download)
        { PasswordChange = SynologyPhotoPasswordChange.Replace, Password = "synthetic-password" });
        Assert.True(result.Pending); var cold = await test.Repository(test.Store.Clone());
        Assert.True((await cold.ReviewSharingChangeAsync(result.Id)).Pending); Assert.True((await cold.ContinueSharingChangeAsync(result.Id)).Pending);
        Assert.True((await cold.CancelSharingChangeAsync(result.Id)).Pending); Assert.Equal(stage, test.Writes.Count);
        if (stage < 3) Assert.False(test.Shared);
    }
    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)]
    public async Task SharingAcceptedStageSurvivesReadFailureAndRestartWithoutAutomaticWrites(int stage)
    {
        using var test = new SharingFixture { FailReadAfter = stage }; var repo = await test.Repository();
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.Download));
        Assert.True(result.Pending); test.FailReadAfter = 0; var cold = await test.Repository(test.Store.Clone());
        var reviewed = await cold.ReviewSharingChangeAsync(result.Id); Assert.Equal(stage, test.Writes.Count);
        if (stage == 1)
        {
            Assert.Equal(SynologyPhotoSharingStage.Configure, reviewed.Stage); Assert.True(reviewed.NeedsInput); Assert.False(reviewed.CanContinue);
            await cold.ContinueSharingChangeAsync(result.Id); Assert.Single(test.Writes);
            Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelSharingChangeAsync(result.Id)).State); Assert.False(test.Shared);
        }
        else
        {
            result = await cold.ContinueSharingChangeAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(3, test.Writes.Count);
        }
    }
    [Fact]
    public async Task SharingRejectedConfigureContinuesOnlyRemainingStepsOnExplicitRequest()
    {
        using var test = new SharingFixture { RejectAt = 2 }; var repo = await test.Repository(); var edit = new SynologyPhotoSharingEdit(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.Download);
        var result = await repo.EditSharingAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.False(test.Shared);
        await repo.EditSharingAsync(result.Id, edit); Assert.Equal(2, test.Writes.Count);
        test.RejectAt = 0; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ContinueSharingChangeAsync(result.Id)).State);
        Assert.Equal(new[] { "set_shared", "update", "update", "set_shared" }, test.Writes.Select(item => item.Method));
    }
    [Fact]
    public async Task SharingRecipientsUseSystemUidAndRetainTypedUserGroupIdentities()
    {
        using var test = new SharingFixture(); test.Candidates.Add(SharingFixture.Member("user", 19, "view"));
        test.Candidates.Add(SharingFixture.Member("user", "101", "view")); test.Candidates.Add(SharingFixture.Member("user", 101, "view"));
        var repo = await test.Repository(); var members = await repo.SharingRecipientsAsync();
        Assert.Contains(members, item => item.Id == new SynologyPhotoShareIdentity("user", "19", true));
        Assert.Contains(members, item => item.Id == new SynologyPhotoShareIdentity("user", "101"));
        Assert.DoesNotContain(members, item => item.Id == new SynologyPhotoShareIdentity("user", "101", true));
        var call = test.Http.Requests.Last(); Assert.Equal("false", call.Values["team_space_sharable_list"]); Assert.Equal(1, call.Version);
    }
    [Fact]
    public async Task MissingSystemUidDoesNotBlockBrowsingOrClosingButBlocksMemberSelection()
    {
        using var test = new SharingFixture { Uid = null, Shared = true }; var repo = await test.Repository();
        var current = await repo.AlbumSharingAsync(61); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.SharingRecipientsAsync());
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditSharingAsync(Guid.NewGuid(), new(current, SynologyPhotoLinkAccess.Disabled))).State);
        Assert.Single(test.Writes);
    }
    [Fact]
    public async Task UnchangedUnknownRoleSurvivesAndMissingMembersAreNeverTreatedAsEmpty()
    {
        using var test = new SharingFixture { Shared = true }; test.Permission.Add(SharingFixture.Member("group", "external", "future-role"));
        var repo = await test.Repository(); var current = await repo.AlbumSharingAsync(61);
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(current, current.Access) { Members = current.Members, Expiration = 1893455999 });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.False(test.Writes[1].Values.ContainsKey("permission"));
        Assert.Equal("future-role", test.Permission.Single()!["role"]!.GetValue<string>());
        test.Permission.Add(SharingFixture.Member("group", "external", "view")); current = await repo.AlbumSharingAsync(61); Assert.Null(current.Members);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(current, current.Access) { Members = [] }));
    }
    [Fact]
    public async Task DisabledSharingCanSaveSettingsWithoutReopeningAndClearPasswordIsExplicitEmpty()
    {
        using var test = new SharingFixture { Shared = true, Password = true }; var repo = await test.Repository(safety: false);
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.Disabled)
        { PasswordChange = SynologyPhotoPasswordChange.Clear, Expiration = 0 });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(2, test.Writes.Count); Assert.Equal("\"\"", test.Writes[1].Values["password"]); Assert.False(test.Shared);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task UneditedMissingOrFractionalExpirationAndPasswordAreNotDefaulted(bool missing)
    {
        using var test = new SharingFixture { Expiration = missing ? null : JsonValue.Create(1.5m), Password = null };
        var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61); Assert.Null(original.Expiration); Assert.Null(original.HasPassword);
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.View));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        Assert.False(test.Writes[1].Values.ContainsKey("expiration")); Assert.False(test.Writes[1].Values.ContainsKey("password"));
    }
    [Fact]
    public async Task SharingSafetyBlocksExpansionButAllowsNoOpAndClosing()
    {
        using var test = new SharingFixture(); var repo = await test.Repository(safety: false); var original = await repo.AlbumSharingAsync(61);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.Disabled))).State); Assert.Empty(test.Writes);
        Assert.Equal(SynologyPhotoFailure.Unavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.View)))).Failure);
        test.Shared = true; original = await repo.AlbumSharingAsync(61);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.Disabled))).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("owner")] [InlineData("revision")] [InlineData("home")]
    public async Task SharingFinalPreparationRejectsRevokedOrChangedTarget(string change)
    {
        using var test = new SharingFixture(); var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61);
        test.Store.OnSave = _ => { if (change == "owner") test.Owner = 66; else if (change == "revision") test.Expiration = 55; else test.Http.HomeEnabled = false; return Task.CompletedTask; };
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.View));
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SharingRejectsStaleCandidatesConditionalContributionAndSelfRemoval()
    {
        using var test = new SharingFixture { Conditional = true }; var repo = await test.Repository(); var original = await repo.AlbumSharingAsync(61);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.Invited)
        { Members = [new(new(new("user", "44", true), "Synthetic"), "upload")] }));
        test.Candidates.Clear(); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.Invited)
        { Members = [new(new(new("user", "44", true), "Synthetic"), "view")] }));
        test.Permission.Add(SharingFixture.Member("user", 101, "view")); original = await repo.AlbumSharingAsync(61);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(original, SynologyPhotoLinkAccess.Invited) { Members = [] })); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SharingUnknownBlocksAlbumChangesAndDuplicateIdsAcrossManagementVariants()
    {
        using var test = new SharingFixture { DropAt = 1 }; var repo = await test.Repository(); var id = Guid.NewGuid(); var original = await repo.AlbumSharingAsync(61);
        await repo.EditSharingAsync(id, new(original, SynologyPhotoLinkAccess.View));
        var current = await repo.AlbumSharingAsync(61);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), new(current, SynologyPhotoLinkAccess.View)))).Failure);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(id, new(SynologyPhotoAlbumEditKind.Rename) { Album = original.Album, Name = "new" }))).Failure);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Rename) { Album = original.Album, Name = "new" }))).Failure);
        Assert.Single(test.Writes); Assert.Single(test.Store.Records);
    }
    [Fact]
    public async Task SharingConcurrentDuplicateSubmissionHasOneWriter()
    {
        using var test = new SharingFixture(); var repo = await test.Repository(); var edit = new SynologyPhotoSharingEdit(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.View); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { if (test.Writes.Count == 1) { entered.SetResult(); await release.Task; } };
        var first = repo.EditSharingAsync(id, edit); await entered.Task;
        Assert.True((await repo.EditSharingAsync(id, edit)).Running); release.SetResult();
        Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State); Assert.Equal(3, test.Writes.Count);
    }
    [Theory]
    [InlineData("http://example.invalid/link", true)] [InlineData("https://example.invalid/link", true)]
    [InlineData("https://user:password@example.invalid/link", false)] [InlineData("file:///C:/synthetic", false)] [InlineData("javascript:synthetic", false)]
    public async Task SharingLinksPermitRecordedWebSchemesButNeverEmbeddedCredentials(string link, bool allowed)
    {
        using var test = new SharingFixture { Shared = true, Link = link }; var repo = await test.Repository();
        Assert.Equal(allowed, (await repo.AlbumSharingAsync(61)).Url is not null); Assert.Empty(test.Writes);
        test.Shared = false; Assert.Null((await repo.AlbumSharingAsync(61)).Url);
    }
    [Theory]
    [InlineData("password")] [InlineData("Password")] [InlineData("_sid")] [InlineData("SynoToken")]
    public async Task SharingTransportStillRejectsCredentialInjectionOutsideExactPasswordUpdate(string field)
    {
        using var test = new SharingFixture();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => test.Http.Api.WritePhotoAsync(test.Http.Profile, test.Http.Session,
            test.Http.Capabilities["SYNO.Foto.Sharing.Passphrase"], 1, "set_shared", new Dictionary<string, string> { [field] = "synthetic" }));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SharingLateGenerationCannotOpenAndAnotherAccountCannotRecoverIt()
    {
        using var test = new SharingFixture(); var repo = await test.Repository();
        test.BeforeWrite = async () => { if (test.Writes.Count == 2) await repo.AccessAsync(); };
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.View));
        Assert.True(result.Pending); Assert.Equal(2, test.Writes.Count); Assert.False(test.Shared);
        var profile = test.Http.Profile with { Username = "synthetic-other-account" };
        var other = new SynologyPhotosRepository(profile, test.Http.Session, test.Http.Api, test.Http.Capabilities, managementStore: test.Store.Clone(), sharingSafety: new(true));
        await other.AccessAsync(); Assert.Empty(await other.SharingChangesAsync());
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinueSharingChangeAsync(result.Id))).Failure);
    }
    [Fact]
    public async Task SharingChangedAfterAcceptedConfigurationCannotBeReopened()
    {
        using var test = new SharingFixture { FailReadAfter = 2 }; var repo = await test.Repository();
        var result = await repo.EditSharingAsync(Guid.NewGuid(), new(await repo.AlbumSharingAsync(61), SynologyPhotoLinkAccess.View));
        test.FailReadAfter = 0; result = await repo.ReviewSharingChangeAsync(result.Id); Assert.Equal(SynologyPhotoSharingStage.Open, result.Stage);
        test.Expiration = 123;
        result = await repo.ContinueSharingChangeAsync(result.Id); Assert.Equal(SynologyPhotoFailure.TargetChanged, result.Failure); Assert.False(test.Shared); Assert.Equal(2, test.Writes.Count);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task SharingOriginalFieldsMustMatchLiveSnapshotEvenWithUnchangedRevision(bool access)
    {
        using var test = new SharingFixture(); var repo = await test.Repository(safety: false); var original = await repo.AlbumSharingAsync(61);
        var changed = access ? original with { Access = SynologyPhotoLinkAccess.Download } : original with { HasPassword = true };
        var edit = new SynologyPhotoSharingEdit(changed, access ? SynologyPhotoLinkAccess.View : SynologyPhotoLinkAccess.Disabled);
        Assert.False(edit.ExpandsAccess);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditSharingAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
    }
    private sealed class SharingFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new();
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly JsonArray Permission = [], Candidates = [Member("user", 44, "view"), Member("group", "44", "view")];
        internal long Owner = 19;
        internal JsonNode? Uid = JsonValue.Create(101), Expiration = JsonValue.Create(0);
        internal bool Shared, Conditional;
        internal bool? Password = false;
        internal string Privacy = "private";
        internal string Link = "https://nas.invalid/synthetic-link";
        internal int DropAt, RejectAt, FailReadAfter;
        internal Func<Task>? BeforeWrite;
        internal SharingFixture()
        {
            Http.Capabilities["SYNO.Foto.Sharing.Passphrase"] = new("SYNO.Foto.Sharing.Passphrase", "entry.cgi", 1, 1, "JSON");
            Http.AccessResponse = suffix => suffix == "SYNO.Foto.UserInfo" ? new() { ["enabled"] = Http.Enabled, ["id"] = Http.UserId, ["uid"] = Uid?.DeepClone() } : null;
            Http.Respond = Respond;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, sharingSafety: new(safety));
            await repo.AccessAsync(); return repo;
        }
        internal static JsonObject Member(string type, object id, string role) => new()
        { ["type"] = type, ["id"] = JsonSerializer.SerializeToNode(id), ["name"] = "Synthetic recipient", ["role"] = role };
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Method is "set_shared" or "update")
            {
                Writes.Add(request); if (BeforeWrite is not null) await BeforeWrite();
                if (Writes.Count == RejectAt) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                if (request.Method == "set_shared") Shared = request.Values["enabled"] == "true";
                else
                {
                    if (request.Values.TryGetValue("expiration", out var expiry)) Expiration = JsonNode.Parse(expiry);
                    if (request.Values.TryGetValue("password", out var password)) Password = JsonSerializer.Deserialize<string>(password)!.Length > 0;
                    if (request.Values.TryGetValue("permission", out var permissions)) foreach (var entry in JsonNode.Parse(permissions)!.AsArray())
                    {
                        var member = entry!["member"]!; var type = member["type"]!.GetValue<string>(); var remove = entry["action"]!.GetValue<string>() == "delete";
                        if (type == "public") { Privacy = remove ? "private" : entry["role"]!.GetValue<string>() == "view" ? "public-view" : "public-download"; continue; }
                        var old = Permission.FirstOrDefault(item => item!["type"]!.GetValue<string>() == type && JsonNode.DeepEquals(item["id"], member["id"]));
                        if (old is not null) Permission.Remove(old);
                        if (!remove) Permission.Add(new JsonObject { ["id"] = member["id"]!.DeepClone(), ["type"] = type, ["name"] = "Synthetic changed name", ["role"] = entry["role"]!.DeepClone() });
                    }
                }
                if (Writes.Count == DropAt) throw new HttpRequestException();
                return SynologyPhotosHttpFixture.Json(new() { ["passphrase"] = "synthetic-passphrase" });
            }
            if (FailReadAfter > 0 && Writes.Count >= FailReadAfter) throw new HttpRequestException();
            if (request.Method == "list_user_group") return SynologyPhotosHttpFixture.Json(new() { ["list"] = Candidates.DeepClone() });
            if (request.Api.EndsWith("Browse.Album", StringComparison.Ordinal)) return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(new JsonObject()
            {
                ["id"] = 61, ["owner_user_id"] = Owner, ["name"] = "original-album", ["type"] = Conditional ? "condition" : "normal", ["freeze_album"] = false,
                ["shared"] = Shared, ["temporary_shared"] = false, ["item_count"] = 0,
                ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject { ["privacy_type"] = Privacy, ["passphrase"] = "synthetic-passphrase",
                    ["sharing_link"] = Link, ["permission"] = Permission.DeepClone(), ["enable_password"] = Password, ["expiration"] = Expiration?.DeepClone() } },
            }));
            throw new InvalidOperationException(request.Api);
        }
        public void Dispose() => Http.Dispose();
    }
}
