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
    [InlineData(SynologyPhotoSpace.Personal)]
    [InlineData(SynologyPhotoSpace.Shared)]
    public async Task StandaloneTagCreatesOnceAndColdReadKeepsReceipt(SynologyPhotoSpace space)
    {
        using var test = new ManagementFixture(); var repo = await test.Repository();
        var edit = new SynologyPhotoEdit(SynologyPhotoEditKind.CreateTag, []) { Space = space, Text = "synthetic-tag" };
        var result = await repo.EditAsync(Guid.NewGuid(), edit);
        Assert.True(result.Completed); Assert.Empty(result.Items); Assert.Equal(41, result.CreatedTag!.Id);
        var cold = await test.Repository(test.Store.Clone());
        Assert.True((await cold.ReviewChangeAsync(result.Id)).Completed);
        Assert.True((await cold.ContinueChangeAsync(result.Id)).Completed);
        var wire = Assert.Single(test.Writes); Assert.Equal("create", wire.Method);
        Assert.StartsWith(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam." : "SYNO.Foto.", wire.Api);
    }
    [Fact]
    public async Task EmptyRejectedTagCanBeCancelledAfterRestartWithoutLosingItsSource()
    {
        using var test = new ManagementFixture { RejectMethod = "create" }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), new(SynologyPhotoEditKind.CreateTag, []) { Space = SynologyPhotoSpace.Shared, Text = "synthetic-tag" });
        var cold = await test.Repository(test.Store.Clone()); var restored = Assert.Single(await cold.ChangesAsync());
        Assert.False(restored.CanContinue); Assert.False(restored.Pending); Assert.Equal(SynologyPhotoChangeState.Failed, restored.TagState);
        var cancelled = await cold.CancelChangeAsync(result.Id); Assert.Equal(SynologyPhotoChangeState.Cancelled, cancelled.TagState);
        Assert.Equal(SynologyPhotoSpace.Shared, cancelled.Space); Assert.Empty(cancelled.Items); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoEditKind.Description, false)]
    [InlineData(SynologyPhotoEditKind.Rating, false)]
    [InlineData(SynologyPhotoEditKind.Date, false)]
    [InlineData(SynologyPhotoEditKind.ShiftDates, false)]
    [InlineData(SynologyPhotoEditKind.AddTags, false)]
    [InlineData(SynologyPhotoEditKind.RemoveTags, false)]
    [InlineData(SynologyPhotoEditKind.CreateTag, false)]
    [InlineData(SynologyPhotoEditKind.Rotate, false)]
    [InlineData(SynologyPhotoEditKind.Description, true)]
    [InlineData(SynologyPhotoEditKind.Rating, true)]
    [InlineData(SynologyPhotoEditKind.Date, true)]
    [InlineData(SynologyPhotoEditKind.ShiftDates, true)]
    [InlineData(SynologyPhotoEditKind.AddTags, true)]
    [InlineData(SynologyPhotoEditKind.RemoveTags, true)]
    [InlineData(SynologyPhotoEditKind.CreateTag, true)]
    [InlineData(SynologyPhotoEditKind.Rotate, true)]
    public async Task EditUsesRecordedSourceRouteAndVerifiesEveryResult(SynologyPhotoEditKind kind, bool shared)
    {
        using var test = new ManagementFixture(); var repo = await test.Repository();
        var photo = await test.Photo(repo, shared); var edit = Edit(kind, photo);
        var result = await repo.EditAsync(Guid.NewGuid(), edit);
        Assert.True(result.Completed); Assert.False(result.Running); Assert.False(result.CanContinue);
        Assert.Equal(kind == SynologyPhotoEditKind.CreateTag ? 2 : 1, test.Writes.Count);
        Assert.All(test.Writes, request =>
        {
            Assert.StartsWith(shared ? "SYNO.FotoTeam." : "SYNO.Foto.", request.Api);
            Assert.Equal(HttpMethod.Post, request.HttpMethod); Assert.DoesNotContain("synthetic-sid", request.Uri.ToString());
        });
        var wire = test.Writes.Last();
        Assert.Equal("[7]", wire.Values["id"]);
        if (kind is SynologyPhotoEditKind.AddTags or SynologyPhotoEditKind.RemoveTags or SynologyPhotoEditKind.CreateTag)
        {
            Assert.Equal(1, wire.Version); Assert.Equal(kind == SynologyPhotoEditKind.RemoveTags ? "remove_tag" : "add_tag", wire.Method);
        }
        else { Assert.Equal(2, wire.Version); Assert.Equal("set", wire.Method); }
        if (kind == SynologyPhotoEditKind.ShiftDates)
        { Assert.Equal(photo.TakenAt.ToUnixTimeSeconds() + 3600, long.Parse(wire.Values["time"])); Assert.False(wire.Values.ContainsKey("shift_time")); }
        if (kind == SynologyPhotoEditKind.Rotate) Assert.Equal("\"counter_clockwise\"", wire.Values["rotate_action"]);
        if (kind == SynologyPhotoEditKind.Description) Assert.Equal("new description", result.Items[0].Updated!.Description);
        Assert.All(test.Store.Records.Values, bytes =>
        {
            var json = Encoding.UTF8.GetString(bytes);
            Assert.DoesNotContain("new description", json); Assert.DoesNotContain("synthetic-tag", json);
            Assert.DoesNotContain("original description", json); Assert.DoesNotContain("synthetic-sid", json); Assert.DoesNotContain("nas.invalid", json);
        });
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LostReceiptNeverResendsAndColdReadbackKeepsFixedDate(bool applied)
    {
        using var test = new ManagementFixture { DropWrite = true, ApplyDropped = applied };
        var repo = await test.Repository(); var photo = await test.Photo(repo); var edit = Edit(SynologyPhotoEditKind.ShiftDates, photo); var id = Guid.NewGuid();
        var first = await repo.EditAsync(id, edit); Assert.Equal(applied, first.Completed);
        var cold = await test.Repository(test.Store.Clone());
        await cold.ReviewChangeAsync(id); await cold.ContinueChangeAsync(id); await cold.EditAsync(id, edit);
        Assert.Single(test.Writes); Assert.Equal(applied, (await cold.ChangesAsync()).Single().Completed);
        if (!applied)
        {
            var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, photo)));
            Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure);
        }
    }
    [Fact]
    public async Task CreateTagAndFailedApplicationColdContinueOnlyAddsExistingTag()
    {
        using var test = new ManagementFixture { RejectMethod = "add_tag" }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.CreateTag, await test.Photo(repo)));
        Assert.Equal(41, result.CreatedTag!.Id); Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[0].State);
        var cold = await test.Repository(test.Store.Clone()); test.RejectMethod = null;
        var final = await cold.ContinueChangeAsync(result.Id);
        Assert.True(final.Completed); Assert.Single(test.Writes, request => request.Method == "create");
        Assert.Equal(2, test.Writes.Count(request => request.Method == "add_tag"));
    }
    [Fact]
    public async Task LostTagCreationCannotClaimSameNameOrRecreateAfterRestart()
    {
        using var test = new ManagementFixture { DropWrite = true, ApplyDropped = true }; var repo = await test.Repository();
        var edit = Edit(SynologyPhotoEditKind.CreateTag, await test.Photo(repo)); var result = await repo.EditAsync(Guid.NewGuid(), edit);
        Assert.True(result.Pending); Assert.Null(result.CreatedTag);
        var cold = await test.Repository(test.Store.Clone()); await cold.ContinueChangeAsync(result.Id); await cold.ReviewChangeAsync(result.Id);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.EditAsync(Guid.NewGuid(), edit with { Photos = [] }));
        Assert.Single(test.Writes);
    }
    [Fact]
    public async Task RepeatedOperationIdDoesNotRetryExplicitFailureAndCannotChangePayload()
    {
        using var test = new ManagementFixture { RejectMethod = "set" }; var repo = await test.Repository();
        var edit = Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo)); var id = Guid.NewGuid();
        var first = await repo.EditAsync(id, edit); Assert.Equal(SynologyPhotoChangeState.Failed, first.Items[0].State);
        await repo.EditAsync(id, edit); Assert.Single(test.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(id, edit with { Value = 3 }));
        test.RejectMethod = null; Assert.True((await repo.ContinueChangeAsync(id)).Completed); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task MissingTagFieldCannotTurnRemoveIntoFalseSuccess()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository(); var edit = Edit(SynologyPhotoEditKind.RemoveTags, await test.Photo(repo));
        test.MissingTagsAfterWrite = true;
        var result = await repo.EditAsync(Guid.NewGuid(), edit); Assert.True(result.Pending);
        await repo.ContinueChangeAsync(result.Id); Assert.Single(test.Writes);
        test.MissingTagsAfterWrite = false; Assert.True((await repo.ReviewChangeAsync(result.Id)).Completed);
    }
    [Fact]
    public async Task MixedSameNumericIdsKeepNamespacesAndRejectMissingSharedManagement()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository();
        var personal = await test.Photo(repo); var shared = await test.Photo(repo, true);
        var edit = Edit(SynologyPhotoEditKind.Rating, personal) with { Photos = [personal, shared] };
        Assert.True((await repo.EditAsync(Guid.NewGuid(), edit)).Completed);
        Assert.Equal(new[] { "SYNO.Foto.Browse.Item", "SYNO.FotoTeam.Browse.Item" }, test.Writes.Select(request => request.Api));
        using var denied = new ManagementFixture(); denied.Http.TeamPermission = "entry"; var limited = await denied.Repository();
        var deniedEdit = Edit(SynologyPhotoEditKind.Rating, await denied.Photo(limited)) with { Photos = [await denied.Photo(limited), await denied.Photo(limited, true)] };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => limited.EditAsync(Guid.NewGuid(), deniedEdit)); Assert.Empty(denied.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(edit with { Kind = SynologyPhotoEditKind.AddTags, TagIds = [5] }));
    }
    [Theory]
    [InlineData("permission")]
    [InlineData("identity")]
    [InlineData("rating")]
    [InlineData("orientation")]
    public async Task ChangedIdentityOrPermissionRejectsBeforeWriting(string problem)
    {
        using var test = new ManagementFixture(); var repo = await test.Repository();
        var photo = await test.Photo(repo); var edit = Edit(problem == "orientation" ? SynologyPhotoEditKind.Rotate : SynologyPhotoEditKind.Rating, photo);
        if (problem == "permission") test.Manage = false;
        if (problem == "identity") test.Personal["filename"] = "replacement.jpg";
        if (problem == "rating") test.Personal["additional"]!["rating"] = 3;
        if (problem == "orientation") test.Personal["additional"]!["orientation"] = 3;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task StoreFailureAndCorruptionFailClosedWithoutBlockingReads()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository(); var edit = Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo));
        test.Store.FailSave = true; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
        Assert.Equal(7, (await test.Photo(repo)).Id.ItemId);
        var broken = new MemoryStore(); broken.Records[Guid.NewGuid()] = Encoding.UTF8.GetBytes("{}"); var cold = await test.Repository(broken);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.ChangesAsync()); Assert.Equal(7, (await test.Photo(cold)).Id.ItemId);
    }
    [Fact]
    public async Task AccountSwitchCannotReadOrContinueOldOperations()
    {
        using var test = new ManagementFixture { DropWrite = true }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo)));
        test.Http.UserId = 66; var cold = await test.Repository(test.Store.Clone()); Assert.Empty(await cold.ChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.ContinueChangeAsync(result.Id)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task DatePartialContinueUsesOriginalAbsoluteTargetsAndCancelOnlyRemaining()
    {
        using var test = new ManagementFixture { RejectWriteNumber = 2 }; var repo = await test.Repository();
        var a = await test.Photo(repo); var b = await test.Photo(repo, true);
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.ShiftDates, a) with { Photos = [a, b] });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.Items[0].State); Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[1].State);
        var cold = await test.Repository(test.Store.Clone()); test.RejectWriteNumber = 0;
        Assert.True((await cold.ContinueChangeAsync(result.Id)).Completed); Assert.Equal(3, test.Writes.Count);
        Assert.Single(test.Writes, request => request.Api == "SYNO.Foto.Browse.Item");
        Assert.All(test.Writes, request => Assert.Equal(a.TakenAt.ToUnixTimeSeconds() + 3600, long.Parse(request.Values["time"])));
        using var cancel = new ManagementFixture { RejectWriteNumber = 1 }; var cancelRepo = await cancel.Repository();
        var pending = await cancelRepo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, await cancel.Photo(cancelRepo)) with { Photos = [await cancel.Photo(cancelRepo), await cancel.Photo(cancelRepo, true)] });
        var cancelled = await cancelRepo.CancelChangeAsync(pending.Id); Assert.All(cancelled.Items, item => Assert.Equal(SynologyPhotoChangeState.Cancelled, item.State));
        await cancelRepo.ContinueChangeAsync(pending.Id); Assert.Single(cancel.Writes);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RotationNeedsExpectedOrientationAndReceiptControlsUnchangedDimensions(bool receipt)
    {
        using var test = new ManagementFixture { DropWrite = !receipt, ApplyDropped = true, KeepDimensions = true };
        var repo = await test.Repository(); var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rotate, await test.Photo(repo)));
        Assert.Equal(receipt, result.Completed); await repo.ContinueChangeAsync(result.Id); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(1, false)]
    [InlineData(1, true)]
    [InlineData(2, true)]
    public async Task OpaqueItemErrorListRequiresBoundedCountAndActualReadback(int errors, bool apply)
    {
        using var test = new ManagementFixture { ErrorCount = errors, ApplyError = apply }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo)));
        Assert.Equal(errors == 1 && apply, result.Completed);
        Assert.Equal(errors == 1 && !apply ? SynologyPhotoChangeState.Failed : errors == 2 ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, result.Items[0].State);
    }

    [Theory]
    [InlineData(45, 19, 45, "normal", true)]
    [InlineData(45, 77, 45, "normal", false)]
    [InlineData(19, 77, 19, "normal", false)]
    [InlineData(19, 77, 19, "condition", true)]
    [InlineData(0, 77, 19, "normal", true)]
    public async Task AlbumEditingChecksOriginalSourceProviderAndActualAlbumOwnership(long originalOwner, long provider, long albumOwner, string type, bool allowed)
    {
        using var test = new ManagementFixture { OriginalOwner = originalOwner, Provider = provider, AlbumOwner = albumOwner, AlbumType = type };
        var repo = await test.Repository(); var photo = await test.AlbumPhoto(repo); var edit = Edit(SynologyPhotoEditKind.Rating, photo);
        if (allowed)
        {
            Assert.True((await repo.EditAsync(Guid.NewGuid(), edit)).Completed);
            Assert.Equal(originalOwner == 0 ? "SYNO.FotoTeam.Browse.Item" : "SYNO.Foto.Browse.Item", Assert.Single(test.Writes).Api);
            Assert.False(test.Writes[0].Values.ContainsKey("album_id"));
            Assert.Contains(test.Http.Requests, request => request.Method == "get" && request.Api == "SYNO.Foto.Browse.Item" && request.Values.GetValueOrDefault("album_id") == "61");
        }
        else { await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes); }
    }
    [Fact]
    public async Task PermissionRevocationIsReadBeforeDispatchAndUnchangedRatingDoesNotWrite()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository(); var photo = await test.Photo(repo, true);
        test.Http.TeamPermission = "entry";
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, photo))); Assert.Empty(test.Writes);
        test.Http.TeamPermission = "management";
        Assert.True((await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.Rating, photo) with { Value = 1 })).Completed); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task GenerationChangeAfterDurableCheckpointSendsNothingAndAllowsExplicitContinue()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository(); var edit = Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo));
        test.Store.OnSave = async count => { if (count == 2) await repo.AccessAsync(); };
        var result = await repo.EditAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[0].State); Assert.Empty(test.Writes);
        Assert.True((await repo.ContinueChangeAsync(result.Id)).Completed); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CrashAtCheckpointRestoresAsUnknownWithoutSendingOrAutomaticallyContinuing()
    {
        using var test = new ManagementFixture(); var repo = await test.Repository(); var id = Guid.NewGuid();
        test.Store.OnSave = count => count == 2 ? Task.FromException(new IOException()) : Task.CompletedTask;
        var edit = Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(id, edit));
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ChangesAsync()).Single().Pending);
        await cold.ContinueChangeAsync(id); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ConcurrentClicksUseOneSubmissionAndUnknownMetadataBlocksLegacyDeletion()
    {
        using var test = new ManagementFixture { DropWrite = true }; var repo = await test.Repository();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.TrySetResult(); await release.Task; };
        var edit = Edit(SynologyPhotoEditKind.Rating, await test.Photo(repo)); var id = Guid.NewGuid();
        var running = repo.EditAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.True((await repo.EditAsync(id, edit)).Running); await repo.ContinueChangeAsync(id); Assert.Single(test.Writes);
        release.SetResult(); Assert.True((await running).Pending);
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.DeleteAsync(edit.Photos[0], Guid.NewGuid()));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task TagOnLaterPageVerifiesByIdAndCompletedCreationDoesNotRegressAfterRename()
    {
        using var test = new ManagementFixture { TagOnSecondPage = true }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.CreateTag, await test.Photo(repo)));
        Assert.True(result.Completed);
        Assert.Contains(test.Http.Requests, request => request.Api.EndsWith("GeneralTag", StringComparison.Ordinal) && request.Values.GetValueOrDefault("offset") == "500");
        test.TagNameOverride = "renamed"; var final = await repo.ReviewChangeAsync(result.Id); Assert.True(final.Completed); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task RenamedCreatedTagCannotBeAppliedOnResumeOrCauseAnotherCreation()
    {
        using var test = new ManagementFixture { RejectMethod = "add_tag" }; var repo = await test.Repository();
        var result = await repo.EditAsync(Guid.NewGuid(), Edit(SynologyPhotoEditKind.CreateTag, await test.Photo(repo)));
        test.TagNameOverride = "renamed"; test.RejectMethod = null;
        var cold = await test.Repository(test.Store.Clone()); var final = await cold.ContinueChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, final.TagState); Assert.Equal(SynologyPhotoFailure.TargetChanged, final.Items[0].Failure);
        Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task DescriptionRestoresWithoutSensitiveTextAndRequiresUserToReenterUnsentChanges()
    {
        using var test = new ManagementFixture { RejectMethod = "set" }; var repo = await test.Repository();
        var edit = Edit(SynologyPhotoEditKind.Description, await test.Photo(repo)); var result = await repo.EditAsync(Guid.NewGuid(), edit);
        var cold = await test.Repository(test.Store.Clone()); var restored = Assert.Single(await cold.ChangesAsync()); Assert.False(restored.CanContinue);
        await cold.ContinueChangeAsync(result.Id); Assert.Single(test.Writes);
        test.RejectMethod = null; await cold.EditAsync(result.Id, edit); Assert.Single(test.Writes);
        Assert.True((await cold.ContinueChangeAsync(result.Id)).Completed); Assert.Equal(2, test.Writes.Count);
    }

    private static SynologyPhotoEdit Edit(SynologyPhotoEditKind kind, SynologyPhoto photo) => new(kind, [photo])
    {
        Space = photo.Id.Space, Text = kind == SynologyPhotoEditKind.CreateTag ? "synthetic-tag" : kind == SynologyPhotoEditKind.Description ? "new description" : null,
        Value = kind switch { SynologyPhotoEditKind.Rating => 5, SynologyPhotoEditKind.Date => 1800000000, SynologyPhotoEditKind.ShiftDates => 3600, _ => null },
        TagIds = kind == SynologyPhotoEditKind.AddTags ? [5] : kind == SynologyPhotoEditKind.RemoveTags ? [4] : [],
    };
    private sealed class MemoryStore : IProtectedTaskStore
    {
        internal readonly Dictionary<Guid, byte[]> Records = [];
        internal bool FailSave;
        internal int Saves;
        internal Func<int, Task>? OnSave;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
        public async Task SaveAsync(Guid id, byte[] record) { if (FailSave) throw new IOException(); Records[id] = record.ToArray(); if (OnSave is not null) await OnSave(++Saves); }
        internal MemoryStore Clone() { var store = new MemoryStore(); foreach (var (id, bytes) in Records) store.Records[id] = bytes.ToArray(); return store; }
    }
    private sealed class ManagementFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly JsonObject Personal, Shared;
        internal bool Manage = true, DropWrite, ApplyDropped, MissingTagsAfterWrite, KeepDimensions, ApplyError;
        internal bool TagOnSecondPage;
        internal long OriginalOwner = 19, Provider = 19, AlbumOwner = 19;
        internal string AlbumType = "normal";
        internal string? TagNameOverride;
        internal Func<Task>? BeforeWrite;
        internal string? RejectMethod;
        internal int RejectWriteNumber, ErrorCount;
        private JsonObject? _tag;
        internal ManagementFixture()
        {
            Personal = Item(); Shared = Item(); Http.Respond = Respond;
        }
        private JsonObject Item()
        {
            var photo = Http.PhotoJson(); photo["additional"]!["description"] = "original description"; photo["additional"]!["rating"] = 1;
            photo["additional"]!["orientation"] = 1; photo["additional"]!["resolution"] = new JsonObject { ["width"] = 400, ["height"] = 300 };
            photo["additional"]!["tag"] = new JsonArray(new JsonObject { ["id"] = 4, ["name"] = "original-tag" }); return photo;
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, deletionEnabled: true, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        internal Task<SynologyPhoto> Photo(SynologyPhotosRepository repo, bool shared = false) => repo.DetailsAsync(Http.Photo with { Id = Http.Photo.Id with { Space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal } });
        internal Task<SynologyPhoto> AlbumPhoto(SynologyPhotosRepository repo) => repo.DetailsAsync(Http.Photo with
        { Id = Http.Photo.Id with { Space = OriginalOwner == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal }, AlbumContext = new(61, OriginalOwner, Provider) });
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            var photo = request.Api.StartsWith("SYNO.FotoTeam.", StringComparison.Ordinal) || request.Values.ContainsKey("album_id") && OriginalOwner == 0 ? Shared : Personal;
            if (request.Method is "set" or "add_tag" or "remove_tag" or "create")
            {
                Writes.Add(request);
                if (BeforeWrite is not null) await BeforeWrite();
                if (request.Method == RejectMethod || Writes.Count == RejectWriteNumber)
                    return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
                if (!DropWrite || ApplyDropped)
                {
                    if (ErrorCount == 0 || ApplyError)
                    {
                        if (request.Method == "create") _tag = new() { ["id"] = 41, ["name"] = JsonSerializer.Deserialize<string>(request.Values["name"]) };
                        else if (request.Method == "set")
                        {
                            foreach (var field in new[] { "rating", "description", "time" })
                                if (request.Values.TryGetValue(field, out var value))
                                { if (field == "time") photo[field] = JsonNode.Parse(value); else photo["additional"]![field] = JsonNode.Parse(value); }
                            if (request.Values.ContainsKey("rotate_action"))
                            {
                                photo["additional"]!["orientation"] = 8;
                                if (!KeepDimensions) photo["additional"]!["resolution"] = new JsonObject { ["width"] = 300, ["height"] = 400 };
                            }
                        }
                        else
                        {
                            var ids = JsonSerializer.Deserialize<long[]>(request.Values["tag"])!; var tags = (JsonArray)photo["additional"]!["tag"]!;
                            if (request.Method == "add_tag") foreach (var id in ids) tags.Add(new JsonObject { ["id"] = id, ["name"] = id == 41 ? "synthetic-tag" : "added-tag" });
                            else foreach (var tag in tags.Where(tag => ids.Contains(long.Parse(tag!["id"]!.ToString()))).ToArray()) tags.Remove(tag);
                        }
                    }
                }
                if (DropWrite) throw new HttpRequestException();
                var data = request.Method == "create" ? new JsonObject { ["tag"] = _tag!.DeepClone() } : new JsonObject();
                if (ErrorCount > 0) data["error_list"] = new JsonArray(Enumerable.Range(0, ErrorCount).Select(_ => (JsonNode)new JsonObject { ["synthetic"] = true }).ToArray());
                return SynologyPhotosHttpFixture.Json(data);
            }
            if (request.Api.EndsWith("Browse.Item", StringComparison.Ordinal))
            {
                var result = (JsonObject)photo.DeepClone(); if (MissingTagsAfterWrite && Writes.Count > 0) ((JsonObject)result["additional"]!).Remove("tag");
                if (request.Values.ContainsKey("album_id")) { result["owner_user_id"] = OriginalOwner; result["additional"]!["provider_user_id"] = Provider; }
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(result));
            }
            if (request.Api.EndsWith("Browse.GeneralTag", StringComparison.Ordinal))
            {
                if (TagOnSecondPage && request.Values.GetValueOrDefault("offset") == "0") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(
                    Enumerable.Range(100, 500).Select(id => new JsonObject { ["id"] = id, ["name"] = "synthetic-unused" }).ToArray()));
                var tag = (JsonObject?)_tag?.DeepClone(); if (tag is not null && TagNameOverride is not null) tag["name"] = TagNameOverride;
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(tag is null ? [] : [tag]));
            }
            if (request.Api.EndsWith("Browse.Album", StringComparison.Ordinal))
                return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = 61, ["owner_user_id"] = AlbumOwner, ["type"] = AlbumType }));
            if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal))
                return SynologyPhotosHttpFixture.Json(new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/synthetic", ["parent"] = 1,
                    ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } });
            throw new InvalidOperationException(request.Api);
        }
        public void Dispose() => Http.Dispose();
    }
}
