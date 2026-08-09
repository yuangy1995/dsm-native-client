using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class PhotoSchemaContractTests
{
    [Fact]
    public void DomainModelsSerializeToSharedPhotoSchemaShape()
    {
        var profileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var item = new PhotoItem(
            profileId,
            "synthetic-item",
            "image.jpg",
            "/photo/image.jpg",
            PhotoItemKind.Image,
            42,
            DateTimeOffset.Parse("2026-01-02T03:04:05Z"),
            null,
            "jpg",
            null);
        var page = new PhotoPage(
            profileId,
            "/photo",
            [item],
            7,
            11,
            20,
            true);

        var spaceJson = JsonSerializer.SerializeToNode(PhotoSpace.Shared)!.AsObject();
        var itemJson = JsonSerializer.SerializeToNode(item)!.AsObject();
        var pageJson = JsonSerializer.SerializeToNode(page)!.AsObject();

        Assert.Equal(new[] { "id", "rootPath", "title" }, spaceJson.Select(pair => pair.Key).Order());
        Assert.Equal("shared", spaceJson["id"]!.GetValue<string>());
        Assert.Equal("/photo", spaceJson["rootPath"]!.GetValue<string>());
        Assert.Equal(
            new[]
            {
                "createdAt", "extension", "id", "kind", "modifiedAt", "name",
                "path", "sizeBytes", "thumbnailAvailable",
            },
            itemJson.Select(pair => pair.Key).Order());
        Assert.Equal("image", itemJson["kind"]!.GetValue<string>());
        Assert.False(itemJson.ContainsKey("profileId"));
        Assert.Equal(
            new[] { "folderPath", "hasMore", "items", "nextOffset", "offset", "sourceTotal" },
            pageJson.Select(pair => pair.Key).Order());
        Assert.False(pageJson.ContainsKey("profileId"));
    }

    [Fact]
    public void SharedSchemasKeepRawOffsetPaginationAndClosedProperties()
    {
        var contracts = ContractsRoot();
        var page = ReadObject(Path.Combine(contracts, "schemas", "photo-page.schema.json"));
        var item = ReadObject(Path.Combine(contracts, "schemas", "photo-item.schema.json"));
        var space = ReadObject(Path.Combine(contracts, "schemas", "photo-space.schema.json"));

        Assert.False(page["additionalProperties"]!.GetValue<bool>());
        Assert.Equal(
            new[] { "folderPath", "hasMore", "items", "nextOffset", "offset", "sourceTotal" },
            Required(page));
        Assert.Equal("photo-item.schema.json", page["properties"]!["items"]!["items"]!["$ref"]!.GetValue<string>());
        Assert.False(item["additionalProperties"]!.GetValue<bool>());
        Assert.Equal(new[] { "id", "kind", "name", "path" }, Required(item));
        Assert.Equal(
            new[] { "folder", "image", "video" },
            item["properties"]!["kind"]!["enum"]!.AsArray()
                .Select(value => value!.GetValue<string>()));
        Assert.False(space["additionalProperties"]!.GetValue<bool>());
        Assert.Equal(new[] { "id", "rootPath", "title" }, Required(space));
    }

    [Fact]
    public void ThumbnailRequestFixtureIsPublicSyntheticAndHeaderAuthenticated()
    {
        var fixturePath = Path.Combine(
            ContractsRoot(),
            "request-fixtures",
            "photos",
            "get-thumbnail",
            "synthetic-image",
            "request.json");
        var fixtureText = File.ReadAllText(fixturePath);
        var fixture = JsonNode.Parse(fixtureText)!.AsObject();

        Assert.Equal("SYNO.FileStation.Thumb", fixture["api"]!["name"]!.GetValue<string>());
        Assert.Equal("get", fixture["api"]!["method"]!.GetValue<string>());
        Assert.Equal(2, fixture["api"]!["preferredVersion"]!.GetValue<int>());
        Assert.Equal("GET", fixture["transport"]!["httpMethod"]!.GetValue<string>());
        Assert.Equal(
            new[] { "path", "rotate", "size" },
            fixture["parameters"]!.AsArray()
                .Select(value => value!["name"]!.GetValue<string>())
                .Order());
        Assert.Equal(
            new[] { "cookie" },
            fixture["authentication"]!["sessionLocations"]!.AsArray()
                .Select(value => value!.GetValue<string>()));
        Assert.Equal(
            new[] { "header" },
            fixture["authentication"]!["synoTokenLocations"]!.AsArray()
                .Select(value => value!.GetValue<string>()));
        Assert.DoesNotContain("_sid", fixtureText, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("synthetic-sid", fixtureText, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("synthetic-token", fixtureText, StringComparison.OrdinalIgnoreCase);
    }

    private static IReadOnlyList<string> Required(JsonObject schema) =>
        schema["required"]!.AsArray()
            .Select(value => value!.GetValue<string>())
            .Order()
            .ToArray();

    private static JsonObject ReadObject(string path) =>
        JsonNode.Parse(File.ReadAllText(path))!.AsObject();

    private static string ContractsRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory is not null;
             directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "contracts");
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        throw new DirectoryNotFoundException("Repository contracts directory was not found.");
    }
}
