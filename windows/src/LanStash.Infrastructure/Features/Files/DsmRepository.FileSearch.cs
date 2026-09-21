using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int FileSearchPageSize = 2000;
    private const int FileSearchVersion = 2;

    bool IFileSearchRepository.IsSearchAvailable => HasFileSearchContract;
    Guid IFileSearchRepository.ProfileId => ProfileId;

    private bool HasFileSearchContract =>
        _capabilities.TryGetValue("SYNO.FileStation.Search", out var capability) &&
        capability.Name == "SYNO.FileStation.Search" &&
        capability.MinVersion <= FileSearchVersion && capability.MaxVersion >= FileSearchVersion &&
        (capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
         capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

    async Task<FileSearchResult> IFileSearchRepository.SearchAsync(
        FileSearchRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();
        if (_profile.Id != _session.ProfileId) throw new InvalidOperationException("file.search.profile-mismatch");
        if (!HasFileSearchContract) throw new NotSupportedException("file.search.unsupported");
        if (string.IsNullOrWhiteSpace(request.Query)) return new([], 0, false);

        var folderPath = string.IsNullOrWhiteSpace(request.FolderPath) ? "/" : request.FolderPath;
        // 公开 v2 要求路径数组；只提交一次 start，不因网络错误自动重建搜索任务。
        var start = await CallFileSearchAsync("start", new Dictionary<string, string>
        {
            ["folder_path"] = JsonSerializer.Serialize(new[] { folderPath }),
            ["pattern"] = SearchString(request.Query),
            ["recursive"] = request.Recursive ? "true" : "false",
        }, cancellationToken).ConfigureAwait(false);
        var taskId = start.String("taskid");
        if (string.IsNullOrWhiteSpace(taskId))
            throw new DsmException(UserText.Key("WinShared17bab1054ab28010"), UserText.Key("WinSharedefc81ced18eb3bb0"));

        var completed = false;
        try
        {
            await PollSearchTaskAsync(taskId, cancellationToken).ConfigureAwait(false);
            var items = new List<FileItem>();
            var paths = new HashSet<string>(StringComparer.Ordinal);
            int? stableTotal = null;
            var offset = 0;
            while (true)
            {
                var result = await CallFileSearchAsync("list", new Dictionary<string, string>
                {
                    ["taskid"] = SearchString(taskId),
                    ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                    ["limit"] = FileSearchPageSize.ToString(CultureInfo.InvariantCulture),
                    ["additional"] = "[\"size\",\"owner\",\"time\",\"perm\"]",
                }, cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                if (result["files"] is not JsonArray files) throw new InvalidDataException("file.search.missing-files");
                var total = SearchRequiredInt(result, "total");
                if (SearchRequiredInt(result, "offset") != offset || files.Count > FileSearchPageSize ||
                    (stableTotal is not null && stableTotal != total) || files.Count > total - offset)
                    throw new InvalidDataException("file.search.invalid-pagination");
                stableTotal ??= total;

                // 与普通文件列表共用元数据解析，不再丢失 additional.size/owner/time/perm。
                var page = ParseFilePage(result, "files", offset, FileSearchPageSize);
                if (page.Items.Count != files.Count || page.Items.Any(item => !paths.Add(item.Path)))
                    throw new InvalidDataException("file.search.invalid-items");
                items.AddRange(page.Items);
                offset = checked(offset + files.Count);
                if (offset == total) break;
                if (files.Count == 0) throw new InvalidDataException("file.search.non-progress");
            }
            completed = true;
            return new(items, items.Count, false);
        }
        finally
        {
            try
            {
                // 成功释放结果；失败/取消停止本次任务。独立清理不继承已取消的 UI 令牌。
                await CallFileSearchAsync(completed ? "clean" : "stop",
                    new Dictionary<string, string> { ["taskid"] = SearchString(taskId) },
                    CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // 清理失败不覆盖用户已获得的结果、取消或原始错误，也不声称 NAS 已清理。
            }
        }
    }

    private async Task PollSearchTaskAsync(string taskId, CancellationToken cancellationToken)
    {
        var delayMs = 250;
        while (true)
        {
            var status = await CallFileSearchAsync("list", new Dictionary<string, string>
            {
                ["taskid"] = SearchString(taskId), ["offset"] = "0", ["limit"] = "1",
            }, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            if (status["finished"] is not JsonValue value || !value.TryGetValue<bool>(out var finished))
                throw new InvalidDataException("file.search.invalid-status");
            if (finished) return;
            // files 可包含未完成的部分结果；只有 finished=true 才可进入结果分页。
            await Task.Delay(delayMs, cancellationToken).ConfigureAwait(false);
            delayMs = Math.Min(delayMs * 2, 1000);
        }
    }

    private Task<JsonObject> CallFileSearchAsync(string method, IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = _capabilities["SYNO.FileStation.Search"];
        return _api.CallAsync(_profile, _session,
            capability with { MinVersion = FileSearchVersion, MaxVersion = FileSearchVersion },
            method, parameters, cancellationToken);
    }

    private string SearchString(string value) =>
        _capabilities["SYNO.FileStation.Search"].RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
            ? JsonSerializer.Serialize(value) : value;

    private static int SearchRequiredInt(JsonObject value, string key)
    {
        if (value[key] is JsonValue node && node.TryGetValue<int>(out var result) && result >= 0) return result;
        throw new InvalidDataException("file.search.invalid-integer");
    }
}
