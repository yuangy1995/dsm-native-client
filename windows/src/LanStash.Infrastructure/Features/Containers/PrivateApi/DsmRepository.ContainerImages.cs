using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static IReadOnlyList<ContainerResourceSummary> ParseContainerImages(JsonObject data)
    {
        var source = RequiredContainerObjectArray(data, ["images", "image", "data", "list"]);
        if (ContainerPageNumber(data, "total") is { } total && total != source.Count ||
            ContainerPageNumber(data, "offset") is { } offset && offset != 0) throw InvalidContainerManagerResponse();
        var result = new List<ContainerResourceSummary>();
        var keys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in source)
        {
            var id = FirstContainerString(item, "id", "image_id", "Id") ?? throw InvalidContainerManagerResponse();
            var repository = FirstContainerString(item, "repository", "name", "repo") ?? throw InvalidContainerManagerResponse();
            if (!item.ContainsKey("tags"))
            {
                // 旧只读摘要没有标签时继续展示，但不能猜测 latest 或开放删除。
                if (!keys.Add(id)) throw InvalidContainerManagerResponse();
                result.Add(new(id, repository, ContainerResourceKind.Image, ContainerOperationalState.Unknown));
                continue;
            }
            if (item["tags"] is not JsonArray tags) throw InvalidContainerManagerResponse();
            // 可写身份只接受已记录的原生字符串，不沿用只读摘要的数字/别名宽松转换。
            id = OptionalImageString(item, "id") ?? throw InvalidContainerManagerResponse();
            repository = OptionalImageString(item, "repository") ?? throw InvalidContainerManagerResponse();
            if (tags.Count == 0)
            {
                if (!keys.Add(id)) throw InvalidContainerManagerResponse();
                result.Add(new(id, repository, ContainerResourceKind.Image, ContainerOperationalState.Unknown));
            }
            foreach (var node in tags)
            {
                if (node is not JsonValue value || !value.TryGetValue<string>(out var tag) || !StableImageText(tag))
                    throw InvalidContainerManagerResponse();
                var reference = new ContainerImageReference(id, repository, tag);
                var key = JsonSerializer.Serialize(new[] { id, repository, tag });
                if (!keys.Add(key)) throw InvalidContainerManagerResponse();
                result.Add(new(key, $"{repository}:{tag}", ContainerResourceKind.Image, ContainerOperationalState.Unknown) { Image = reference });
            }
        }
        // 相同仓库/标签指向多个 ID 的清单无法绑定删除目标；裸标签以原 ID 区分。
        var addresses = result.Where(item => item.Image is { UsesIdentity: false }).Select(item => ImageAddress(item.Image!));
        if (addresses.Distinct(StringComparer.Ordinal).Count() != addresses.Count()) throw InvalidContainerManagerResponse();
        return result;
    }

    private async Task<IReadOnlyList<ContainerResourceSummary>> LoadContainerImagesAsync(CancellationToken token) =>
        ParseContainerImages(await CallInternalObservedContainerAsync(InternalObservedImageApi, "list",
            new Dictionary<string, string> { ["offset"] = "0", ["limit"] = "-1", ["show_dsm"] = "false" }, token).ConfigureAwait(false));

    private async Task<bool> ContainerImagesAreUnusedAsync(IReadOnlyList<ContainerResourceSummary> selected,
        IReadOnlyList<ContainerResourceSummary> images, CancellationToken token)
    {
        var data = await CallInternalObservedContainerAsync(InternalObservedContainerApi, "list",
            new Dictionary<string, string> { ["offset"] = "0", ["limit"] = "-1", ["type"] = "all" }, token).ConfigureAwait(false);
        var rows = RequiredContainerObjectArray(data, ["containers"]);
        if (ContainerPageNumber(data, "total") is { } total && total != rows.Count ||
            ContainerPageNumber(data, "offset") is { } offset && offset != 0) throw InvalidContainerManagerResponse();
        foreach (var row in rows)
        {
            var image = OptionalImageString(row, "Image") ?? "";
            ContainerResourceSummary? used;
            if (image.StartsWith("sha256:", StringComparison.Ordinal) || image.Contains("@sha256:", StringComparison.Ordinal))
            {
                var imageId = OptionalImageString(row, "ImageID") ?? throw InvalidContainerManagerResponse();
                var matches = images.Where(item => item.Image?.ImageId == imageId).ToArray();
                if (matches.Length == 0) throw InvalidContainerManagerResponse();
                var marker = image.StartsWith("sha256:", StringComparison.Ordinal) ? image : ":" + ImageTag(image.Split('@')[0]);
                used = matches.FirstOrDefault(item => item.Name.Contains(marker, StringComparison.Ordinal) ||
                    item.Image is { UsesIdentity: true } bare && bare.ImageId.Contains(marker, StringComparison.Ordinal)) ?? matches[0];
            }
            else
            {
                var name = OptionalImageString(row, "image") ?? throw InvalidContainerManagerResponse();
                used = images.FirstOrDefault(item => item.Image is { } reference && ImageAddress(reference) == NormalizeImageName(name));
            }
            if (used is not null && selected.Any(item => item.Id == used.Id ||
                item.Image is { UsesIdentity: true } reference && reference.ImageId == used.Image?.ImageId)) return false;
        }
        return true;
    }

    private static string? OptionalImageString(JsonObject row, string key)
    {
        if (!row.ContainsKey(key)) return null;
        if (row[key] is JsonValue value && value.TryGetValue<string>(out var text) && StableImageText(text)) return text;
        throw InvalidContainerManagerResponse();
    }
    private static string ImageAddress(ContainerImageReference image) => NormalizeImageName($"{image.Repository}:{image.Tag}");
    private static bool StableImageText(string text) => !string.IsNullOrWhiteSpace(text) && text == text.Trim() && !text.Any(char.IsControl);
    private static string ImageTag(string name) => name.LastIndexOf(':') > name.LastIndexOf('/') ? name[(name.LastIndexOf(':') + 1)..] : "latest";
    private static string NormalizeImageName(string name)
    {
        foreach (var prefix in new[] { "docker.io/", "index.docker.io/" })
            if (name.StartsWith(prefix, StringComparison.Ordinal)) { name = name[prefix.Length..]; break; }
        return name.LastIndexOf(':') > name.LastIndexOf('/') ? name : name + ":latest";
    }
}
