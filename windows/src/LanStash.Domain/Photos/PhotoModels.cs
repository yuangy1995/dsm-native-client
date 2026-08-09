using System.Text.Json;
using System.Text.Json.Serialization;

namespace LanStash.Domain;

public static class PhotoSpaceIds
{
    public const string Personal = "personal";
    public const string Shared = "shared";
}

public sealed record PhotoSpace(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("title")] string Title,
    [property: JsonPropertyName("rootPath")] string RootPath)
{
    public static PhotoSpace Personal { get; } = new(
        PhotoSpaceIds.Personal,
        PhotoSpaceIds.Personal,
        "/home/Photos");

    public static PhotoSpace Shared { get; } = new(
        PhotoSpaceIds.Shared,
        PhotoSpaceIds.Shared,
        "/photo");
}

[JsonConverter(typeof(PhotoItemKindJsonConverter))]
public enum PhotoItemKind
{
    Folder,
    Image,
    Video,
}

public sealed class PhotoItemKindJsonConverter : JsonConverter<PhotoItemKind>
{
    public override PhotoItemKind Read(
        ref Utf8JsonReader reader,
        Type typeToConvert,
        JsonSerializerOptions options) => reader.GetString() switch
    {
        "folder" => PhotoItemKind.Folder,
        "image" => PhotoItemKind.Image,
        "video" => PhotoItemKind.Video,
        _ => throw new JsonException("Unknown photo item kind."),
    };

    public override void Write(
        Utf8JsonWriter writer,
        PhotoItemKind value,
        JsonSerializerOptions options) => writer.WriteStringValue(value switch
        {
            PhotoItemKind.Folder => "folder",
            PhotoItemKind.Image => "image",
            PhotoItemKind.Video => "video",
            _ => throw new JsonException("Unknown photo item kind."),
        });
}

public sealed record PhotoItem(
    [property: JsonIgnore] Guid ProfileId,
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("kind")] PhotoItemKind Kind,
    [property: JsonPropertyName("sizeBytes")] long? SizeBytes,
    [property: JsonPropertyName("createdAt")] DateTimeOffset? CreatedAt,
    [property: JsonPropertyName("modifiedAt")] DateTimeOffset? ModifiedAt,
    [property: JsonPropertyName("extension")] string? FileExtension,
    [property: JsonPropertyName("thumbnailAvailable")] bool? ThumbnailAvailable);

public sealed record PhotoPage(
    [property: JsonIgnore] Guid ProfileId,
    [property: JsonPropertyName("folderPath")] string FolderPath,
    [property: JsonPropertyName("items")] IReadOnlyList<PhotoItem> Items,
    [property: JsonPropertyName("offset")] int Offset,
    [property: JsonPropertyName("nextOffset")] int NextOffset,
    [property: JsonPropertyName("sourceTotal")] int SourceTotal,
    [property: JsonPropertyName("hasMore")] bool HasMore);

public sealed record PhotoTimelineLimits(
    int MaximumFolders = 2_000,
    int MaximumSourceItems = 50_000,
    int MaximumMediaItems = 10_000,
    int PageSize = 200)
{
    public static PhotoTimelineLimits Default { get; } = new();

    public void Validate()
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(MaximumFolders, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(MaximumSourceItems, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(MaximumMediaItems, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(PageSize, 1);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(PageSize, 500);
    }
}

public enum PhotoTimelineCompletion
{
    Complete,
    Truncated,
}

public sealed record PhotoTimelineSnapshot(
    Guid ProfileId,
    string SpaceId,
    IReadOnlyList<PhotoItem> Items,
    int ScannedFolderCount,
    int SkippedFolderCount,
    int SourceItemCount,
    PhotoTimelineCompletion Completion);

public enum PhotoThumbnailSize
{
    Small,
    Medium,
    Large,
}

public sealed record PhotoThumbnail(
    byte[] Bytes,
    string MediaType)
{
    public const int MaximumBytes = 10 * 1024 * 1024;
}
