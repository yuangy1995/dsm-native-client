using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed record CloudDriveRefreshCandidate(FileItem Item, CloudDriveContentVersion? Version);
internal sealed record CloudDriveRefreshSummary(int Refreshed, int Failed, int Removed = 0, int Retained = 0);

/// 只核对远端文件；原生更新实现必须在独占/已同步条件下失效旧缓存，不能覆盖本地修改。
internal static class CloudDriveRemoteRefresh
{
    internal static async Task<IReadOnlyDictionary<string, FileItem>> ReadDirectoryAsync(string parent,
        Func<int, CancellationToken, Task<FilePage>> loadPage, CancellationToken token)
    {
        var items = new Dictionary<string, FileItem>(StringComparer.Ordinal);
        var offset = 0; int? total = null;
        do
        {
            token.ThrowIfCancellationRequested();
            var page = await loadPage(offset, token).ConfigureAwait(false);
            if (page.Offset != offset || page.Total < 0 || total is not null && total != page.Total ||
                page.Items.Count > page.Total - offset || page.Items.Count == 0 && offset < page.Total)
                throw new InvalidDataException("cloud.refresh.incomplete_directory");
            total = page.Total;
            foreach (var item in page.Items)
            {
                var separator = item.Path.LastIndexOf('/');
                var itemParent = separator <= 0 ? "/" : item.Path[..separator];
                if (DesktopDrivePath.Normalize(item.Path) != item.Path || itemParent != parent || !items.TryAdd(item.Path, item))
                    throw new InvalidDataException("cloud.refresh.invalid_directory");
            }
            offset = checked(offset + page.Items.Count);
        } while (offset < total);
        return items;
    }

    internal static async Task<CloudDriveRefreshCandidate> ReadCandidateAsync(FileItem item,
        IFileRangeReader reader, CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(reader);
        if (item.IsDirectory || item.Size < 0 || string.IsNullOrWhiteSpace(item.Path) ||
            !item.Path.StartsWith('/') || item.Path == "/" || item.Path.Contains('\\') ||
            item.Path.Any(char.IsControl) || DesktopDrivePath.Normalize(item.Path) != item.Path)
            throw new InvalidDataException("cloud.refresh.invalid_item");
        token.ThrowIfCancellationRequested();
        // 空文件没有可请求的字节；仅根据明确元数据截断，不能制造一个 HTTP 内容版本。
        if (item.Size == 0) return new(item, null);
        var result = await reader.ReadFileRangeResultAsync(item.Path, 0, 1,
            cancellationToken: token).ConfigureAwait(false);
        try
        {
            token.ThrowIfCancellationRequested();
            if (result.StatusCode != 206 || result.RequestedStart != 0 || result.ResponseStart != 0 ||
                result.RequestedLength != 1 || result.ResponseLength != 1 || result.ActualByteCount != 1 ||
                result.Bytes.Length != 1 || result.TotalLength != item.Size || !result.CanSafelyReadInSegments ||
                !IsStrongVersion(result.ServerContentVersion))
                throw new InvalidDataException("cloud.refresh.remote_changed");
            return new(item, new(item.Path, result.ServerContentVersion!, result.TotalLength));
        }
        finally { Array.Clear(result.Bytes); }
    }

    internal static async Task<CloudDriveRefreshCandidate> RefreshAsync(DesktopDriveMapping mapping, FileItem item,
        IFileRangeReader reader, DesktopCloudDriveSyncStore store,
        Func<CloudDriveRefreshCandidate, bool, CancellationToken, Task> updateLocalPlaceholder,
        CancellationToken token = default)
    {
        ArgumentNullException.ThrowIfNull(updateLocalPlaceholder);
        // 在网络请求前锁定基线；读取候选期间的同目标写入/刷新会在最终事务内被拒绝。
        var expected = await store.ReadVersionAsync(mapping, item.Path, token).ConfigureAwait(false);
        var candidate = await ReadCandidateAsync(item, reader, token).ConfigureAwait(false);
        await store.RefreshVersionAsync(mapping, item.Path, expected, candidate.Version,
            cancellation => updateLocalPlaceholder(candidate, expected is null || expected != candidate.Version, cancellation), token)
            .ConfigureAwait(false);
        return candidate;
    }

    private static bool IsStrongVersion(string? version) => version is { Length: >= 2 } &&
        version[0] == '"' && version[^1] == '"' &&
        !version[1..^1].Any(value => value == '"' || value <= ' ' || value == '\u007f');
}
