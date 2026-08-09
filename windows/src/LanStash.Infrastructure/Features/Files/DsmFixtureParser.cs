using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

internal static class DsmFixtureParser
{
    /// <summary>
    /// 将 File Station 列表数据转换为稳定领域语义，供生产请求和脱敏 Fixture 共用。
    /// </summary>
    public static FilePage ParseFilePage(JsonObject data, string root = "files")
    {
        var items = data.Array(root).OfType<JsonObject>().Select(item =>
        {
            var additional = item.Object("additional");
            var time = additional?.Object("time");
            var permission = additional?.Object("perm");
            return new FileItem(
                item.String("path") ?? string.Empty,
                item.String("name") ?? item.String("path")?.Split('/').Last() ?? UserText.Key("WinShared79f326be4409d51f"),
                item.Bool("isdir") ?? false,
                item.Bool("isdir") == true
                    ? 0
                    : item.Long("size") ?? additional?.Long("size") ?? -1,
                time?.Date("mtime") ?? item.Date("mtime"),
                additional?.Object("owner")?.String("user") ?? additional?.String("owner"),
                permission?.Bool("write") ?? false,
                permission?.Bool("delete") ?? false);
        }).Where(item => !string.IsNullOrWhiteSpace(item.Path)).ToArray();
        return new FilePage(
            items,
            data.Int("total") ?? items.Length,
            data.Int("offset") ?? 0);
    }
}

public sealed partial class DsmRepository
{
    private FilePage ParseFilePage(JsonObject data, string root)
        => DsmFixtureParser.ParseFilePage(data, root);
}
