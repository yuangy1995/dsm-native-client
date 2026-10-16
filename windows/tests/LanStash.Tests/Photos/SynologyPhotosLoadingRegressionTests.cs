using System.Text.Json.Nodes;
using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotosLoadingRegressionTests
{
    [Theory]
    [InlineData(1001L)]
    [InlineData(1788220900123L)]
    public async Task IndexTimestampAlwaysUsesMillisecondsAndPreservesTheirPrecision(long indexedMilliseconds)
    {
        using var fixture = new SynologyPhotosHttpFixture();
        var item = fixture.PhotoJson(); item["indexed_time"] = indexedMilliseconds;
        fixture.Respond = (_, _) => Task.FromResult(Json(List((JsonObject)item.DeepClone())));
        var repository = fixture.Repository(); await repository.AccessAsync();

        var photo = Assert.Single((await repository.PhotosAsync(new SynologyPhotoQuery.Recent(), 0, 100)).Items);

        Assert.Equal(fixture.Photo.TakenAt, photo.TakenAt);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(indexedMilliseconds), photo.IndexedAt);
        Assert.Equal(indexedMilliseconds, photo.IndexedAt.ToUnixTimeMilliseconds());
    }

    [Theory]
    [InlineData(0L)]
    [InlineData(1L)]
    public async Task OriginalFileReviewPreservesOneMillisecondIdentityChanges(long changedMilliseconds)
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (request, _) =>
        {
            if (request.Api == "SYNO.Foto.Browse.Folder") return Task.FromResult(Json(new JsonObject
            {
                ["folder"] = new JsonObject { ["id"] = 3, ["parent"] = 1, ["name"] = "/synthetic",
                    ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = true, ["manage"] = true } } },
            }));
            var item = fixture.PhotoJson(); item["indexed_time"] = fixture.Photo.IndexedAt.ToUnixTimeMilliseconds() + changedMilliseconds;
            return Task.FromResult(Json(List(item)));
        };
        var repository = fixture.Repository(delete: true); await repository.AccessAsync();

        if (changedMilliseconds == 0) await repository.PrepareDeletionAsync(fixture.Photo);
        else Assert.Equal(SynologyPhotoFailure.TargetChanged,
            (await Assert.ThrowsAsync<SynologyPhotoException>(() => repository.PrepareDeletionAsync(fixture.Photo))).Failure);

        Assert.DoesNotContain(fixture.Requests, request => request.Method is "delete" or "move" or "copy");
    }

    [Fact]
    public async Task ObservedSettingsShapeLoadsThroughProductionPhotoTransport()
    {
        using var fixture = new SynologyPhotosHttpFixture();
        // 只复现已观察的字段结构；身份、版本与媒体内容全部为合成值。
        fixture.AccessResponse = api => api switch
        {
            "SYNO.Foto.UserInfo" => new() { ["enabled"] = true, ["id"] = 19, ["uid"] = 1024, ["is_admin"] = true },
            "SYNO.Foto.Setting.User" => new()
            {
                ["enable_home_service"] = true, ["team_space_permission"] = "none",
                ["timeline_group_unit"] = "day", ["date_format"] = "yyyy-mm-dd", ["time_format"] = "24",
                ["item_sort_by"] = "takentime", ["sort_direction"] = "asc", ["show_item_info_in_lightbox"] = true,
                ["copy_move_default_action"] = "overwrite", ["upload_default_action"] = "ignore", ["theme"] = "auto",
                ["ame_status"] = new JsonObject { ["has_h264"] = true, ["has_hevc"] = true, ["has_vc1"] = false },
            },
            "SYNO.Foto.Setting.Admin" => new() { ["package_version"] = "synthetic", ["enable_person"] = true, ["enable_concept"] = true },
            "SYNO.Foto.Setting.TeamSpace" => new() { ["enabled"] = false, ["team_space_disabled_by_share_folder_disabled"] = false },
            _ => null,
        };
        fixture.Respond = (request, _) => Task.FromResult(Json(request.Api == "SYNO.Foto.Browse.Timeline"
            ? new JsonObject { ["section"] = new JsonArray(new JsonObject { ["offset"] = 0, ["limit"] = 1,
                ["list"] = new JsonArray(new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = 1 }) }) }
            : List(fixture.PhotoJson())));
        using var model = new SynologyPhotosWorkspace(fixture.Repository());

        await model.RefreshAsync();

        Assert.Null(model.ErrorKey);
        Assert.True(model.HasLoaded);
        Assert.True(model.CanRefreshChanges);
        Assert.Single(model.Items);
        Assert.Equal(SynologyPhotoSpace.Personal, Assert.Single(model.Spaces));
        Assert.NotNull(model.DisplaySettings);
        Assert.Collection(fixture.Requests,
            request => Assert.Equal(("SYNO.Foto.UserInfo", 1, "me"), (request.Api, request.Version, request.Method)),
            request => Assert.Equal(("SYNO.Foto.Setting.User", 1, "get"), (request.Api, request.Version, request.Method)),
            request => Assert.Equal(("SYNO.Foto.Setting.Admin", 1, "get"), (request.Api, request.Version, request.Method)),
            request => Assert.Equal(("SYNO.Foto.Setting.TeamSpace", 1, "get"), (request.Api, request.Version, request.Method)),
            request => Assert.Equal(("SYNO.Foto.Browse.Timeline", 5, "get"), (request.Api, request.Version, request.Method)),
            request => Assert.Equal(("SYNO.Foto.Browse.Item", 4, "list"), (request.Api, request.Version, request.Method)));
        Assert.All(fixture.Requests, request =>
        {
            Assert.Equal($"/webapi/entry.cgi/{request.Api}", request.Uri.AbsolutePath);
            Assert.Equal(System.Net.Http.HttpMethod.Post, request.HttpMethod);
            Assert.Equal("synthetic-token", request.Values["SynoToken"]);
            Assert.Empty(request.Uri.Query);
        });
    }

    [Fact]
    public async Task FailedAccessDoesNotStartChangeRecoveryAndRetryRestoresIt()
    {
        using var fixture = new SynologyPhotosHttpFixture { Enabled = false };
        fixture.Respond = (_, _) => Task.FromResult(Json(new JsonObject { ["section"] = new JsonArray() }));
        using var model = new SynologyPhotosWorkspace(fixture.Repository());

        Assert.False(model.CanRefreshChanges);
        await model.RefreshAsync();
        Assert.Equal("PhotosServicePermission", model.ErrorKey);
        Assert.False(model.HasAccess);
        Assert.False(model.CanRefreshChanges);

        fixture.Enabled = true;
        await model.RefreshAsync();
        Assert.Null(model.ErrorKey);
        Assert.True(model.HasLoaded);
        Assert.True(model.HasAccess);
        Assert.True(model.CanRefreshChanges);

        model.Suspend();
        Assert.False(model.CanRefreshChanges);
    }

    [Fact]
    public async Task LibraryFailureKeepsAuthorizedRecoveryAvailableButRefreshRevokesIt()
    {
        using var fixture = new SynologyPhotosHttpFixture();
        var timeline = new TaskCompletionSource<System.Net.Http.HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var requested = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Respond = (_, _) => { requested.TrySetResult(); return timeline.Task; };
        using var model = new SynologyPhotosWorkspace(fixture.Repository());
        var loading = model.RefreshAsync();
        await Task.WhenAny(requested.Task, loading);
        Assert.True(requested.Task.IsCompletedSuccessfully);
        Assert.True(model.HasAccess);
        Assert.True(model.IsLoading);
        Assert.False(model.CanRefreshChanges);

        timeline.SetResult(Json(new JsonObject()));
        await loading;
        Assert.False(model.HasLoaded);
        Assert.NotNull(model.ErrorKey);
        Assert.True(model.CanRefreshChanges);

        fixture.Enabled = false;
        await model.RefreshAsync();
        Assert.False(model.HasAccess);
        Assert.False(model.CanRefreshChanges);
    }

    [Theory]
    [InlineData("timeline")]
    [InlineData("search")]
    [InlineData("filter")]
    public async Task EpochCalendarDayLoadsThroughTheRealRepository(string mode)
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (request, _) => Task.FromResult(Json(
            request.Method is "get" or "get_search_timeline" or "get_with_filter"
                ? new JsonObject { ["section"] = new JsonArray(new JsonObject { ["list"] = new JsonArray(
                    new JsonObject { ["year"] = 1970, ["month"] = 1, ["day"] = 1, ["item_count"] = 1 },
                    new JsonObject { ["year"] = 2026, ["month"] = 9, ["day"] = 1, ["item_count"] = 1 }) }) }
                : List(fixture.PhotoJson())));
        using var model = new SynologyPhotosWorkspace(fixture.Repository());
        if (mode == "search") await model.SearchAsync("synthetic");
        else if (mode == "filter") await model.ApplyFilterAsync(new() { Rating = 3 });
        else await model.RefreshAsync();

        Assert.Null(model.ErrorKey);
        Assert.True(model.HasLoaded);
        Assert.Single(model.Items);
        var call = fixture.Requests[^1];
        var start = mode == "filter"
            ? JsonNode.Parse(call.Values["time"])![0]!["start_time"]!.GetValue<long>()
            : long.Parse(call.Values["start_time"], System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(0, start);
    }

    [Fact]
    public async Task InitialRangeMatchesMacCalendarCoverageRatherThanClientTimezone()
    {
        var repository = new SynologyPhotosTestRepository { Days = [new(new(2026, 9, 1), 1)] };
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync();
        var query = Assert.IsType<SynologyPhotoQuery.Timeline>(Assert.Single(repository.Calls).Query);
        var utcDay = new DateTimeOffset(2026, 9, 1, 0, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds();
        Assert.Equal(utcDay - 86400, query.Start);
        Assert.Equal(utcDay + 172800, query.End);
    }

    [Theory]
    [InlineData(106, "PhotosSessionExpired")]
    [InlineData(107, "PhotosSessionExpired")]
    [InlineData(119, "PhotosSessionExpired")]
    [InlineData(105, "PhotosServicePermission")]
    [InlineData(104, "PhotosServiceUnavailable")]
    public async Task RealEnvelopeFailureOffersTheCorrectRecovery(int code, string key)
    {
        using var fixture = new SynologyPhotosHttpFixture();
        fixture.Respond = (_, _) => Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK)
        {
            Content = new StringContent(new JsonObject
            {
                ["success"] = false, ["error"] = new JsonObject { ["code"] = code },
            }.ToJsonString(), System.Text.Encoding.UTF8, "application/json"),
        });
        using var model = new SynologyPhotosWorkspace(fixture.Repository());
        await model.RefreshAsync();
        Assert.Equal(key, model.ErrorKey);
        Assert.False(model.HasLoaded);
        Assert.Empty(model.Items);
        if (key == "PhotosSessionExpired") Assert.False(model.CanRefreshChanges);
    }
}
