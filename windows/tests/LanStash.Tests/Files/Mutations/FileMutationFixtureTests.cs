using System.Text.Json.Nodes;

namespace LanStash.Tests.Files.Mutations;

public sealed class FileMutationFixtureTests
{
    [Theory]
    [InlineData("contracts/request-fixtures/file-station/create-folder/synthetic-folder/request.json", "SYNO.FileStation.CreateFolder", "create")]
    [InlineData("contracts/request-fixtures/file-station/rename/synthetic-item/request.json", "SYNO.FileStation.Rename", "rename")]
    public void FixedV2FixturesDeclareReadbackAndZeroAutomaticRetry(string relative,
        string apiName, string method)
    {
        var fixture = JsonNode.Parse(File.ReadAllText(Find(relative)))!.AsObject();
        Assert.Equal(apiName, fixture["api"]!["name"]!.GetValue<string>());
        Assert.Equal(2, fixture["api"]!["resolvedVersion"]!.GetValue<int>());
        Assert.Equal(method, fixture["api"]!["method"]!.GetValue<string>());
        Assert.Equal("queryStateBeforeDecision", fixture["policy"]!["retryPolicy"]!.GetValue<string>());
        Assert.Equal("required", fixture["policy"]!["readbackPolicy"]!.GetValue<string>());
    }

    private static string Find(string relative)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, relative);
            if (File.Exists(path)) return path;
        }
        throw new FileNotFoundException(relative);
    }
}
