using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotosSourceTests
{
    [Theory]
    [InlineData(true, true, "entry", 2, false)]
    [InlineData(true, true, "management", 2, true)]
    [InlineData(false, true, "entry", 1, false)]
    [InlineData(true, true, "none", 1, false)]
    [InlineData(true, false, "management", 1, false)]
    [InlineData(false, true, "admin", 0, false)]
    [InlineData(false, false, "none", 0, false)]
    public async Task ActualPhotosRoleDeterminesSourcesIndependentlyOfDsmAdministrator(
        bool home, bool team, string role, int count, bool management)
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = home, TeamEnabled = team, TeamPermission = role };
        var access = await fixture.Repository().AccessAsync();
        Assert.Equal(count, access.Spaces.Count); Assert.Equal(management, access.CanManageSharedSpace);
        Assert.Equal(home, access.Spaces.Contains(SynologyPhotoSpace.Personal));
        Assert.Equal(team && role is "entry" or "management", access.Spaces.Contains(SynologyPhotoSpace.Shared));
        Assert.All(fixture.Requests, call => Assert.StartsWith("SYNO.Foto.", call.Api));
    }

    [Theory]
    [InlineData("timeline", "Browse.Item", 4, "list")]
    [InlineData("search", "Search.Search", 1, "list_item")]
    [InlineData("filter", "Browse.Item", 2, "list_with_filter")]
    [InlineData("folder", "Browse.Item", 4, "list")]
    [InlineData("recent", "Browse.RecentlyAdded", 1, "list")]
    [InlineData("category", "Browse.Item", 4, "list")]
    public async Task SharedQueriesCarryExplicitSourceAndRecordedVersion(string kind, string suffix, int version, string method)
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "management" };
        var repository = fixture.Repository(); await repository.AccessAsync();
        SynologyPhotoQuery query = kind switch
        {
            "search" => new SynologyPhotoQuery.Search("synthetic & text", 0, 1900000000),
            "filter" => new SynologyPhotoQuery.Filtered(new() { Rating = 4 }, 0, 1900000000),
            "folder" => new SynologyPhotoQuery.Folder(3),
            "recent" => new SynologyPhotoQuery.Recent(),
            "category" => new SynologyPhotoQuery.Category(SynologyPhotoCategory.Tags, 5, 0, 1900000000),
            _ => new SynologyPhotoQuery.Timeline(0, 1900000000),
        };
        var page = await repository.PhotosAsync(query with { Space = SynologyPhotoSpace.Shared }, 10, 100);
        var call = fixture.Requests[^1];
        Assert.Equal("SYNO.FotoTeam." + suffix, call.Api); Assert.Equal(version, call.Version); Assert.Equal(method, call.Method);
        Assert.Equal("10", call.Values["offset"]); Assert.Equal(11, page.NextOffset);
        Assert.Equal(SynologyPhotoSpace.Shared, Assert.Single(page.Items).Id.Space);
        Assert.DoesNotContain("album_id", call.Values.Keys);
    }

    [Theory]
    [InlineData("timeline", "Browse.Timeline", 5, "get")]
    [InlineData("search", "Search.Search", 2, "get_search_timeline")]
    [InlineData("filter", "Browse.Timeline", 3, "get_with_filter")]
    public async Task SharedCalendarUsesTheSameSourceAsItsPhotoPages(string kind, string suffix, int version, string method)
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "entry" };
        fixture.Respond = (_, _) => Task.FromResult(Json(new JsonObject { ["section"] = new JsonArray() }));
        var repository = fixture.Repository(); await repository.AccessAsync();
        SynologyPhotoQuery query = kind switch
        {
            "search" => new SynologyPhotoQuery.Search("synthetic", 0, 1900000000),
            "filter" => new SynologyPhotoQuery.Filtered(new() { Rating = 1 }, 0, 1900000000),
            _ => new SynologyPhotoQuery.Timeline(0, 1900000000),
        };
        await repository.TimelineAsync(query with { Space = SynologyPhotoSpace.Shared });
        var call = fixture.Requests[^1]; Assert.Equal("SYNO.FotoTeam." + suffix, call.Api);
        Assert.Equal(version, call.Version); Assert.Equal(method, call.Method);
    }

    [Fact]
    public async Task AlbumsAndSharingRemainReadableWithoutAnyOriginalLibrary()
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = false };
        fixture.Respond = (_, _) => Task.FromResult(Json(List(new JsonObject { ["id"] = 41, ["name"] = "Synthetic album" })));
        var repository = fixture.Repository(); Assert.Empty((await repository.AccessAsync()).Spaces);
        Assert.Equal(41, Assert.Single(await repository.AlbumsAsync(0, 100)).Id);
        Assert.Equal(41, Assert.Single(await repository.SharedEntriesAsync(SynologyPhotoShareScope.WithMe, 0, 100)).AlbumId);
        var calls = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PhotosAsync(new SynologyPhotoQuery.Recent(), 0, 100));
        Assert.Equal(calls, fixture.Requests.Count);
        Assert.All(fixture.Requests, call => Assert.StartsWith("SYNO.Foto.", call.Api));
    }

    [Fact]
    public async Task AlbumDecodingPreservesEachOriginalOwnerAndContributor()
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = false };
        var personal = AlbumItem(fixture, 17, 19); var shared = AlbumItem(fixture, 0, 23); shared["id"] = 8;
        fixture.Respond = (_, _) => Task.FromResult(Json(List(personal.DeepClone().AsObject(), shared.DeepClone().AsObject())));
        var repository = fixture.Repository(); await repository.AccessAsync();
        var page = await repository.PhotosAsync(new SynologyPhotoQuery.Album(41) { Space = SynologyPhotoSpace.Shared }, 0, 2);
        Assert.True(page.HasMore); Assert.Equal(2, page.NextOffset);
        Assert.Equal(new[] { SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared }, page.Items.Select(item => item.Id.Space));
        Assert.Equal(new SynologyPhotoAlbumContext(41, 17, 19), page.Items[0].AlbumContext);
        Assert.Equal(new SynologyPhotoAlbumContext(41, 0, 23), page.Items[1].AlbumContext);
        var call = fixture.Requests[^1]; Assert.Equal("SYNO.Foto.Browse.Item", call.Api); Assert.Equal("41", call.Values["album_id"]);
        Assert.Contains("provider_user_id", call.Values["additional"]);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("negative")]
    [InlineData("text")]
    [InlineData("provider")]
    public async Task UnknownAlbumIdentityNeverDefaultsToPersonal(string invalid)
    {
        using var fixture = new SynologyPhotosHttpFixture(); var photo = AlbumItem(fixture, 17, 19);
        if (invalid == "missing") photo.Remove("owner_user_id");
        else if (invalid == "negative") photo["owner_user_id"] = -1;
        else if (invalid == "text") photo["owner_user_id"] = "17";
        else photo["additional"]!["provider_user_id"] = -1;
        fixture.Respond = (_, _) => Task.FromResult(Json(List(photo)));
        var repository = fixture.Repository(); await repository.AccessAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PhotosAsync(new SynologyPhotoQuery.Album(41), 0, 100));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(17)]
    public async Task AlbumMediaAlwaysKeepsUnifiedRouteAndOriginalAlbum(long owner)
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = false };
        var photo = fixture.Photo with { Id = fixture.Photo.Id with { Space = owner == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal }, AlbumContext = new(41, owner, 19) };
        fixture.Capabilities["SYNO.Foto.Sharing.Passphrase"] = new("SYNO.Foto.Sharing.Passphrase", "entry.cgi", 1, 1, "JSON");
        fixture.Respond = (call, _) => Task.FromResult(call.Uri.AbsolutePath.Contains("Thumbnail") || call.Api.EndsWith(".Download", StringComparison.Ordinal)
            ? Binary() : call.Api.EndsWith(".Browse.Album", StringComparison.Ordinal)
                ? Json(List(new JsonObject { ["id"] = 41, ["owner_user_id"] = 29, ["passphrase"] = "synthetic-sharing" }))
                : call.Api.EndsWith(".Sharing.Passphrase", StringComparison.Ordinal) ? Json(new JsonObject { ["permission"] = new JsonObject { ["download"] = true } })
                : Json(List(AlbumItem(fixture, owner, 23))));
        var repository = fixture.Repository(); await repository.AccessAsync();
        var detail = await repository.DetailsAsync(photo); Assert.Equal(23, detail.AlbumContext!.ProviderUserId);
        await repository.ThumbnailAsync(detail);
        var thumbnail = fixture.Requests[^1]; Assert.Equal("/synofoto/api/v2/p/Thumbnail/get", thumbnail.Uri.AbsolutePath);
        Assert.Equal("41", thumbnail.Values["album_id"]);
        var path = Path.Combine(Path.GetTempPath(), $"photos-source-{Guid.NewGuid():N}.jpg");
        try
        {
            await repository.DownloadOriginalAsync(detail, path);
            Assert.Equal(8, new FileInfo(path).Length);
            var download = fixture.Requests[^1]; Assert.Equal("SYNO.Foto.Download", download.Api); Assert.Equal("41", download.Values["album_id"]);
        }
        finally { if (File.Exists(path)) File.Delete(path); }
        Assert.All(fixture.Requests, call => { Assert.DoesNotContain("synthetic-sid", call.Uri.ToString()); Assert.DoesNotContain("synthetic-token", call.Uri.ToString()); });
    }

    [Fact]
    public async Task SharedThumbnailUsesTeamRouteWhileAlbumThumbnailUsesPersonalRoute()
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "entry" };
        fixture.Respond = (_, _) => Task.FromResult(Binary());
        var repository = fixture.Repository(); await repository.AccessAsync();
        var photo = fixture.Photo with { Id = fixture.Photo.Id with { Space = SynologyPhotoSpace.Shared } };
        await repository.ThumbnailAsync(photo);
        Assert.Equal("/synofoto/api/v2/t/Thumbnail/get", fixture.Requests[^1].Uri.AbsolutePath);
        Assert.DoesNotContain("album_id", fixture.Requests[^1].Values.Keys);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SharedAndAlbumLiveVideoRetainTheirReadContext(bool album)
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = !album, TeamPermission = "entry", HomeEnabled = false };
        fixture.Respond = (_, _) => Task.FromResult(Json(List(new JsonObject { ["id_item"] = 7, ["unit"] = new JsonArray(
            new JsonObject { ["id"] = 9, ["live_type"] = "video", ["additional"] = new JsonObject { ["video_convert"] = new JsonArray(new JsonObject { ["quality"] = "high" }) } }) })));
        var repository = fixture.Repository(); await repository.AccessAsync();
        var photo = fixture.Photo with { Id = fixture.Photo.Id with { Space = SynologyPhotoSpace.Shared }, MediaType = "live", AlbumContext = album ? new(41, 0, 19) : null };
        var media = await repository.VideoRequestAsync(photo);
        Assert.Equal(album ? "SYNO.Foto.Streaming" : "SYNO.FotoTeam.Streaming", media.Capability.Name);
        Assert.Equal(album, media.Parameters.ContainsKey("album_id")); Assert.Equal(album, fixture.Requests[^1].Values.ContainsKey("album_id"));
        Assert.Equal("9", media.Parameters["id"]);
    }

    [Fact]
    public async Task ChangedAlbumOwnerOrPermissionCannotFallBackToAnOriginalLibrary()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository(); await repository.AccessAsync();
        var photo = fixture.Photo with { AlbumContext = new(41, 17, 19) };
        fixture.Respond = (_, _) => Task.FromResult(Json(List(AlbumItem(fixture, 18, 19))));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DetailsAsync(photo));
        fixture.Respond = (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.Forbidden));
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.ThumbnailAsync(photo));
        Assert.Equal(before + 1, fixture.Requests.Count); Assert.Equal("41", fixture.Requests[^1].Values["album_id"]);
    }

    [Theory]
    [InlineData("entry", false, false)]
    [InlineData("management", false, true)]
    [InlineData("management", true, true)]
    public async Task SharedCategoryDiscoveryUsesUnifiedApiAndRecognitionPermissions(string role, bool person, bool any)
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = role, TeamPersonEnabled = person };
        fixture.Respond = (_, _) => Task.FromResult(Json(List(new JsonObject { ["id"] = "person" }, new JsonObject { ["id"] = "video" }, new JsonObject { ["id"] = "concept" })));
        var repository = fixture.Repository(); await repository.AccessAsync(); var before = fixture.Requests.Count;
        var categories = await repository.CategoriesAsync(space: SynologyPhotoSpace.Shared);
        Assert.Equal(any, categories.Count > 0); Assert.Equal(person, categories.Contains(SynologyPhotoCategory.People));
        Assert.DoesNotContain(SynologyPhotoCategory.Subjects, categories);
        if (any) Assert.Equal("SYNO.Foto.Browse.Category", fixture.Requests[^1].Api);
        else Assert.Equal(before, fixture.Requests.Count);
        if (!person) await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.CategoryItemsAsync(SynologyPhotoCategory.People, 0, 100, space: SynologyPhotoSpace.Shared));
    }

    [Fact]
    public async Task SharedFoldersAndFiltersUseTeamNamespaceAndKeepFolderSource()
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "entry" };
        fixture.Respond = (call, _) => Task.FromResult(Json(call.Api.EndsWith(".Filter", StringComparison.Ordinal)
            ? new JsonObject { ["person"] = new JsonArray(), ["geocoding"] = new JsonArray() }
            : call.Method == "get" ? new JsonObject { ["folder"] = Folder(3, 0) } : List(Folder(4, 3))));
        var repository = fixture.Repository(); await repository.AccessAsync();
        Assert.Equal(SynologyPhotoSpace.Shared, (await repository.RootFolderAsync(space: SynologyPhotoSpace.Shared)).Space);
        Assert.Equal(SynologyPhotoSpace.Shared, Assert.Single(await repository.FoldersAsync(3, 0, 100, space: SynologyPhotoSpace.Shared)).Space);
        await repository.FilterOptionsAsync(space: SynologyPhotoSpace.Shared);
        Assert.All(fixture.Requests.Skip(4), call => Assert.StartsWith("SYNO.FotoTeam.", call.Api));
    }

    [Fact]
    public async Task SharedWorkspaceReadsEveryRawPageWithoutChangingNamespace()
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = false, TeamEnabled = true, TeamPermission = "entry" };
        fixture.Respond = (call, _) => Task.FromResult(Json(call.Api.EndsWith(".Timeline", StringComparison.Ordinal)
            ? new JsonObject { ["section"] = new JsonArray(new JsonObject { ["list"] = new JsonArray(new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = 120 }) }) }
            : List(Enumerable.Range(1, 120).Skip(int.Parse(call.Values["offset"])).Take(int.Parse(call.Values["limit"]))
                .Select(id => { var item = fixture.PhotoJson(); item["id"] = id; return item; }).ToArray())));
        using var model = new SynologyPhotosWorkspace(fixture.Repository()); await model.RefreshAsync();
        Assert.Equal(100, model.Items.Count); Assert.True(model.HasMore); await model.LoadNextAsync();
        Assert.Equal(120, model.Items.Count); Assert.False(model.HasMore); Assert.Null(model.ErrorKey);
        Assert.All(model.Items, item => Assert.Equal(SynologyPhotoSpace.Shared, item.Id.Space));
        Assert.Equal(new[] { "0", "100" }, fixture.Requests.Where(call => call.Method == "list").Select(call => call.Values["offset"]));
    }

    [Fact]
    public async Task LateSharedResponseIsDiscardedAfterPermissionRevocation()
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "entry" };
        var repository = fixture.Repository(); await repository.AccessAsync();
        var response = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Respond = (_, _) => response.Task;
        var pending = repository.PhotosAsync(new SynologyPhotoQuery.Recent { Space = SynologyPhotoSpace.Shared }, 0, 100);
        fixture.TeamPermission = "none"; await repository.AccessAsync(); response.SetResult(Json(List(fixture.PhotoJson())));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.ThumbnailAsync(fixture.Photo with { Id = fixture.Photo.Id with { Space = SynologyPhotoSpace.Shared } }));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Fact]
    public async Task RecognitionFlagsAndMissingTeamCapabilityRemoveOnlyAffectedCategories()
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "management", TeamPersonEnabled = true };
        fixture.Capabilities.Remove("SYNO.FotoTeam.Browse.Person");
        fixture.AccessResponse = api => api == "SYNO.Foto.Setting.User"
            ? new JsonObject { ["enable_home_service"] = true, ["team_space_permission"] = "management", ["enable_person"] = false } : null;
        fixture.Respond = (_, _) => Task.FromResult(Json(List(new JsonObject { ["id"] = "person" }, new JsonObject { ["id"] = "video" })));
        var repository = fixture.Repository(); await repository.AccessAsync();
        Assert.Equal(new[] { SynologyPhotoCategory.Videos }, await repository.CategoriesAsync());
        Assert.Equal(new[] { SynologyPhotoCategory.Videos }, await repository.CategoriesAsync(space: SynologyPhotoSpace.Shared));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.CategoryItemsAsync(SynologyPhotoCategory.People, 0, 100));
    }

    [Fact]
    public async Task NoOriginalLibraryCannotBeUsedToReadPhotoCollectionRequests()
    {
        using var fixture = new SynologyPhotosHttpFixture { HomeEnabled = false }; var repository = fixture.Repository(); await repository.AccessAsync();
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.SharedEntriesAsync(SynologyPhotoShareScope.Requests, 0, 100));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Fact]
    public async Task MalformedAccessRefreshRevokesPreviousAuthorizationBeforeParsingNewFlags()
    {
        using var fixture = new SynologyPhotosHttpFixture(); var repository = fixture.Repository(); await repository.AccessAsync();
        fixture.AccessResponse = api => api == "SYNO.Foto.UserInfo" ? new JsonObject { ["enabled"] = true, ["id"] = "wrong-type" } : null;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.AccessAsync());
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DetailsAsync(fixture.Photo));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SharedReadAndAnotherOwnersAlbumCannotGrantOriginalDelete(bool shared)
    {
        using var fixture = new SynologyPhotosHttpFixture { TeamEnabled = true, TeamPermission = "management" };
        var repository = fixture.Repository(delete: true); await repository.AccessAsync();
        var photo = fixture.Photo with { Id = fixture.Photo.Id with { Space = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal }, AlbumContext = new(41, shared ? 0 : 17, fixture.UserId) };
        var before = fixture.Requests.Count;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.DeleteAsync(photo, Guid.NewGuid()));
        Assert.Equal(before, fixture.Requests.Count);
    }

    [Fact]
    public async Task SwitchingSourceClearsPreviewFilterAndLatePersonalPage()
    {
        var repository = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared] };
        using var model = new SynologyPhotosWorkspace(repository); await model.RefreshAsync(); await model.Preview.OpenAsync(repository.Photo());
        var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Read = (query, offset, _) => query.Space == SynologyPhotoSpace.Personal ? delayed.Task
            : Task.FromResult(new SynologyPhotoPage([repository.Photo(2, space: SynologyPhotoSpace.Shared)], offset, offset + 1, false));
        var old = model.ApplyFilterAsync(new() { Rating = 3 }); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        delayed.SetResult(new([repository.Photo()], 0, 1, false)); await old;
        Assert.Null(model.Preview.Photo); Assert.False(model.Filter.IsActive); Assert.Empty(model.FolderHistory);
        Assert.Equal(SynologyPhotoSpace.Shared, Assert.Single(model.Items).Id.Space); Assert.Null(model.ErrorKey);
        await model.JumpToMonthAsync(new(2026, 8)); Assert.Equal(SynologyPhotoSpace.Shared, repository.Calls[^1].Query.Space);
        await model.LoadPreviousAsync(); Assert.Equal(SynologyPhotoSpace.Shared, repository.Calls[^1].Query.Space);
    }

    [Fact]
    public async Task ChangingAlbumCategorySourceKeepsTheAlbumSection()
    {
        var repository = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared], Albums = [new(41, "Synthetic")] };
        using var model = new SynologyPhotosWorkspace(repository); await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        Assert.Equal(SynologyPhotosSection.Albums, model.Section); Assert.Single(model.Collections);
        Assert.Equal(SynologyPhotoSpace.Shared, model.SelectedSpace); Assert.Null(model.ErrorKey);
    }

    [Fact]
    public async Task WorkspaceRejectsWrongSourceAndWrongAlbumWithoutMixingRows()
    {
        var repository = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Shared], Albums = [new(41, "Synthetic")] };
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repository.Photo()], offset, offset + 1, false));
        using var model = new SynologyPhotosWorkspace(repository); await model.RefreshAsync();
        Assert.Empty(model.Items); Assert.NotNull(model.ErrorKey);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repository.Photo() with { AlbumContext = new(42, 19, 19) }], offset, offset + 1, false));
        await model.OpenCollectionAsync(Assert.Single(model.Collections));
        Assert.Empty(model.Items); Assert.NotNull(model.ErrorKey);
    }

    [Fact]
    public async Task AlbumOwnerChangeAcrossPagesStopsWithoutDiscardingTheFirstPage()
    {
        var repository = new SynologyPhotosTestRepository { Albums = [new(41, "Synthetic")] };
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage(
            [repository.Photo() with { AlbumContext = new(41, offset == 0 ? 17 : 18, 19) }], offset, offset + 1, offset == 0));
        using var model = new SynologyPhotosWorkspace(repository); await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        await model.OpenCollectionAsync(Assert.Single(model.Collections)); await model.LoadNextAsync();
        Assert.Equal(17, Assert.Single(model.Items).AlbumContext!.OwnerUserId); Assert.NotNull(model.ErrorKey);
    }

    [Theory]
    [InlineData("Browse.Album", 4, "list")]
    [InlineData("Browse.Category", 3, "get")]
    [InlineData("BackgroundTask.File", 1, "delete")]
    public async Task TeamPrefixDoesNotAuthorizeUnrecordedAlbumCategoryOrWriteCalls(string suffix, int version, string method)
    {
        using var fixture = new SynologyPhotosHttpFixture(); var name = "SYNO.FotoTeam." + suffix;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => fixture.Api.CallPhotoJsonAsync(fixture.Profile, fixture.Session,
            new(name, "entry.cgi", 1, 9, "JSON"), version, method));
        Assert.Empty(fixture.Requests);
    }

    [Fact]
    public async Task SourceAndAlbumContextParticipateInThumbnailCacheIdentity()
    {
        var repository = new SynologyPhotosTestRepository(); var calls = 0;
        repository.Thumbnail = (_, _) => Task.FromResult(new[] { (byte)++calls });
        using var cache = new SynologyPhotoThumbnailCache<byte>(repository, (bytes, _) => Task.FromResult(new SynologyPhotoDecodedThumbnail<byte>(bytes[0], 1)));
        var photo = repository.Photo(); Assert.Equal(1, await cache.GetAsync(photo)); Assert.Equal(1, await cache.GetAsync(photo));
        Assert.Equal(2, await cache.GetAsync(photo with { AlbumContext = new(41, 19, 19) }));
        Assert.Equal(3, await cache.GetAsync(photo with { AlbumContext = new(42, 19, 19) }));
        Assert.Equal(4, await cache.GetAsync(photo with { Id = photo.Id with { Space = SynologyPhotoSpace.Shared } }));
        Assert.Equal(4, calls);
    }

    [Fact]
    public async Task SharedPreviewReadsDetailAndMediaAndClosesNormally()
    {
        var repository = new SynologyPhotosTestRepository(); using var preview = new SynologyPhotoPreviewModel(repository);
        await preview.OpenAsync(repository.Photo(space: SynologyPhotoSpace.Shared));
        Assert.NotNull(preview.Photo); Assert.NotNull(preview.ImageBytes); Assert.Null(preview.ErrorKey);
        preview.Close(); Assert.Null(preview.ImageBytes);
    }

    private static JsonObject AlbumItem(SynologyPhotosHttpFixture fixture, long owner, long provider)
    { var item = fixture.PhotoJson(); item["owner_user_id"] = owner; item["additional"]!["provider_user_id"] = provider; return item; }
    private static JsonObject Folder(long id, long parent) => new()
    { ["id"] = id, ["parent"] = parent, ["name"] = "/Synthetic", ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true } } };
    private static HttpResponseMessage Binary()
    {
        var result = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([0xff, 0xd8, 0xff, 1, 2, 3, 4, 5]) };
        result.Content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg"); return result;
    }
}
