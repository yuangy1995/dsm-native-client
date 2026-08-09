using System.Text.Json.Nodes;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveFixtureTests
{
    [Theory]
    [InlineData("copy", "false")]
    [InlineData("move", "true")]
    public void NoOverwriteFixturesFreezePublicV3Wire(string operation, string removeSource)
    {
        var fixture = JsonNode.Parse(ReadRepositoryFile(
            $"contracts/request-fixtures/file-station/{operation}/synthetic-no-overwrite/request.json"))!
            .AsObject();
        var api = fixture["api"]!.AsObject();
        var transport = fixture["transport"]!.AsObject();
        var parameters = fixture["parameters"]!.AsArray()
            .Select(node => node!.AsObject())
            .ToDictionary(node => node["name"]!.GetValue<string>(),
                node => node["encodedValue"]!.GetValue<string>(), StringComparer.Ordinal);

        Assert.Equal("SYNO.FileStation.CopyMove", api["name"]!.GetValue<string>());
        Assert.Equal("start", api["method"]!.GetValue<string>());
        Assert.Equal(3, api["resolvedVersion"]!.GetValue<int>());
        Assert.Equal("POST", transport["httpMethod"]!.GetValue<string>());
        Assert.Equal("form", transport["requestFormat"]!.GetValue<string>());
        Assert.Equal("false", parameters["overwrite"]);
        Assert.Equal(removeSource, parameters["remove_src"]);
        Assert.Equal("true", parameters["accurate_progress"]);
    }

    private static string ReadRepositoryFile(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }
}
