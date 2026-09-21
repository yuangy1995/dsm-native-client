using LanStash.Domain;

namespace LanStash.App.Features.Files.CopyMove;

// 拖动只携带一次性票据，文件路径及变更基线留在当前页面内存中。
internal sealed class FileDragMoveSession(Guid profileId, string folder, IReadOnlyList<FileItem> sources)
{
    public const string DataFormat = "LanStash.RemoteFileMove";
    public string Ticket { get; } = Guid.NewGuid().ToString("N");
    public Guid ProfileId { get; } = profileId;
    public string Folder { get; } = folder;
    public IReadOnlyList<FileItem> Sources { get; } = Array.AsReadOnly(sources.ToArray());
    private bool _consumed;
    public void Invalidate() => _consumed = true;

    public bool CanDrop(Guid currentProfile, string currentFolder, IReadOnlyList<FileItem> currentItems, FileItem target) =>
        !_consumed && currentProfile == ProfileId && currentFolder == Folder && target.IsDirectory && target.CanWrite &&
        currentItems.Contains(target) && FileCopyMoveViewModel.IsDestination(target.Path) &&
        FileCopyMoveBatchViewModel.Validate(Sources, FileCopyMoveOperation.Move, Folder, FileCopyMoveBatchSourceScope.CurrentFolder) == FileCopyMoveBatchValidationStatus.Valid &&
        Sources.All(source => currentItems.Contains(source) && target.Path != source.Path && !target.Path.StartsWith(source.Path + "/", StringComparison.Ordinal));

    public bool TryConsume(string ticket, Guid currentProfile, string currentFolder, IReadOnlyList<FileItem> currentItems, FileItem target)
    {
        if (ticket != Ticket || !CanDrop(currentProfile, currentFolder, currentItems, target)) return false;
        _consumed = true; return true;
    }
}
