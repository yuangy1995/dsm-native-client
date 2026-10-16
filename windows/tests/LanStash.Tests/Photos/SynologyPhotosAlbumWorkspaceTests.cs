using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosAlbumWorkspaceTests
{
    private static SynologyPhotosTestRepository Repository()
    {
        var repo = new SynologyPhotosTestRepository { Albums = [new(3, "Synthetic album")] };
        repo.ReadAlbum = id => Task.FromResult(new SynologyPhotoAlbum(id, 1, 1, "Synthetic album", false, false, new('a', 64))
            { ProfileId = repo.ProfileId, CanContribute = true, Sort = new(SynologyPhotoSortField.Filename, true) });
        return repo;
    }
    private static SynologyPhotoAlbumChange Change(SynologyPhotoAlbumEdit edit, SynologyPhotoAlbum? result = null, SynologyPhotoChangeState state = SynologyPhotoChangeState.Completed) =>
        new(Guid.NewGuid(), edit, state, edit.Photos.Select(photo => new SynologyPhotoAlbumMemberChange(photo, SynologyPhotoChangeState.Completed)).ToArray(), result, null, false, false);
    private static async Task Open(SynologyPhotosWorkspace model)
    { await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(model.Collections[0]); }
    [Fact]
    public async Task OpenAlbumUsesItsOwnSortWithoutOriginalLibrary()
    {
        var repo = Repository(); repo.Spaces = []; using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        Assert.Equal(new(SynologyPhotoSortField.Filename, true), Assert.IsType<SynologyPhotoQuery.Album>(repo.Calls.Last().Query).Sort);
        Assert.NotNull(model.CurrentAlbum); Assert.Single(model.Items); Assert.Null(model.ErrorKey);
    }
    [Fact]
    public async Task EveryAlbumPageKeepsDisplayAndSort()
    {
        var repo = Repository(); repo.Albums = Enumerable.Range(1, 101).Select(id => new SynologyPhotoCollection(id, "Synthetic")).ToArray();
        repo.ReadAlbumDisplay = () => Task.FromResult(SynologyPhotoAlbumDisplay.Mine);
        repo.ReadAlbumSort = _ => Task.FromResult(new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.Created, true));
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.LoadNextAsync();
        Assert.Equal(101, model.Collections.Count); Assert.Equal(new[] { 0, 100 }, repo.AlbumPages.Select(page => page.Offset));
        Assert.All(repo.AlbumPages, page => { Assert.Equal(SynologyPhotoAlbumDisplay.Mine, page.Display); Assert.True(page.Sort.Descending); });
    }
    [Theory]
    [InlineData(SynologyPhotoShareScope.WithMe)]
    [InlineData(SynologyPhotoShareScope.WithOthers)]
    public async Task EverySharedPageKeepsItsScopeSort(SynologyPhotoShareScope scope)
    {
        var repo = Repository(); repo.Shares = Enumerable.Range(1, 101).Select(id => new SynologyPhotoSharedEntry(id.ToString(), "Synthetic", id)).ToArray();
        var calls = new List<SynologyPhotoAlbumListScope>(); repo.ReadAlbumSort = value => { calls.Add(value); return Task.FromResult(new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.ShareModified, true)); };
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Sharing); await model.SelectShareScopeAsync(scope); repo.SharePages.Clear();
        await model.LoadNextAsync(); Assert.Equal(101, model.SharedEntries.Count); Assert.Equal(scope, repo.SharePages[0].Scope); Assert.Equal(100, repo.SharePages[0].Offset);
        Assert.Equal(SynologyPhotoAlbumListField.ShareModified, repo.SharePages[0].Sort!.Field);
        Assert.Equal(scope == SynologyPhotoShareScope.WithMe ? SynologyPhotoAlbumListScope.WithMe : SynologyPhotoAlbumListScope.ByMe, calls.Last());
    }
    [Fact]
    public async Task CollectionRequestsDoNotReadOrWriteAlbumPreferences()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Sharing);
        repo.ReadAlbumSort = _ => throw new InvalidOperationException(); await model.SelectShareScopeAsync(SynologyPhotoShareScope.Requests);
        Assert.Null(model.AlbumListScope); Assert.Null(model.ErrorKey); Assert.Null(repo.SharePages.Last().Sort);
    }
    [Fact]
    public async Task RequestTitleSearchReadsAllPagesAndResetsWhenLeavingScope()
    {
        var repo = Repository(); repo.Shares = Enumerable.Range(1, 201).Select(id => new SynologyPhotoSharedEntry(id.ToString(), id == 201 ? "Find me" : "Synthetic")).ToArray();
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Sharing); await model.SelectShareScopeAsync(SynologyPhotoShareScope.Requests);
        repo.SharePages.Clear(); await model.SearchAsync(" find ");
        Assert.Equal("find", model.SearchText); Assert.Equal("201", Assert.Single(model.VisibleSharedEntries).Id);
        Assert.Equal(new[] { 0, 100, 200 }, repo.SharePages.Select(page => page.Offset)); Assert.False(model.HasMoreCollections); Assert.Null(model.ErrorKey);
        await model.SearchAsync("absent"); Assert.Empty(model.VisibleSharedEntries); Assert.True(model.IsFiltering);
        await model.SelectShareScopeAsync(SynologyPhotoShareScope.WithMe); Assert.Equal("", model.SearchText); Assert.False(model.IsRequestList);
    }
    [Fact]
    public async Task RequestCompletionRefreshesOnlyItsListAndOnlyOnce()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); repo.Calls.Clear();
        var change = new SynologyPhotoRequestChange(Guid.NewGuid(), SynologyPhotoRequestEditKind.Delete, SynologyPhotoChangeState.Completed, null, false, false, false, null);
        await model.ApplyRequestChangesAsync([change]); Assert.Empty(repo.Calls);
        await model.SelectSectionAsync(SynologyPhotosSection.Sharing); await model.SelectShareScopeAsync(SynologyPhotoShareScope.Requests); repo.SharePages.Clear();
        await model.ApplyRequestChangesAsync([change with { State = SynologyPhotoChangeState.PendingReview }]); Assert.Empty(repo.SharePages);
        await model.ApplyRequestChangesAsync([change]); Assert.Single(repo.SharePages);
        await model.ApplyRequestChangesAsync([change]); Assert.Single(repo.SharePages);
    }
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task UnavailablePreferencesDoNotBlockReadingOrPretendDefaultsWereRead(bool display)
    {
        var repo = Repository();
        if (display) repo.ReadAlbumDisplay = () => throw new IOException(); else repo.ReadAlbumSort = _ => throw new IOException();
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        Assert.Single(model.Collections); Assert.Equal("PhotosAlbumPreferencesFailed", model.ErrorKey); Assert.Empty(repo.AlbumPages);
        Assert.True(display ? model.AlbumDisplay is null : model.AlbumListSort is null);
    }
    [Fact]
    public async Task RenameUpdatesCurrentAlbumAndDoesNotReloadPhotos()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var original = model.CurrentAlbum!; var count = repo.Calls.Count;
        await model.ApplyAlbumChangeAsync(Change(new(SynologyPhotoAlbumEditKind.Rename) { Album = original, Name = "Renamed" }, original with { Name = "Renamed" }));
        Assert.Equal("Renamed", model.Album!.Name); Assert.Equal(count, repo.Calls.Count);
    }
    [Fact]
    public async Task MemberRemovalDoesNotDeleteOriginalOrOtherAlbumMember()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var photo = model.Items[0]; var read = repo.Read;
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([], offset, offset, false));
        var change = Change(new(SynologyPhotoAlbumEditKind.RemoveMembers) { Album = model.CurrentAlbum, Photos = [photo] });
        await model.ApplyAlbumChangeAsync(change); Assert.Empty(model.Items); repo.Read = read;
        await model.SelectSectionAsync(SynologyPhotosSection.Timeline); Assert.Single(model.Items);
        await Open(model); Assert.Single(model.Items); var calls = repo.Calls.Count; await model.ApplyAlbumChangeAsync(change);
        Assert.Single(model.Items); Assert.Equal(calls, repo.Calls.Count);
    }
    [Fact]
    public async Task PartialMemberResultsApplyOnlyCompletedItemsAndOnlyOnce()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        var photo = model.Items[0]; var second = photo with { Id = photo.Id with { ItemId = 2 } };
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([second], offset, offset + 1, false));
        var change = Change(new(SynologyPhotoAlbumEditKind.RemoveMembers) { Album = model.CurrentAlbum, Photos = [photo, second] }, state: SynologyPhotoChangeState.PendingReview) with
            { Members = [new(photo, SynologyPhotoChangeState.Completed), new(second, SynologyPhotoChangeState.PendingReview)] };
        await model.ApplyAlbumChangeAsync(change); Assert.Equal(second.Id, Assert.Single(model.Items).Id);
        var calls = repo.Calls.Count; await model.ApplyAlbumChangeAsync(change); Assert.Equal(calls, repo.Calls.Count);
    }
    [Fact]
    public async Task ChangedAlbumSortRetainsContentsOnReadFailureAndRetriesSameWindow()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var album = model.CurrentAlbum!; var sort = new SynologyPhotoSort(SynologyPhotoSortField.FileSize);
        var change = Change(new(SynologyPhotoAlbumEditKind.Sort) { Album = album, Sort = sort }, album with { Sort = sort });
        repo.Read = (_, _, _) => throw new IOException(); await model.ApplyAlbumChangeAsync(change);
        Assert.True(model.NeedsChangesRefresh); Assert.Single(model.Items); repo.Read = null; await model.LoadNextAsync();
        Assert.False(model.NeedsChangesRefresh); Assert.Equal(sort, Assert.IsType<SynologyPhotoQuery.Album>(repo.Calls.Last().Query).Sort);
    }
    [Fact]
    public async Task ForeignConnectionResultCannotRenameCurrentAlbum()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var album = model.CurrentAlbum! with { ProfileId = Guid.NewGuid() };
        await model.ApplyAlbumChangeAsync(Change(new(SynologyPhotoAlbumEditKind.Rename) { Album = album, Name = "Other" }, album with { Name = "Other" }));
        Assert.Equal("Synthetic album", model.Album!.Name);
    }
    [Fact]
    public async Task DeleteAlbumReturnsToItsListAndKeepsOriginalPhotos()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var album = model.CurrentAlbum!; repo.Albums = [];
        await model.ApplyAlbumChangeAsync(Change(new(SynologyPhotoAlbumEditKind.Delete) { Album = album }));
        Assert.Null(model.Album); Assert.Empty(model.Collections); await model.SelectSectionAsync(SynologyPhotosSection.Timeline); Assert.Single(model.Items);
    }
    [Fact]
    public async Task CompletedCreateRefreshesAlbumList()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        repo.Albums = [.. repo.Albums, new(4, "New")]; await model.ApplyAlbumChangeAsync(Change(new(SynologyPhotoAlbumEditKind.Create) { Name = "New" }, (await repo.AlbumAsync(4)) with { Name = "New" }));
        Assert.Equal(2, model.Collections.Count);
    }
    [Theory]
    [InlineData(SynologyPhotoAlbumEditKind.Condition)]
    [InlineData(SynologyPhotoAlbumEditKind.Unfreeze)]
    public async Task ConditionAndUnfreezeReloadCurrentAlbumWithoutChangingItsScope(SynologyPhotoAlbumEditKind kind)
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var original = model.CurrentAlbum!;
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([], offset, offset, false));
        await model.ApplyAlbumChangeAsync(Change(new(kind) { Album = original }, original with { Conditional = kind == SynologyPhotoAlbumEditKind.Condition, Frozen = false }));
        Assert.Equal(3, model.Album!.Id); Assert.Equal(3, Assert.IsType<SynologyPhotoQuery.Album>(repo.Calls.Last().Query).Id); Assert.Empty(model.Items);
    }
    [Theory]
    [InlineData(SynologyPhotoChangeState.PendingReview)]
    [InlineData(SynologyPhotoChangeState.Failed)]
    [InlineData(SynologyPhotoChangeState.Completed)]
    public async Task RebuildNavigatesToNewIdentityOnlyAfterOldCleanupCompletes(SynologyPhotoChangeState state)
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var original = model.CurrentAlbum!;
        var replacement = original with { Id = 8, Name = "replacement", Conditional = true }; var calls = repo.Calls.Count;
        await model.ApplyAlbumChangeAsync(Change(new(SynologyPhotoAlbumEditKind.Rebuild) { Album = original }, replacement, state) with { ReplacementCreated = true });
        Assert.Equal(state == SynologyPhotoChangeState.Completed ? 8 : 3, model.Album!.Id);
        if (state == SynologyPhotoChangeState.Completed) Assert.Equal(8, Assert.IsType<SynologyPhotoQuery.Album>(repo.Calls.Last().Query).Id);
        else Assert.Equal(calls, repo.Calls.Count);
    }
}
