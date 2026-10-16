using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private readonly HashSet<Guid> _appliedFileChanges = [];
    private readonly HashSet<SynologyPhotoIdentity> _pagedPhotoIds = [];
    public async Task ApplyFileChangeAsync(SynologyPhotoFileChange change)
    {
        if (_disposed || change.State != SynologyPhotoFileState.Completed || change.Command.Photos.Any(photo => photo.Id.ProfileId != _repository.ProfileId)) return;
        if (!_appliedFileChanges.Add(change.Id)) { if (NeedsChangesRefresh) await ReloadChangedPhotoWindowAsync(); return; }
        var command = change.Command;
        if (command.Action == SynologyPhotoFileAction.Copy)
        {
            if (command.Destination is { } destination && Section == SynologyPhotosSection.Folders && SelectedSpace == destination.Space &&
                _query is SynologyPhotoQuery.Folder query && query.Id == destination.Id) await ReloadChangedPhotoWindowAsync();
            return;
        }
        if (command.Action == SynologyPhotoFileAction.Delete)
            foreach (var photo in command.Photos) RemoveConfirmed(photo);
        else
        {
            var target = command.Destination!;
            if (target.Space != command.Space && Album is not null && command.Photos.Any(original => Items.Any(photo => photo.Id == original.Id)))
            { await ReloadChangedPhotoWindowAsync(); return; }
            foreach (var photo in command.Photos)
            {
                if (target.Space != command.Space || _query is SynologyPhotoQuery.Folder source && source.Id == photo.FolderId && source.Space == photo.Id.Space)
                    RemoveVisibleFilePhoto(photo);
                else if (_query is not SynologyPhotoQuery.Folder)
                {
                    var index = Items.ToList().FindIndex(item => item.IsSameDeletionTarget(photo));
                    if (index >= 0) Items[index] = Items[index] with { FolderId = target.Id };
                }
                if (Preview.Photo?.Id == photo.Id) Preview.Close();
            }
        }
        if (SelectedSpace == command.Space && command.Folders.Count > 0)
        {
            if (Section == SynologyPhotosSection.Folders)
            {
                var index = _folderHistory.FindIndex(folder => command.Folders.Any(original => original.Id == folder.Id && original.Space == folder.Space));
                if (index >= 0)
                {
                    _folderHistory.RemoveRange(index, _folderHistory.Count - index);
                    // 原历史中保留存活父目录，内部刷新不跳回时间线。
                    await RefreshAsync(); return;
                }
                if (IsLoading && _folderHistory.LastOrDefault() is { } current && command.Folders.Any(folder => folder.ParentId == current.Id))
                { await RefreshAsync(); return; }
                var removed = Collections.Where(folder => command.Folders.Any(original => folder.Id == original.Id && folder.Space == original.Space && folder.ParentId == original.ParentId)).ToArray();
                foreach (var folder in removed) Collections.Remove(folder);
                if (removed.Length > 0) { _collectionOffset = Math.Max(0, _collectionOffset - removed.Length); InvalidateFilePaging(); }
            }
            else if (command.Action == SynologyPhotoFileAction.Delete) { await ReloadChangedPhotoWindowAsync(); return; }
        }
        if (command.Action == SynologyPhotoFileAction.Move && command.Destination is { } destinationFolder &&
            Section == SynologyPhotosSection.Folders && SelectedSpace == destinationFolder.Space && _query is SynologyPhotoQuery.Folder destinationQuery && destinationQuery.Id == destinationFolder.Id)
        { await ReloadChangedPhotoWindowAsync(); return; }
        Changed(content: true);
    }
    private void RemoveVisibleFilePhoto(SynologyPhoto photo)
    {
        if (_pagedPhotoIds.Remove(photo.Id)) { _nextOffset = Math.Max(0, _nextOffset - 1); InvalidateFilePaging(); }
        _itemIds.Remove(photo.Id);
        var existing = Items.FirstOrDefault(item => item.Id == photo.Id); if (existing is not null) Items.Remove(existing);
        if (Preview.Photo?.Id == photo.Id) Preview.Close();
    }
    private void InvalidateFilePaging()
    {
        if (!IsLoadingMore && !IsLoadingPrevious) return;
        var old = _request; _request = new(); _generation++; old.Cancel(); old.Dispose(); IsLoadingMore = false; IsLoadingPrevious = false;
    }
}
