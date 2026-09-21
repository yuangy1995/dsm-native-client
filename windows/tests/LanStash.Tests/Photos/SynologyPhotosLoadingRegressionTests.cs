using System.Text.Json.Nodes;
using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;
using static LanStash.Tests.SynologyPhotosHttpFixture;

namespace LanStash.Tests;

public sealed class SynologyPhotosLoadingRegressionTests
{
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
    }
}
