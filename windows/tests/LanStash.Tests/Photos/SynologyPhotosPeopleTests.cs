using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosPeopleTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async Task RenamesExactlyAndRequiresOwnReceipt(SynologyPhotoSpace space)
    {
        using var test = new Fixture(space); var repo = await test.Repository(); var people = await repo.PeopleAsync(space, false);
        var edit = new SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind.RenamePerson, [people[0]]) { Space = space, Name = "  合成人物  " };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var write = Assert.Single(test.Writes); Assert.Equal("set", write.Method); Assert.Equal(1, write.Version); Assert.Equal("11", write.Values["id"]);
        Assert.Equal("  合成人物  ", JsonSerializer.Deserialize<string>(write.Values["name"]));
        Assert.Equal(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Browse.Person" : "SYNO.Foto.Browse.Person", write.Api);
        Assert.Equal("  合成人物  ", Assert.Single(result.People).Person.Name);
    }
    [Fact]
    public async Task ClearSmallPersonNeedsReceiptAndAbsence()
    {
        using var test = new Fixture(); test.Photos[11] = [7]; var repo = await test.Repository();
        var person = (await repo.PeopleAsync(test.Space, false))[0];
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), new(SynologyPhotoRecognitionKind.RenamePerson, [person]) { Name = "" });
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal([11L], result.RemovedIds);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task LostRenameReceiptCannotBeReplacedByMatchingNameOrAbsence(bool clear)
    {
        using var test = new Fixture { Drop = true }; test.Photos[11] = [7]; var repo = await test.Repository();
        var edit = new SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind.RenamePerson, [(await repo.PeopleAsync(test.Space, false))[0]]) { Name = clear ? "" : "Changed" };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending);
        var cold = await test.Repository(test.Store.Clone()); Assert.True((await cold.ReviewRecognitionAsync(result.Id)).Pending);
        Assert.True((await cold.ContinueRecognitionAsync(result.Id)).Pending); Assert.True((await cold.CancelRecognitionAsync(result.Id)).Pending); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RenamePerson)][InlineData(SynologyPhotoRecognitionKind.MergePeople)][InlineData(SynologyPhotoRecognitionKind.ShowPeople)]
    public async Task AcceptedReadFailureRecoversWithoutResending(SynologyPhotoRecognitionKind kind)
    {
        using var test = new Fixture { FailRead = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, kind);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending);
        test.FailRead = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ReviewRecognitionAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); await cold.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task MergeUsesFullUnionAndSourceRemoval()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Completed, result.State);
        var write = Assert.Single(test.Writes); Assert.Equal(2, write.Version); Assert.Equal("merge", write.Method);
        Assert.Equal("11", write.Values["target_id"]); Assert.Equal("[12]", write.Values["merged_id"]);
        Assert.Equal(3, Assert.Single(result.People).Person.Count); Assert.Equal([12L], result.RemovedIds);
        Assert.All(test.Http.Requests.Where(call => call.Api.EndsWith("Browse.Timeline")), call => Assert.Equal(5, call.Version));
        Assert.All(test.Http.Requests.Where(call => call.Api.EndsWith("Browse.Item")), call => Assert.Equal(4, call.Version));
    }
    [Theory]
    [InlineData("source")][InlineData("items")][InlineData("identity")][InlineData("receipt")]
    public async Task IncompleteMergeStaysPending(string problem)
    {
        using var test = new Fixture { KeepSource = problem == "source", LosePhoto = problem == "items", ChangePhoto = problem == "identity", Drop = problem == "receipt" };
        var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople));
        Assert.True(result.Pending); await repo.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ShowPartialRetainsKnownSuccessAndNeverReplays()
    {
        using var test = new Fixture { PartialShow = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople));
        Assert.True(result.Pending); Assert.Equal([11L], result.CompletedIds); await repo.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes);
        test.Visible[11] = true; test.Visible[12] = false; result = await repo.ReviewRecognitionAsync(result.Id);
        Assert.True(result.Pending); Assert.Equal(2, result.CompletedIds.Count);
        test.Visible[11] = false; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State);
    }
    [Theory]
    [InlineData("missing")][InlineData("show")][InlineData("duplicate")][InlineData("unchanged")][InlineData("receipt")]
    public async Task ShowRequiresEveryExplicitStateAndReceipt(string problem)
    {
        using var test = new Fixture { BadAfter = problem, Ignore = problem == "unchanged", Drop = problem == "receipt" }; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople));
        Assert.True(result.Pending); Assert.Empty(result.CompletedIds); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("name")][InlineData("count")][InlineData("show")][InlineData("permission")][InlineData("recognition")]
    public async Task ChangedOriginalOrAccessRejectsBeforeWrite(string change)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople);
        if (change == "name") test.Names[11] = "Other";
        if (change == "count") test.Photos[11] = [7];
        if (change == "show") test.Visible[11] = false;
        if (change == "permission") test.Http.HomeEnabled = false;
        if (change == "recognition") test.Http.AccessResponse = api => api == "SYNO.Foto.Setting.Admin" ? new() { ["package_version"] = "synthetic", ["enable_person"] = false } : null;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SharedRequiresManagementAndCurrentRecognition()
    {
        using var test = new Fixture(SynologyPhotoSpace.Shared); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson);
        test.Http.TeamPermission = "entry"; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit));
        test.Http.TeamPermission = "management"; test.Http.TeamPersonEnabled = false; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task MergeCapabilityAndSafetyDoNotBlockRenaming()
    {
        using var test = new Fixture(); var name = "SYNO.Foto.Browse.Person"; test.Http.Capabilities[name] = test.Http.Capabilities[name] with { MaxVersion = 1 };
        var repo = await test.Repository(safety: false);
        var merge = await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(merge));
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson))).State);
    }
    [Fact]
    public async Task MergeRejectsCountsAndFolderPermissions()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople);
        test.CountOverride = 99; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit));
        test.CountOverride = null; test.Manage = false; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task DuplicateAndNoopShowAreInvalidAndRenameNoopIsZeroWrite()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var people = await repo.PeopleAsync(test.Space, true);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(new(SynologyPhotoRecognitionKind.ShowPeople, [people[0], people[0]]) { Visible = false }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareRecognitionAsync(new(SynologyPhotoRecognitionKind.ShowPeople, people) { Visible = true }));
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.EditRecognitionAsync(Guid.NewGuid(), new(SynologyPhotoRecognitionKind.RenamePerson, [people[0]]) { Name = people[0].Person.Name })).State); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ColdRejectedRenameRequiresInputAndContainsNoNames()
    {
        using var test = new Fixture { Reject = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson);
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        var persisted = Encoding.UTF8.GetString(test.Store.Records[result.Id]); Assert.DoesNotContain(edit.Name!, persisted); Assert.DoesNotContain(edit.People[0].Person.Name, persisted);
        var cold = await test.Repository(test.Store.Clone()); result = Assert.Single(await cold.RecognitionChangesAsync()); Assert.True(result.NeedsInput); Assert.False(result.CanContinue);
        await cold.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes); Assert.Equal(SynologyPhotoChangeState.Cancelled, (await cold.CancelRecognitionAsync(result.Id)).State);
    }
    [Fact]
    public async Task RejectedShowCanExplicitlyResumeAfterRestart()
    {
        using var test = new Fixture { Reject = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople));
        test.Reject = false; var cold = await test.Repository(test.Store.Clone()); result = await cold.ContinueRecognitionAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task DuplicateAndChangedFingerprintCannotOverwritePendingTask()
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson); var id = Guid.NewGuid();
        await repo.EditRecognitionAsync(id, edit); await repo.EditRecognitionAsync(id, edit);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(id, edit with { Name = "Other" }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task UnknownMergeBlocksPhotoAndAncestorWrites()
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople));
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.Rating, [test.Http.Photo]) { Value = 4 }));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, new(test.Space, 3, 1, "/Synthetic")) { Name = "Changed" })); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CorruptRecoveryAndForeignOwnerAreDenied()
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople));
        var other = new SynologyPhotosRepository(test.Http.Profile with { Username = "other-synthetic" }, test.Http.Session, test.Http.Api, test.Http.Capabilities, managementStore: test.Store.Clone());
        await other.AccessAsync(); Assert.Empty(await other.RecognitionChangesAsync()); await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ContinueRecognitionAsync(result.Id));
        var store = test.Store.Clone(); var node = JsonNode.Parse(store.Records[result.Id])!; node["Recognition"]!["People"]![0]!["NameHash"] = "bad";
        store.Records[result.Id] = JsonSerializer.SerializeToUtf8Bytes(node); var cold = await test.Repository(store);
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.RecognitionChangesAsync())).Failure); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task CoverUsesAuthorizedPersonOrUnitWithoutSizeAndClearsOnReauthorization(bool unit)
    {
        using var test = new Fixture { UnitThumbnail = unit }; var repo = await test.Repository(); var person = (await repo.CategoryItemsAsync(SynologyPhotoCategory.People, 0, 100))[0];
        await repo.CategoryImageAsync(SynologyPhotoCategory.People, person);
        var request = Assert.Single(test.Http.Requests, call => call.Uri.AbsolutePath.EndsWith("Thumbnail/get"));
        Assert.Equal(JsonSerializer.Serialize(unit ? "unit" : "person"), request.Values["type"]); Assert.Equal(unit ? "70" : "11", request.Values["id"]);
        Assert.False(request.Values.ContainsKey("size")); Assert.False(request.Values.ContainsKey("album_id"));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CategoryImageAsync(SynologyPhotoCategory.Tags, person));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CategoryImageAsync(SynologyPhotoCategory.People, person with { Thumbnail = person.Thumbnail! with { UnitId = 999 } }));
        await repo.AccessAsync(); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CategoryImageAsync(SynologyPhotoCategory.People, person));
    }
    [Fact]
    public async Task HiddenListPaginatesCompletelyAndRejectsDuplicatePages()
    {
        using var test = new Fixture(); for (var id = 13L; id <= 512; id++) { test.Names[id] = "Synthetic"; test.Photos[id] = []; test.Visible[id] = false; }
        var repo = await test.Repository(); Assert.Equal(502, (await repo.PeopleAsync(test.Space, true)).Count);
        var calls = test.Http.Requests.Where(call => call.Method == "list").ToArray(); Assert.Equal(["0", "500"], calls.Select(call => call.Values["offset"]));
        Assert.All(calls, call => { Assert.Equal("true", call.Values["show_hidden"]); Assert.Equal("true", call.Values["show_more"]); });
        test.RepeatPage = true; await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PeopleAsync(test.Space, true));
    }
    [Theory]
    [InlineData("id")][InlineData("name")][InlineData("missing")]
    public async Task IncorrectNameReceiptStaysUnknownDespiteMatchingReadback(string problem)
    {
        using var test = new Fixture { BadReceipt = problem }; var repo = await test.Repository();
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson));
        Assert.True(result.Pending); Assert.Empty(result.CompletedIds); await repo.ContinueRecognitionAsync(result.Id); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task DurableCheckpointFailurePreventsWrite()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson);
        test.Store.FailSave = node => node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting;
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditRecognitionAsync(Guid.NewGuid(), edit))).Failure);
        Assert.Empty(test.Writes); Assert.NotEmpty(await repo.PeopleAsync(test.Space, false));
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task ChangedPhotoOrFolderPermissionAfterCheckpointStopsMerge(bool permission)
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople);
        test.Store.AfterSave = node =>
        {
            if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting)
            { if (permission) test.Manage = false; else test.Photos[11] = [7, 10]; }
            return Task.CompletedTask;
        };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ParallelDuplicateOnlySendsOnce()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.Store.AfterSave = async node => { if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) { entered.TrySetResult(); await release.Task; } };
        var id = Guid.NewGuid(); var pending = repo.EditRecognitionAsync(id, edit); await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        try { Assert.True((await repo.EditRecognitionAsync(id, edit)).Running); Assert.Empty(test.Writes); }
        finally { release.TrySetResult(); }
        Assert.Equal(SynologyPhotoChangeState.Completed, (await pending).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CancellationBeforeSubmissionIsNotUnknown()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.ShowPeople); using var cancellation = new CancellationTokenSource();
        test.Store.AfterSave = node => { if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) cancellation.Cancel(); return Task.CompletedTask; };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit, cancellation.Token); Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(test.Writes);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, (await repo.CancelRecognitionAsync(result.Id)).State);
    }
    [Fact]
    public async Task IdentifierCannotBeReusedByOtherManagementVariants()
    {
        using var test = new Fixture { Drop = true }; var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(result.Id, new(SynologyPhotoFolderEditKind.Rename, new(test.Space, 3, 1, "/Synthetic")) { Name = "Other" }));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(result.Id, new(SynologyPhotoEditKind.Rating, [test.Http.Photo]) { Value = 3 }));
        Assert.Single(test.Store.Records); Assert.NotNull(JsonNode.Parse(test.Store.Records[result.Id])!["Recognition"]); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task LateReceiptAfterAccountChangeStaysWithOriginalOwner()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var edit = await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson);
        test.Store.AfterSave = async node =>
        {
            if (node["Recognition"]!["State"]!.GetValue<int>() == (int)SynologyPhotoChangeState.PendingReview && test.Http.UserId == 19)
            { test.Http.UserId = 20; await repo.AccessAsync(); }
        };
        var result = await repo.EditRecognitionAsync(Guid.NewGuid(), edit); Assert.True(result.Pending); Assert.Empty(await repo.RecognitionChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ReviewRecognitionAsync(result.Id));
        test.Http.UserId = 19; test.Store.AfterSave = null; await repo.AccessAsync();
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ReviewRecognitionAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task MergeReadsEveryPhotoPageAndUsesOverlappingUnion()
    {
        using var test = new Fixture(); test.Photos[11] = Enumerable.Range(1, 501).Select(id => (long)id).ToArray(); test.Photos[12] = [501, 502];
        var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.MergePeople));
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(502, Assert.Single(result.People).Person.Count);
        Assert.Contains(test.Http.Requests, call => call.Api.EndsWith("Browse.Item") && call.Values["offset"] == "500"); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task ExistingPersonRecordsWithoutOptionalFaceFieldsRemainReadable()
    {
        using var test = new Fixture(); var repo = await test.Repository(); var result = await repo.EditRecognitionAsync(Guid.NewGuid(), await test.Edit(repo, SynologyPhotoRecognitionKind.RenamePerson));
        var store = test.Store.Clone(); var root = JsonNode.Parse(store.Records[result.Id])!; var record = root["Recognition"]!.AsObject();
        foreach (var key in new[] { "Faces", "CoverReceipt", "PersonReceipt", "RemovedPhotoIds" }) record.Remove(key);
        store.Records[result.Id] = Encoding.UTF8.GetBytes(root.ToJsonString()); var cold = await test.Repository(store);
        var restored = Assert.Single(await cold.RecognitionChangesAsync()); Assert.Equal(SynologyPhotoChangeState.Completed, restored.State); Assert.Equal([11L], restored.CompletedIds); Assert.Single(test.Writes);
    }
    private sealed class Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal) : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management", TeamPersonEnabled = true };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal readonly Dictionary<long, string> Names = new() { [11] = "Synthetic Alice", [12] = "Synthetic Bob" };
        internal readonly Dictionary<long, bool> Visible = new() { [11] = true, [12] = true };
        internal readonly Dictionary<long, long[]> Photos = new() { [11] = [7, 8], [12] = [8, 9] };
        internal SynologyPhotoSpace Space => space;
        internal bool Drop, Reject, FailRead, PartialShow, KeepSource, LosePhoto, ChangePhoto, Ignore, UnitThumbnail, RepeatPage;
        internal bool Manage = true;
        internal int? CountOverride;
        internal string? BadAfter;
        internal string? BadReceipt;
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, bool safety = true)
        {
            Http.Respond = Respond;
            var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store, recognitionSafety: new(safety));
            await repo.AccessAsync(); return repo;
        }
        internal async Task<SynologyPhotoRecognitionEdit> Edit(SynologyPhotosRepository repo, SynologyPhotoRecognitionKind kind)
        {
            var people = await repo.PeopleAsync(space, kind == SynologyPhotoRecognitionKind.ShowPeople);
            return new(kind, kind == SynologyPhotoRecognitionKind.RenamePerson ? [people[0]] : people) { Space = space, Name = kind == SynologyPhotoRecognitionKind.ShowPeople ? null : "Changed person", Visible = false };
        }
        private JsonObject Person(long id)
        {
            var thumb = new JsonObject { ["cache_key"] = "synthetic" }; if (UnitThumbnail) thumb["unit_id"] = 70;
            var result = new JsonObject { ["id"] = id, ["name"] = Names[id], ["item_count"] = CountOverride ?? Photos[id].Length, ["show"] = Visible[id], ["additional"] = new JsonObject { ["thumbnail"] = thumb } };
            if (Writes.Count > 0 && BadAfter == "show") result.Remove("show"); return result;
        }
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Uri.AbsolutePath.EndsWith("Thumbnail/get"))
            {
                var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([137, 80, 78, 71]) };
                response.Content.Headers.ContentType = new("image/png"); return Task.FromResult(response);
            }
            if (call.Api.EndsWith("Browse.Person") && call.Method is "set" or "merge" or "show")
            {
                Writes.Add(call); if (Reject) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") });
                var result = new JsonObject();
                if (!Ignore)
                {
                    if (call.Method == "show")
                    { foreach (var id in JsonSerializer.Deserialize<long[]>(call.Values["id"])!.Take(PartialShow ? 1 : 100)) Visible[id] = JsonSerializer.Deserialize<bool>(call.Values["show"]); }
                    else
                    {
                        var id = JsonSerializer.Deserialize<long>(call.Values[call.Method == "merge" ? "target_id" : "id"]); Names[id] = JsonSerializer.Deserialize<string>(call.Values["name"])!;
                        if (call.Method == "merge")
                        {
                            var sources = JsonSerializer.Deserialize<long[]>(call.Values["merged_id"])!; Photos[id] = Photos[id].Concat(sources.SelectMany(source => Photos[source])).Distinct().ToArray();
                            if (LosePhoto) Photos[id] = Photos[id][..^1]; if (!KeepSource) foreach (var source in sources) Names.Remove(source);
                        }
                        else { result["id"] = id; result["name"] = Names[id]; if (Names[id] == "" && Photos[id].Length < 2) Visible[id] = false; }
                    }
                }
                if (BadReceipt == "id") result["id"] = 999;
                if (BadReceipt == "name") result["name"] = "Other";
                if (BadReceipt == "missing") result = new();
                if (Drop) throw new HttpRequestException(); return Task.FromResult(SynologyPhotosHttpFixture.Json(result));
            }
            if (Writes.Count > 0 && FailRead) throw new HttpRequestException();
            JsonObject data;
            if (call.Api.EndsWith("Browse.Person"))
            {
                IEnumerable<long> ids = call.Method == "get" ? JsonSerializer.Deserialize<long[]>(call.Values["id"])! : Names.Keys.Where(id => call.Values.ContainsKey("show_hidden") || Visible[id]);
                if (call.Method == "list") ids = ids.Skip(RepeatPage ? 0 : int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"]));
                var values = ids.Where(Names.ContainsKey).Select(Person).ToArray();
                if (Writes.Count > 0 && BadAfter == "missing") values = values.Take(1).ToArray();
                if (Writes.Count > 0 && BadAfter == "duplicate") values = [values[0], values[0].DeepClone().AsObject()];
                data = SynologyPhotosHttpFixture.List(values);
            }
            else if (call.Api.EndsWith("Browse.Timeline")) data = new() { ["section"] = new JsonArray(SynologyPhotosHttpFixture.List(new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = 3 })) };
            else if (call.Api.EndsWith("Browse.Item"))
            {
                var id = JsonSerializer.Deserialize<long>(call.Values["person_id"]);
                data = SynologyPhotosHttpFixture.List(Photos[id].Skip(int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"])).Select(photoId =>
                { var item = Http.PhotoJson(); item["id"] = photoId; if (ChangePhoto && Writes.Count > 0) item["filesize"] = 99; return item; }).ToArray());
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1,
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = Manage } } } };
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public void Dispose() => Http.Dispose();
    }
}
