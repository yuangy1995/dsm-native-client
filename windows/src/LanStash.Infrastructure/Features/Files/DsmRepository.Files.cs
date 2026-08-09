using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<FilePage> ListFilesAsync(
        string path,
        CancellationToken cancellationToken = default) =>
        await ListFilesAsync(
            path,
            0,
            500,
            FileListOptions.Default,
            cancellationToken).ConfigureAwait(false);

    public async Task<FilePage> ListFilesAsync(
        string path,
        int offset,
        int limit,
        CancellationToken cancellationToken = default) =>
        await ListFilesAsync(
            path,
            offset,
            limit,
            FileListOptions.Default,
            cancellationToken).ConfigureAwait(false);

    public async Task<FilePage> ListFilesAsync(
        string path,
        int offset,
        int limit,
        FileListOptions options,
        CancellationToken cancellationToken = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var method = string.IsNullOrWhiteSpace(path) ? "list_share" : "list";
        var effectiveOptions = method == "list_share"
            ? options.NormalizeForSharedRoot()
            : options;
        var parameters = new Dictionary<string, string>
        {
            ["offset"] = offset.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["limit"] = Math.Min(limit, 500).ToString(
                System.Globalization.CultureInfo.InvariantCulture),
            ["sort_by"] = SortFieldValue(effectiveOptions.SortField),
            ["sort_direction"] = SortDirectionValue(effectiveOptions.SortDirection),
            ["additional"] = "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"volume_status\"]",
        };
        if (method == "list")
        {
            parameters["folder_path"] = path;
            var fileType = TypeFilterValue(effectiveOptions.TypeFilter);
            if (fileType is not null)
            {
                parameters["filetype"] = fileType;
            }
        }
        var data = await CallAsync(
            "SYNO.FileStation.List",
            method,
            parameters,
            cancellationToken).ConfigureAwait(false);
        return ParseFilePage(data, method == "list" ? "files" : "shares");
    }

    private static string SortFieldValue(FileListSortField field) => field switch
    {
        FileListSortField.Name => "name",
        FileListSortField.Size => "size",
        FileListSortField.ModifiedTime => "mtime",
        _ => throw new ArgumentOutOfRangeException(nameof(field)),
    };

    private static string SortDirectionValue(FileListSortDirection direction) => direction switch
    {
        FileListSortDirection.Ascending => "asc",
        FileListSortDirection.Descending => "desc",
        _ => throw new ArgumentOutOfRangeException(nameof(direction)),
    };

    private static string? TypeFilterValue(FileListTypeFilter filter) => filter switch
    {
        FileListTypeFilter.All => null,
        FileListTypeFilter.Files => "file",
        FileListTypeFilter.Folders => "dir",
        _ => throw new ArgumentOutOfRangeException(nameof(filter)),
    };

    public async Task<byte[]> ReadFileRangeAsync(
        string remotePath,
        long offset,
        long length,
        CancellationToken cancellationToken = default)
    {
        var result = await ReadFileRangeResultAsync(
            remotePath,
            offset,
            length,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (result.RequestedStart != 0 || result.RequestedLength != result.TotalLength)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnsafeSegmentedRead,
                "The byte-array compatibility API cannot prove consistency across multiple ranges.",
                result.StatusCode);
        }
        return result.Bytes;
    }

    public Task<FileRangeReadResult> ReadFileRangeResultAsync(
        string remotePath,
        long offset,
        long length,
        string? expectedContentVersion = null,
        long? expectedTotalLength = null,
        CancellationToken cancellationToken = default) =>
        _api.ReadFileRangeResultAsync(
            _profile,
            _session,
            Required("SYNO.FileStation.Download"),
            remotePath,
            offset,
            length,
            expectedContentVersion,
            expectedTotalLength,
            cancellationToken);

    public async Task<IReadOnlyList<FileItem>> SearchFilesAsync(
        string path,
        string query,
        CancellationToken cancellationToken = default)
    {
        var start = await CallAsync(
            "SYNO.FileStation.Search",
            "start",
            new Dictionary<string, string>
            {
                ["folder_path"] = string.IsNullOrWhiteSpace(path) ? "/" : path,
                ["pattern"] = query,
                ["recursive"] = "true",
            },
            cancellationToken).ConfigureAwait(false);
        var taskId = start.String("taskid")
            ?? throw new DsmException(UserText.Key("WinShared17bab1054ab28010"), UserText.Key("WinSharedefc81ced18eb3bb0"));
        try
        {
            var result = await CallAsync(
                "SYNO.FileStation.Search",
                "list",
                new Dictionary<string, string>
                {
                    ["taskid"] = taskId,
                    ["offset"] = "0",
                    ["limit"] = "1000",
                    ["additional"] = "[\"size\",\"owner\",\"time\",\"perm\"]",
                },
                cancellationToken).ConfigureAwait(false);
            return ParseFilePage(result, "files").Items;
        }
        finally
        {
            try
            {
                await CallAsync(
                    "SYNO.FileStation.Search",
                    "stop",
                    new Dictionary<string, string> { ["taskid"] = taskId },
                    cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException)
            {
                // 停止失败不覆盖已取得的搜索结果。
            }
        }
    }

    public async Task CreateFolderAsync(
        string parentPath,
        string name,
        CancellationToken cancellationToken = default)
    {
        ValidateName(name);
        await CallAsync(
            "SYNO.FileStation.CreateFolder",
            "create",
            new Dictionary<string, string>
            {
                ["folder_path"] = string.IsNullOrWhiteSpace(parentPath) ? "/" : parentPath,
                ["name"] = name.Trim(),
                ["force_parent"] = "false",
            },
            cancellationToken).ConfigureAwait(false);
        await VerifyFileExistsAsync(parentPath, name.Trim(), cancellationToken).ConfigureAwait(false);
    }

    public async Task RenameAsync(
        string path,
        string newName,
        CancellationToken cancellationToken = default)
    {
        ValidateName(newName);
        await CallAsync(
            "SYNO.FileStation.Rename",
            "rename",
            new Dictionary<string, string>
            {
                ["path"] = path,
                ["name"] = newName.Trim(),
            },
            cancellationToken).ConfigureAwait(false);
        var parent = path.Contains('/') ? path[..path.LastIndexOf('/')] : string.Empty;
        await VerifyFileExistsAsync(parent, newName.Trim(), cancellationToken).ConfigureAwait(false);
    }

    public async Task DeleteFilesAsync(
        IReadOnlyList<string> paths,
        CancellationToken cancellationToken = default)
    {
        if (paths.Count == 0)
        {
            throw new ArgumentException(UserText.Key("WinShared73a4d6d9c92df71c"), nameof(paths));
        }
        await CallVoidAsync(
            "SYNO.FileStation.Delete",
            "start",
            new Dictionary<string, string>
            {
                ["path"] = JsonSerializer.Serialize(paths),
                ["recursive"] = "true",
                ["accurate_progress"] = "true",
            },
            cancellationToken).ConfigureAwait(false);
        await WaitUntilAsync(
            async () =>
            {
                foreach (var group in paths.GroupBy(ParentPath))
                {
                    var page = await ListFilesAsync(group.Key, cancellationToken).ConfigureAwait(false);
                    var remaining = page.Items.Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
                    if (group.Any(remaining.Contains))
                    {
                        return false;
                    }
                }
                return true;
            },
            UserText.Key("WinSharedfea22978bfdec072"),
            cancellationToken).ConfigureAwait(false);
    }

    private static string ParentPath(string path)
    {
        var index = path.LastIndexOf('/');
        return index > 0 ? path[..index] : string.Empty;
    }

    private async Task VerifyFileExistsAsync(
        string parent,
        string name,
        CancellationToken cancellationToken)
    {
        var page = await ListFilesAsync(
            string.IsNullOrWhiteSpace(parent) ? "/" : parent,
            cancellationToken).ConfigureAwait(false);
        if (!page.Items.Any(item => string.Equals(item.Name, name, StringComparison.Ordinal)))
        {
            throw new DsmException(
                UserText.Key("WinShared0dc50225eea5c275"),
                UserText.Key("WinShared6e75c1fff5138b30"));
        }
    }
}
