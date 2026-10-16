using LanStash.App.Features.Files.Downloads;
using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed record FolderDownloadEntry(FileItem Item, string RelativePath);
internal sealed record FolderDownloadPlan(IReadOnlyList<FolderDownloadEntry> Entries, long TotalBytes);

internal static class ForegroundFolderDownloadPlan
{
    // 清单使用公开完整分页；输出路径只由经过 Windows 名称检查的直接子项组成。
    public static async Task<FolderDownloadPlan> CreateAsync(IDsmRepository repository, IReadOnlyList<FileItem> selection,
        ForegroundTransferControl control, CancellationToken token)
    {
        var selected = selection.ToArray();
        if (!FileDownloadSelection.IsValid(selected) || selected.Any(a => selected.Any(b => a != b && a.Path.StartsWith(b.Path + "/", StringComparison.Ordinal))))
            throw new InvalidDataException("download.selection-overlap");
        var entries = new List<FolderDownloadEntry>();
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var sources = new HashSet<string>(StringComparer.Ordinal);
        var pending = new Queue<FolderDownloadEntry>(selected.Select(item => new FolderDownloadEntry(item, item.Name)));
        long totalBytes = 0;
        while (pending.TryDequeue(out var current))
        {
            await control.WaitAsync(token).ConfigureAwait(false);
            if (!FileDownloadSelection.IsValidItem(current.Item) || !BoundedFileDownloadBatch.IsValidLocalName(current.Item.Name) ||
                !names.Add(current.RelativePath) || !sources.Add(current.Item.Path))
                throw new ForegroundDownloadException(MutationErrorCategory.Validation);
            // 限制不可映射的路径深度，不把未遍历内容当作完整结果。
            if (current.RelativePath.Count(c => c == '/') >= 128) throw new InvalidDataException("download.path-too-deep");
            await ValidateSourceAsync(repository, current.Item, token).ConfigureAwait(false);
            entries.Add(current);
            if (!current.Item.IsDirectory) { totalBytes = checked(totalBytes + current.Item.Size); continue; }
            int offset = 0;
            int? total = null;
            var children = new HashSet<string>(StringComparer.Ordinal);
            do
            {
                await control.WaitAsync(token).ConfigureAwait(false);
                var page = await repository.ListFilesAsync(current.Item.Path, offset, 500, FileListOptions.Default, token).ConfigureAwait(false);
                if (page.Offset != offset || page.Total < offset || page.Items.Count > 500 || page.Items.Count > page.Total - offset ||
                    page.Items.Count == 0 && offset < page.Total || total is not null && total != page.Total)
                    throw new InvalidDataException("download.incomplete-directory");
                total = page.Total;
                foreach (var child in page.Items)
                {
                    if (!FileDownloadSelection.IsValidItem(child) || child.Path != current.Item.Path + "/" + child.Name || !children.Add(child.Path))
                        throw new InvalidDataException("download.incomplete-directory");
                    pending.Enqueue(new(child, current.RelativePath + "/" + child.Name));
                }
                offset = checked(offset + page.Items.Count);
            } while (offset < total);
        }
        return new(entries, totalBytes);
    }

    public static async Task ValidateSourceAsync(IDsmRepository repository, FileItem item, CancellationToken token)
    {
        var metadata = await repository.ReadFileMetadataAsync(item.Path, token).ConfigureAwait(false);
        if (metadata is null || metadata.Item.Path != item.Path || metadata.Item.Name != item.Name ||
            metadata.Item.IsDirectory != item.IsDirectory || !item.IsDirectory && metadata.Item.Size != item.Size ||
            metadata.Item.ModifiedAt != item.ModifiedAt || metadata.Type?.Contains("link", StringComparison.OrdinalIgnoreCase) == true)
            throw new InvalidDataException("download.source-changed");
    }
}
