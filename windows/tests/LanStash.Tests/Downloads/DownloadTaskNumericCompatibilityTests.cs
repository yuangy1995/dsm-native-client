using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Tests.Downloads;

public sealed class DownloadTaskNumericCompatibilityTests
{
    [Fact]
    public async Task TaskListAcceptsDecimalStringsWithoutLosingLargeByteCounts()
    {
        var task = DownloadInventoryDetailsRssTests.TaskRow();
        task["size"] = "9007199254740993";
        task["seeds"] = "12";
        task["additional"]!["transfer"] = new JsonObject
        {
            ["size_downloaded"] = "4294967297",
            ["size_uploaded"] = "20",
            ["speed_download"] = "0",
            ["speed_upload"] = "128",
        };
        using var fixture = new DownloadInventoryDetailsRssTests.Fixture(_ => Page(task));

        var page = await fixture.Repository.ListTasksAsync(0, 100);
        var result = Assert.Single(page.Tasks);

        Assert.Equal(9007199254740993L, result.Size);
        Assert.Equal(4294967297L, result.Downloaded);
        Assert.Equal(20L, result.Uploaded);
        Assert.Equal(0L, result.DownloadSpeed);
        Assert.Equal(128L, result.UploadSpeed);
        Assert.Equal(12, result.AdvancedDetails.Seeds);
        Assert.False(page.HasMore);
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task ExplicitNullTaskStatisticsRemainUnknownAndDoNotHideTheTask()
    {
        var task = DownloadInventoryDetailsRssTests.TaskRow();
        task["size"] = null;
        task["seeds"] = null;
        task["additional"]!["transfer"] = new JsonObject
        {
            ["size_downloaded"] = null,
            ["size_uploaded"] = null,
            ["speed_download"] = null,
            ["speed_upload"] = 0,
        };
        using var fixture = new DownloadInventoryDetailsRssTests.Fixture(_ => Page(task));

        var result = Assert.Single((await fixture.Repository.ListTasksAsync(0, 100)).Tasks);

        Assert.Null(result.Size);
        Assert.Null(result.Downloaded);
        Assert.Null(result.Uploaded);
        Assert.Null(result.DownloadSpeed);
        Assert.Equal(0L, result.UploadSpeed);
        Assert.Null(result.AdvancedDetails.Seeds);
    }

    [Fact]
    public async Task TaskDetailsAcceptDecimalByteCountsAndOptionalNullStatistics()
    {
        var task = DownloadInventoryDetailsRssTests.TaskRow();
        task["additional"]!["file"] = new JsonArray(new JsonObject
        {
            ["filename"] = "synthetic.bin", ["size"] = "4294967297", ["size_downloaded"] = "16",
        });
        task["additional"]!["tracker"] = new JsonArray(new JsonObject
        {
            ["url"] = "https://tracker.invalid/announce", ["seeds"] = "12", ["peers"] = null,
        });
        task["additional"]!["peer"] = new JsonArray(new JsonObject
        {
            ["address"] = "peer.invalid", ["speed_download"] = "0", ["speed_upload"] = null,
        });
        using var fixture = new DownloadInventoryDetailsRssTests.Fixture(_ => Page(task));

        var result = await fixture.Repository.LoadTaskDetailsAsync("task-1");

        Assert.Equal(4294967297L, Assert.Single(result.Files!).Size);
        Assert.Equal(16L, Assert.Single(result.Files!).Downloaded);
        Assert.Equal(12, Assert.Single(result.Trackers!).Seeds);
        Assert.Null(Assert.Single(result.Trackers!).Peers);
        Assert.Equal(0L, Assert.Single(result.Peers!).DownloadSpeed);
        Assert.Null(Assert.Single(result.Peers!).UploadSpeed);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("1.5")]
    [InlineData("1e3")]
    [InlineData("9223372036854775808")]
    [InlineData("unknown")]
    public async Task InvalidNumericStringsStillRejectThePage(string value)
    {
        var task = DownloadInventoryDetailsRssTests.TaskRow();
        task["size"] = value;
        using var fixture = new DownloadInventoryDetailsRssTests.Fixture(_ => Page(task));

        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ListTasksAsync(0, 100));

        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("offset")]
    [InlineData("total")]
    public async Task NumericCompatibilityDoesNotRelaxPaginationValidation(string key)
    {
        using var fixture = new DownloadInventoryDetailsRssTests.Fixture(_ =>
        {
            var page = Page(DownloadInventoryDetailsRssTests.TaskRow());
            page[key] = key == "offset" ? "0" : "1";
            return page;
        });

        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.ListTasksAsync(0, 100));
    }

    private static JsonObject Page(JsonObject task) => new()
    {
        ["offset"] = 0, ["total"] = 1, ["tasks"] = new JsonArray(task),
    };
}
