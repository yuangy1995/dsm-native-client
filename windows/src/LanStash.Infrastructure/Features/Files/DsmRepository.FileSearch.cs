using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileSearchPageSize = 2000;
    private const int FileSearchResultLimit = 2000;
    private const int FileSearchMaxPollAttempts = 12;

    bool IFileSearchRepository.IsSearchAvailable =>
        Supports("SYNO.FileStation.Search");

    Guid IFileSearchRepository.ProfileId => ProfileId;

    async Task<FileSearchResult> IFileSearchRepository.SearchAsync(
        FileSearchRequest request,
        CancellationToken cancellationToken)
    {
        if (!Supports("SYNO.FileStation.Search"))
        {
            throw new NotSupportedException("File search is not available on this NAS.");
        }

        if (string.IsNullOrWhiteSpace(request.Query))
        {
            return new FileSearchResult([], 0, false);
        }

        var folderPath = string.IsNullOrWhiteSpace(request.FolderPath)
            ? "/"
            : request.FolderPath;

        // 第一步：启动搜索任务。
        var start = await CallAsync(
            "SYNO.FileStation.Search",
            "start",
            new Dictionary<string, string>
            {
                ["folder_path"] = folderPath,
                ["pattern"] = request.Query,
                ["recursive"] = request.Recursive ? "true" : "false",
            },
            cancellationToken).ConfigureAwait(false);

        var taskId = start.String("taskid")
            ?? throw new DsmException(
                UserText.Key("WinShared17bab1054ab28010"),
                UserText.Key("WinSharedefc81ced18eb3bb0"));

        try
        {
            // 第二步：按指数退避轮询，直到搜索结束。
            await PollSearchTaskAsync(taskId, cancellationToken).ConfigureAwait(false);

            // 第三步：列出所有结果页。
            var items = new List<FileItem>();
            var offset = 0;
            int? stableTotal = null;
            var truncated = false;

            while (offset < FileSearchResultLimit)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var requestLimit = Math.Min(FileSearchPageSize, FileSearchResultLimit - offset);
                var result = await CallAsync(
                    "SYNO.FileStation.Search",
                    "list",
                    new Dictionary<string, string>
                    {
                        ["taskid"] = taskId,
                        ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                        ["limit"] = requestLimit.ToString(CultureInfo.InvariantCulture),
                        ["additional"] = "[\"size\",\"owner\",\"time\",\"perm\"]",
                    },
                    cancellationToken).ConfigureAwait(false);

                var files = result["files"] as JsonArray;
                if (files is null)
                {
                    break;
                }

                var responseOffset = SearchRequiredInt(result, "offset");
                var total = SearchRequiredInt(result, "total");
                if (responseOffset != offset || total < 0 ||
                    (stableTotal is not null && stableTotal != total))
                {
                    throw new InvalidDataException("file.search.invalid-pagination");
                }
                stableTotal ??= total;

                if (files.Count > requestLimit)
                {
                    throw new InvalidDataException("file.search.page-over-limit");
                }

                foreach (var node in files)
                {
                    if (node is not JsonObject item) continue;
                    var path = item.String("path");
                    var name = item.String("name");
                    if (path is null || name is null) continue;
                    var isDir = item.Bool("isdir") ?? false;
                    long size = 0;
                    if (!isDir && item.Long("size") is { } s)
                    {
                        size = Math.Max(s, 0);
                    }
                    var owner = item.String("owner");
                    var modified = ParseSearchTime(item);
                    var canWrite = false;
                    var canDelete = false;
                    if (item["additional"] is JsonObject additional)
                    {
                        if (additional["perm"] is JsonObject perm)
                        {
                            canWrite = perm.Bool("write") ?? false;
                            canDelete = perm.Bool("delete") ?? false;
                        }
                    }
                    items.Add(new FileItem(path, name, isDir, size, modified, owner, canWrite, canDelete));
                }

                offset = checked(offset + files.Count);
                if (files.Count == 0 || offset >= Math.Min(total, FileSearchResultLimit))
                {
                    truncated = total > FileSearchResultLimit;
                    if (total > FileSearchResultLimit)
                    {
                        // 服务端结果数超过安全上限。
                    }
                    break;
                }
            }

            if (items.Count > FileSearchResultLimit)
            {
                items = items.Take(FileSearchResultLimit).ToList();
                truncated = true;
            }

            return new FileSearchResult(items, items.Count, truncated);
        }
        finally
        {
            // 第四步：始终停止并清理搜索任务。
            try
            {
                await CallAsync(
                    "SYNO.FileStation.Search",
                    "stop",
                    new Dictionary<string, string> { ["taskid"] = taskId },
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch (DsmException)
            {
                // 停止失败不覆盖搜索结果。
            }
            catch (OperationCanceledException)
            {
                // 清理期间忽略取消信号。
            }
        }
    }

    private async Task PollSearchTaskAsync(
        string taskId,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < FileSearchMaxPollAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var delayMs = Math.Min(250 * (int)Math.Pow(2, attempt), 1000);
            await Task.Delay(delayMs, cancellationToken).ConfigureAwait(false);

            var status = await CallAsync(
                "SYNO.FileStation.Search",
                "list",
                new Dictionary<string, string>
                {
                    ["taskid"] = taskId,
                    ["offset"] = "0",
                    ["limit"] = "1",
                },
                cancellationToken).ConfigureAwait(false);

            // 响应包含 finished 或结果总数时，搜索已经完成。
            if (status.Bool("finished") == true)
            {
                return;
            }
            // 成功响应包含 files 数组时，即使为空也视为完成。
            if (status["files"] is JsonArray)
            {
                return;
            }
        }
        // 达到最大轮询次数后仍尝试列出结果，搜索可能已经完成。
    }

    private static int SearchRequiredInt(JsonObject value, string key)
    {
        if (value[key] is JsonValue node && node.TryGetValue<int>(out var result) && result >= 0)
        {
            return result;
        }
        throw new InvalidDataException("file.search.invalid-integer");
    }

    private static DateTimeOffset? ParseSearchTime(JsonObject item)
    {
        if (item.Long("mtime") is { } seconds && seconds >= 0)
        {
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        }
        if (item["additional"] is JsonObject additional)
        {
            if (additional["time"] is JsonObject time)
            {
                if (time.Long("mtime") is { } timeSeconds && timeSeconds >= 0)
                {
                    return DateTimeOffset.FromUnixTimeSeconds(timeSeconds);
                }
            }
        }
        return null;
    }
}
