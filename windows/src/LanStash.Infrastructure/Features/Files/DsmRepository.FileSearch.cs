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
        request.Validate();
        if (!request.HasConditions) return new([], 0, false);
        var matcher = request.CreateNameRegex();
        var folders = await ResolveSearchFoldersAsync(request.FolderPath, cancellationToken).ConfigureAwait(false);
        if (folders.Count == 0) return new([], 0, false);

        // 公开 v2 要求路径数组；只提交一次 start，不因网络错误自动重建搜索任务。
        var parameters = new Dictionary<string, string>
        {
            ["folder_path"] = JsonSerializer.Serialize(folders),
            ["pattern"] = SearchString(matcher is not null || string.IsNullOrWhiteSpace(request.Query) ? "*" : request.Query),
            ["recursive"] = request.Recursive ? "true" : "false",
            ["filetype"] = SearchString(request.Kind switch { FileListTypeFilter.Files => "file", FileListTypeFilter.Folders => "dir", _ => "all" }),
        };
        AddText("extension", request.Extension);
        AddText("owner", request.Owner);
        AddText("group", request.Group);
        AddNumber("size_from", request.MinimumBytes);
        AddNumber("size_to", request.MaximumBytes);
        AddRange("mtime", request.Modified);
        AddRange("crtime", request.Created);
        AddRange("atime", request.Accessed);
        if (request.SearchesContents)
        {
            // 内部只读扩展；不能将正文搜索失败降级为名称搜索后返回空结果。
            parameters["search_content"] = "true";
            parameters["search_type"] = SearchString("advance");
        }
        var start = await CallFileSearchAsync("start", parameters, cancellationToken).ConfigureAwait(false);
        var taskId = start.String("taskid");
        if (string.IsNullOrWhiteSpace(taskId))
            throw new DsmException(UserText.Key("WinShared17bab1054ab28010"), UserText.Key("WinSharedefc81ced18eb3bb0"));

        var completed = false;
        try
        {
            var coverage = FileSearchIndexCoverage.NotRequested;
            if (request.SearchesContents)
            {
                if (start["has_not_index_share"] is not JsonValue index || !index.TryGetValue<bool>(out var incomplete))
                    throw new NotSupportedException("file.search.content-unavailable");
                coverage = incomplete ? FileSearchIndexCoverage.Incomplete : FileSearchIndexCoverage.Complete;
            }
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
            // 正则仅在完整名称结果上执行，正文结果不能再按名称剔除。
            var matches = matcher is null ? items : items.Where(item => matcher.IsMatch(item.Name)).ToList();
            cancellationToken.ThrowIfCancellationRequested();
            completed = true;
            return new(matches, matches.Count, false) { IndexCoverage = coverage };
        }
        finally
        {
            try
            {
                // 成功释放结果；失败/取消停止本次任务。独立清理不继承已取消的 UI 令牌。
                using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await CallFileSearchAsync(completed ? "clean" : "stop",
                    new Dictionary<string, string> { ["taskid"] = SearchString(taskId) },
                    cleanup.Token).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // 清理失败不覆盖用户已获得的结果、取消或原始错误，也不声称 NAS 已清理。
            }
        }

        void AddText(string key, string value)
        {
            if (!string.IsNullOrWhiteSpace(value)) parameters[key] = SearchString(value);
        }
        void AddNumber(string key, long? value)
        {
            if (value.HasValue) parameters[key] = value.Value.ToString(CultureInfo.InvariantCulture);
        }
        void AddRange(string prefix, FileSearchTimeRange range)
        {
            AddNumber(prefix + "_from", range.From?.ToUnixTimeSeconds());
            AddNumber(prefix + "_to", range.To?.ToUnixTimeSeconds());
        }
    }

    private async Task<IReadOnlyList<string>> ResolveSearchFoldersAsync(string folder, CancellationToken token)
    {
        if (!string.IsNullOrWhiteSpace(folder) && folder != "/")
        {
            if (!folder.StartsWith('/') || folder.Split('/').Any(part => part is "." or ".."))
                throw new ArgumentException("file.search.invalid-folder");
            return [folder];
        }
        // DSM 搜索不接受虚拟共享根，先完整读取当前账号实际可见的共享。
        var folders = new List<string>();
        var paths = new HashSet<string>(StringComparer.Ordinal);
        int? total = null;
        var offset = 0;
        while (true)
        {
            var page = await ListFilesAsync(string.Empty, offset, FileSearchPageSize, token).ConfigureAwait(false);
            if (page.Offset != offset || page.Total < offset + page.Items.Count ||
                total is not null && total != page.Total || page.Items.Count == 0 && page.Total > offset ||
                page.Items.Any(item => !item.IsDirectory || !paths.Add(item.Path)))
                throw new InvalidDataException("file.search.invalid-shares");
            total ??= page.Total;
            folders.AddRange(page.Items.Select(item => item.Path));
            offset = checked(offset + page.Items.Count);
            if (offset == total) return folders;
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
