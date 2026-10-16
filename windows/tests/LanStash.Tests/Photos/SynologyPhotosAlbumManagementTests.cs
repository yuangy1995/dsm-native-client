using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.Create, "create", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.Rename, "set_name", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.Delete, "delete", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.AddMembers, "add_item", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.RemoveMembers, "delete_item", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.Cover, "set_cover", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.Sort, "set_order", 1)]
    [InlineData(SynologyPhotoAlbumEditKind.ListSort, "set_album_list_order", 2)]
    [InlineData(SynologyPhotoAlbumEditKind.ListDisplay, "set_album_list_display", 3)]
    public async Task AlbumActionsUseRecordedRoutesAndReadFinalResult(SynologyPhotoAlbumEditKind kind, string method, int version)
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); var request = Assert.Single(test.Writes);
        Assert.Equal(method, request.Method); Assert.Equal(version, request.Version); Assert.StartsWith("SYNO.Foto.Browse.", request.Api);
        Assert.DoesNotContain("BackgroundTask", request.Api); Assert.Equal(HttpMethod.Post, request.HttpMethod);
        if (kind == SynologyPhotoAlbumEditKind.Cover) Assert.Equal("7", request.Values["id_item"]);
        if (kind == SynologyPhotoAlbumEditKind.Delete) Assert.Equal("[61]", request.Values["id"]);
        if (kind == SynologyPhotoAlbumEditKind.Create) { Assert.Equal("[]", request.Values["item"]); Assert.Equal(62, result.Result!.Id); }
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ContinueAlbumChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.Create)]
    [InlineData(SynologyPhotoAlbumEditKind.Rename)]
    [InlineData(SynologyPhotoAlbumEditKind.Delete)]
    [InlineData(SynologyPhotoAlbumEditKind.AddMembers)]
    [InlineData(SynologyPhotoAlbumEditKind.RemoveMembers)]
    [InlineData(SynologyPhotoAlbumEditKind.Cover)]
    [InlineData(SynologyPhotoAlbumEditKind.Sort)]
    public async Task LostAlbumReceiptCannotClaimExternalOutcomeOrReplayAfterRestart(SynologyPhotoAlbumEditKind kind)
    {
        using var test = new AlbumFixture { Drop = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, kind)); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueAlbumChangeAsync(result.Id);
        Assert.True(result.Pending); Assert.False(result.CanContinue); Assert.Single(test.Writes);
        Assert.True((await cold.CancelAlbumChangeAsync(result.Id)).Pending);
    }
    [Fact]
    public async Task AlbumAcceptedReceiptSurvivesFailedReadAndNewNameNeverEntersRecoveryFile()
    {
        using var test = new AlbumFixture { FailReadsAfterWrite = true }; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Create) { Name = "sensitive-new-name" }); Assert.True(result.Pending);
        var bytes = Assert.Single(test.Store.Records).Value; var json = Encoding.UTF8.GetString(bytes);
        Assert.DoesNotContain("sensitive-new-name", json); Assert.DoesNotContain("synthetic-token", json); Assert.DoesNotContain("synthetic-sid", json);
        test.FailReadsAfterWrite = false; var cold = await test.Repository(test.Store.Clone());
        var completed = await cold.ReviewAlbumChangeAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Completed, completed.State); Assert.Equal(62, completed.Result!.Id); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RejectedNameEditRequiresReentryAfterRestartAndCancelsWithoutWriting()
    {
        using var test = new AlbumFixture { Reject = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); var cold = await test.Repository(test.Store.Clone());
        Assert.False(Assert.Single(await cold.AlbumChangesAsync()).CanContinue); await cold.ContinueAlbumChangeAsync(result.Id); Assert.Single(test.Writes);
        test.Reject = false; await cold.EditAlbumAsync(result.Id, edit); Assert.Single(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ContinueAlbumChangeAsync(result.Id)).State); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task PartialMembershipResumesOnlyRemainingPhotoAndPreservesCompletedFacts()
    {
        using var test = new AlbumFixture { Partial = true }; var repo = await test.Repository();
        var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers); edit = edit with { Photos = [test.Photo(7), test.Photo(8)] };
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.Members[0].State); Assert.Equal(SynologyPhotoChangeState.Failed, result.Members[1].State);
        test.Partial = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueAlbumChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal("[8]", test.Writes[1].Values["item"]);
        test.Members.Clear(); Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewAlbumChangeAsync(result.Id)).State);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ContributorUsesEphemeralPassphraseAndOnlyRemovesOwnContribution(bool remove)
    {
        using var test = new AlbumFixture { Owner = 66, Provider = 19 }; var repo = await test.Repository();
        var edit = await test.Edit(repo, remove ? SynologyPhotoAlbumEditKind.RemoveMembers : SynologyPhotoAlbumEditKind.AddMembers);
        if (remove) { test.Http.HomeEnabled = false; await repo.AccessAsync(); }
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var write = Assert.Single(test.Writes); Assert.Equal("\"synthetic-passphrase\"", write.Values["passphrase"]); Assert.False(write.Values.ContainsKey("id"));
        Assert.DoesNotContain("synthetic-passphrase", Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value));
        Assert.Contains(test.Http.Requests, request => request.Method == "get_permission" && request.Values["exclude_public"] == "false");
    }
    [Fact]
    public async Task ContributorCannotRemoveOtherProviderOrModifyAlbumIdentity()
    {
        using var test = new AlbumFixture { Owner = 66, Provider = 55 }; var repo = await test.Repository();
        var remove = await test.Edit(repo, SynologyPhotoAlbumEditKind.RemoveMembers);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), remove));
        var rename = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename);
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), rename))).Failure); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConditionAndFrozenAlbumsDisallowContributionButFrozenCoverRemainsAvailable(bool conditional)
    {
        using var test = new AlbumFixture { Conditional = conditional, Frozen = !conditional }; var repo = await test.Repository();
        var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers);
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
        var cover = await test.Edit(repo, SynologyPhotoAlbumEditKind.Cover);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditAlbumAsync(Guid.NewGuid(), cover)).State);
    }
    [Fact]
    public async Task DeleteRequiresDedicatedSafetyAndChangedOriginalPreventsWrite()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(safety: false); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Delete);
        Assert.Equal(SynologyPhotoFailure.Unavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure);
        repo = await test.Repository(); test.Name = "changed";
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task PermissionRevokedAtFinalPreparationRejectsWithoutWrite()
    {
        using var test = new AlbumFixture { Owner = 66 }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers);
        test.Store.OnSave = _ => { test.Upload = false; return Task.CompletedTask; };
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        Assert.Equal(SynologyPhotoFailure.Permission, result.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task AlbumSourceRequiresOriginalLibraryAndCurrentProviderBeforeTransfer()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); var photo = test.Photo(7) with { AlbumContext = new(70, 19, 19) };
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Create) { Name = "copy-members", Photos = [photo] };
        test.Http.HomeEnabled = false;
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure);
        test.Http.HomeEnabled = true; test.Provider = 66;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SameNumericIdAcrossSpacesIsRejectedBeforeReadOrWrite()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); var photo = test.Photo(7);
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Create) { Name = "mixed", Photos = [photo, photo with { Id = photo.Id with { Space = SynologyPhotoSpace.Shared } }] };
        var count = test.Http.Requests.Count; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit));
        Assert.Equal(count, test.Http.Requests.Count); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ExistingMemberOnSecondPageDoesNotCauseDuplicateWrite()
    {
        using var test = new AlbumFixture(); test.Members.UnionWith(Enumerable.Range(100, 100).Select(value => (long)value)); test.Members.Add(7);
        var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditAlbumAsync(Guid.NewGuid(), edit)).State); Assert.Empty(test.Writes);
        Assert.Contains(test.Http.Requests, request => request.Api.EndsWith("Browse.Item", StringComparison.Ordinal) && request.Values.GetValueOrDefault("offset") == "100");
    }
    [Fact]
    public async Task MembershipOwnerMismatchCannotConfirmOrCauseAWrite()
    {
        using var test = new AlbumFixture { MemberOwner = 0 }; test.Members.Add(7); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers);
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, result.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task PendingAlbumMemberBlocksMetadataDeleteAndOtherAlbumCommands()
    {
        using var test = new AlbumFixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.AddMembers);
        await repo.EditAlbumAsync(Guid.NewGuid(), edit);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), new(SynologyPhotoEditKind.Rating, edit.Photos) { Value = 4 }))).Failure);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareDeletionAsync(edit.Photos[0]))).Failure);
        var rename = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), rename))).Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task AlbumStoreFailureAtSubmittingCheckpointRestoresUnknownWithoutSending()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); test.Store.OnSave = count => count == 2 ? Task.FromException(new IOException()) : Task.CompletedTask;
        var id = Guid.NewGuid(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(id, edit)); var cold = await test.Repository(test.Store.Clone());
        Assert.True((await cold.ContinueAlbumChangeAsync(id)).Pending); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task DuplicateAlbumClicksShareOneWriteAndOtherOwnerCannotSeeOrResumeTask()
    {
        using var test = new AlbumFixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.TrySetResult(); await release.Task; };
        var operation = repo.EditAlbumAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.EditAlbumAsync(id, edit)).Running); release.SetResult(); Assert.True((await operation).Pending); Assert.Single(test.Writes);
        test.Http.UserId = 88; var cold = await test.Repository(test.Store.Clone()); Assert.Empty(await cold.AlbumChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.ReviewAlbumChangeAsync(id));
    }
    [Fact]
    public async Task AlbumListSettingsUseOnlySelectedScopeAndAllPagesCarrySortAndDisplay()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository();
        foreach (var scope in Enum.GetValues<SynologyPhotoAlbumListScope>())
        {
            var old = await repo.AlbumListSortAsync(scope); var next = new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.StartTime, true);
            var result = await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.ListSort) { Scope = scope, OriginalListSort = old, ListSort = next });
            Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
            Assert.Equal(2, test.Writes.Last().Values.Keys.Count(key => key.EndsWith("_sort_by", StringComparison.Ordinal) || key.EndsWith("_sort_direction", StringComparison.Ordinal)));
        }
        await repo.AlbumsAsync(100, 100, SynologyPhotoAlbumDisplay.Mine, new(SynologyPhotoAlbumListField.Created, true));
        var wire = test.Http.Requests.Last(); Assert.Equal("100", wire.Values["offset"]); Assert.Equal("\"normal\"", wire.Values["category"]); Assert.Equal("\"create_time\"", wire.Values["sort_by"]);
        await repo.PhotosAsync(new SynologyPhotoQuery.Album(61, new(SynologyPhotoSortField.Filename)), 100, 100);
        wire = test.Http.Requests.Last(); Assert.Equal("\"filename\"", wire.Values["sort_by"]); Assert.Equal("\"asc\"", wire.Values["sort_direction"]);
    }
    [Fact]
    public async Task UnknownListPreferenceDoesNotBecomeDefaultAndSortReadbackRequiresExplicitFields()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); test.Preferences["album_list_sort_by"] = "unknown";
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.AlbumListSortAsync(SynologyPhotoAlbumListScope.Albums));
        test.OmitSortAfterWrite = true; var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Sort);
        Assert.True((await repo.EditAlbumAsync(Guid.NewGuid(), edit)).Pending); Assert.Single(test.Writes);
    }

    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.Create)]
    [InlineData(SynologyPhotoAlbumEditKind.Rename)]
    [InlineData(SynologyPhotoAlbumEditKind.Sort)]
    [InlineData(SynologyPhotoAlbumEditKind.Cover)]
    public async Task OwnedAlbumOperationsDoNotRequirePersonalLibrary(SynologyPhotoAlbumEditKind kind)
    {
        using var test = new AlbumFixture(); test.Http.HomeEnabled = false; var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), await test.Edit(repo, kind)); Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Single(test.Writes);
        Assert.DoesNotContain(test.Http.Requests, request => request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal));
    }
    [Fact]
    public async Task ViewerSortDoesNotDependOnContributionEndpoint()
    {
        using var test = new AlbumFixture { Owner = 66 }; test.Http.Capabilities.Remove("SYNO.Foto.Sharing.Passphrase"); var repo = await test.Repository();
        var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Sort); Assert.False(edit.Album!.CanContribute);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditAlbumAsync(Guid.NewGuid(), edit)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ChangedOperationIdentityAndCancelledRemainingCannotSubmitAgain()
    {
        using var test = new AlbumFixture { Reject = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename); var id = Guid.NewGuid();
        await repo.EditAlbumAsync(id, edit);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(id, edit with { Name = "other" }))).Failure);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await repo.CancelAlbumChangeAsync(id)).State); test.Reject = false;
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await repo.ContinueAlbumChangeAsync(id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task SameOperationIdCannotReplaceAnotherManagementRecord()
    {
        using var test = new AlbumFixture { Drop = true }; var repo = await test.Repository(); var id = Guid.NewGuid();
        await repo.EditAlbumAsync(id, await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename));
        var photo = test.Photo(7);
        Assert.Equal(SynologyPhotoFailure.TargetChanged, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(id, new(SynologyPhotoEditKind.Rating, [photo]) { Value = 4 }))).Failure);
        Assert.Single(test.Store.Records); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task AlbumSnapshotFromAnotherConnectionCannotBeSubmitted()
    {
        using var test = new AlbumFixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoAlbumEditKind.Rename);
        edit = edit with { Album = edit.Album! with { ProfileId = Guid.NewGuid() } };
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAlbumAsync(Guid.NewGuid(), edit))).Failure); Assert.Empty(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoShareScope.WithMe)]
    [InlineData(SynologyPhotoShareScope.WithOthers)]
    public async Task SharedAlbumPagesCarryExplicitScopeSort(SynologyPhotoShareScope scope)
    {
        using var test = new AlbumFixture(); var repo = await test.Repository();
        await repo.SharedEntriesAsync(scope, 100, 100, new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.StartTime));
        var request = test.Http.Requests.Last(); Assert.Equal("100", request.Values["offset"]); Assert.Equal("\"start_time\"", request.Values["sort_by"]); Assert.Equal("\"asc\"", request.Values["sort_direction"]);
        Assert.Equal(scope == SynologyPhotoShareScope.WithMe ? "list_shared_with_me_album" : "list", request.Method);
        if (scope == SynologyPhotoShareScope.WithOthers) Assert.Equal("\"shared\"", request.Values["category"]);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CreatedAlbumRequiresPrivateStateAndExactMembersBeyondReportedCount(bool unexpectedlyShared)
    {
        using var test = new AlbumFixture { CreatedShared = unexpectedlyShared, ExtraCreatedMember = !unexpectedlyShared };
        var repo = await test.Repository();
        var result = await repo.EditAlbumAsync(Guid.NewGuid(), new(SynologyPhotoAlbumEditKind.Create) { Name = "new", Photos = [test.Photo(7)] });
        Assert.True(result.Pending); Assert.Single(test.Writes);
        Assert.True((await repo.ContinueAlbumChangeAsync(result.Id)).Pending); Assert.Single(test.Writes);
    }
    private sealed class AlbumFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly HashSet<long> Members = [];
        internal readonly JsonObject Preferences = new();
        internal string Name = "original-album", CreatedName = "", SortBy = "takentime", Direction = "asc", Display = "all_album";
        internal long Owner = 19, Provider = 19, MemberOwner = 19, Cover = 7;
        internal bool Conditional, Frozen, Drop, Reject, Partial, FailReadsAfterWrite, OmitSortAfterWrite;
        internal bool Upload = true, Exists = true, Created;
        internal bool CreatedShared, ExtraCreatedMember;
        internal Func<Task>? BeforeWrite;
        internal AlbumFixture()
        {
            foreach (var api in new[] { "Browse.NormalAlbum", "Sharing.Passphrase" }) Http.Capabilities["SYNO.Foto." + api] = new("SYNO.Foto." + api, "entry.cgi", 1, 4, "JSON");
            foreach (var key in new[] { "album_list", "shared_with_me", "shared_with_others" }) { Preferences[key + "_sort_by"] = "album_name"; Preferences[key + "_sort_direction"] = "asc"; }
            Http.Respond = Respond;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, true, managementStore: store ?? Store, albumSafety: new(safety));
            await repo.AccessAsync(); return repo;
        }
        internal SynologyPhoto Photo(long id) => Http.Photo with { Id = Http.Photo.Id with { ItemId = id } };
        internal async Task<SynologyPhotoAlbumEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoAlbumEditKind kind)
        {
            if (kind is SynologyPhotoAlbumEditKind.RemoveMembers or SynologyPhotoAlbumEditKind.Cover) Members.Add(7);
            return new(kind)
            {
                Album = kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.ListSort or SynologyPhotoAlbumEditKind.ListDisplay ? null : await repo.AlbumAsync(61),
                Name = kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.Rename ? "new-album" : null,
                Photos = kind == SynologyPhotoAlbumEditKind.AddMembers ? [Photo(7)] : kind is SynologyPhotoAlbumEditKind.RemoveMembers or SynologyPhotoAlbumEditKind.Cover ? [Photo(7) with { AlbumContext = new(61, MemberOwner, Provider) }] : [],
                Sort = kind == SynologyPhotoAlbumEditKind.Sort ? new(SynologyPhotoSortField.Filename, true) : null,
                OriginalListSort = kind == SynologyPhotoAlbumEditKind.ListSort ? new(SynologyPhotoAlbumListField.Name) : null,
                ListSort = kind == SynologyPhotoAlbumEditKind.ListSort ? new(SynologyPhotoAlbumListField.Created, true) : null,
                OriginalDisplay = kind == SynologyPhotoAlbumEditKind.ListDisplay ? SynologyPhotoAlbumDisplay.All : null,
                Display = kind == SynologyPhotoAlbumEditKind.ListDisplay ? SynologyPhotoAlbumDisplay.Mine : null,
            };
        }
        private JsonObject Album(long id) => new()
        {
            ["id"] = id, ["name"] = id == 62 ? CreatedName : Name, ["owner_user_id"] = Owner, ["type"] = Conditional ? "condition" : "normal",
            ["freeze_album"] = Frozen, ["item_count"] = id == 62 && ExtraCreatedMember ? Members.Count - 1 : Members.Count, ["shared"] = id == 62 && CreatedShared,
            ["sort_by"] = OmitSortAfterWrite && Writes.Count > 0 ? null : SortBy, ["sort_direction"] = OmitSortAfterWrite && Writes.Count > 0 ? null : Direction,
            ["additional"] = new JsonObject { ["sharing_info"] = new JsonObject { ["passphrase"] = "synthetic-passphrase" },
                ["thumbnail"] = new JsonObject { ["unit_id"] = Cover, ["cache_key"] = "synthetic" } },
        };
        private JsonObject Item(long id, bool album)
        {
            var item = Http.PhotoJson(); item["id"] = id;
            if (album) { item["owner_user_id"] = MemberOwner; item["additional"]!["provider_user_id"] = Provider; }
            return item;
        }
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            if (request.Method is "create" or "set_name" or "delete" or "set_cover" or "set_order" or "add_item" or "delete_item" or "set_album_list_order" or "set_album_list_display")
            {
                Writes.Add(request); if (BeforeWrite is not null) await BeforeWrite();
                if (Reject) return new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                var data = new JsonObject();
                switch (request.Method)
                {
                    case "create": Created = true; CreatedName = JsonSerializer.Deserialize<string>(request.Values["name"])!; Members.UnionWith(JsonSerializer.Deserialize<long[]>(request.Values["item"])!);
                        if (ExtraCreatedMember) Members.Add(99); data["album"] = new JsonObject { ["id"] = 62 }; break;
                    case "set_name": Name = JsonSerializer.Deserialize<string>(request.Values["name"])!; break;
                    case "delete": Exists = false; break;
                    case "set_cover": Cover = long.Parse(request.Values["id_item"]); break;
                    case "set_order": SortBy = JsonSerializer.Deserialize<string>(request.Values["sort_by"])!; Direction = JsonSerializer.Deserialize<string>(request.Values["sort_direction"])!; break;
                    case "set_album_list_order": foreach (var (key, value) in request.Values.Where(pair => pair.Key.EndsWith("_sort_by", StringComparison.Ordinal) || pair.Key.EndsWith("_sort_direction", StringComparison.Ordinal))) Preferences[key] = JsonNode.Parse(value); break;
                    case "set_album_list_display": Display = JsonSerializer.Deserialize<string>(request.Values["album_display_type"])!; break;
                    case "add_item" or "delete_item":
                        var ids = JsonSerializer.Deserialize<long[]>(request.Values["item"])!;
                        foreach (var id in Partial ? ids.Take(1) : ids) { if (request.Method == "add_item") Members.Add(id); else Members.Remove(id); }
                        if (Partial) data["error_list"] = new JsonArray(new JsonObject { ["synthetic"] = true }); break;
                }
                if (Drop) throw new HttpRequestException(); return SynologyPhotosHttpFixture.Json(data);
            }
            if (FailReadsAfterWrite && Writes.Count > 0) throw new HttpRequestException();
            if (request.Method == "get_permission") return SynologyPhotosHttpFixture.Json(new() { ["permission"] = new JsonObject { ["upload"] = Upload, ["download"] = true } });
            if (request.Method == "get_album_list_order") return SynologyPhotosHttpFixture.Json((JsonObject)Preferences.DeepClone());
            if (request.Method == "get_album_list_display") return SynologyPhotosHttpFixture.Json(new() { ["album_display_type"] = Display });
            if (request.Method == "list_shared_with_me_album") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Album(61)));
            if (request.Api.EndsWith("Browse.Album", StringComparison.Ordinal))
            {
                var id = request.Values.TryGetValue("id", out var value) ? JsonSerializer.Deserialize<long[]>(value)![0] : 61;
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(id == 62 ? Created ? [Album(id)] : [] : Exists ? [Album(id)] : []));
            }
            if (request.Api.EndsWith("Browse.Item", StringComparison.Ordinal))
            {
                var album = request.Values.ContainsKey("album_id");
                var items = request.Method == "get" ? JsonSerializer.Deserialize<long[]>(request.Values["id"])! : Members.Skip(int.Parse(request.Values["offset"])).Take(int.Parse(request.Values["limit"])).ToArray();
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(items.Select(id => Item(id, album)).ToArray()));
            }
            if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)) return SynologyPhotosHttpFixture.Json(new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["download"] = true, ["manage"] = true } } } });
            throw new InvalidOperationException(request.Api);
        }
        public void Dispose() => Http.Dispose();
    }
}
