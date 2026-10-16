using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private readonly HashSet<Guid> _appliedFolderChanges = [];
    public async Task ApplyFolderChangeAsync(SynologyPhotoFolderChange change)
    {
        if (_disposed || change.State != SynologyPhotoChangeState.Completed || change.Result is not { } result || result.Space != SelectedSpace) return;
        var original = change.Edit.Folder;
        if (!_appliedFolderChanges.Add(change.Id))
        {
            if (NeedsChangesRefresh && change.Edit.Kind is SynologyPhotoFolderEditKind.Create or SynologyPhotoFolderEditKind.Sort &&
                Section == SynologyPhotosSection.Folders && _query is SynologyPhotoQuery.Folder retry && retry.Id == original.Id)
                await ReloadChangedPhotoWindowAsync();
            return;
        }
        if (change.Edit.Kind == SynologyPhotoFolderEditKind.Cover) return;
        if (change.Edit.Kind == SynologyPhotoFolderEditKind.Rename)
        {
            SynologyPhotoCollection Update(SynologyPhotoCollection value)
            {
                if (value.Space != result.Space || value.Path is not { } path) return value;
                if (value.Id == original.Id && path == original.Path) return value with { Name = result.Name, Path = result.Path, ParentId = result.ParentId };
                return path.StartsWith(original.Path + "/", StringComparison.Ordinal) ? value with { Path = result.Path + path[original.Path.Length..] } : value;
            }
            for (var i = 0; i < _folderHistory.Count; i++) _folderHistory[i] = Update(_folderHistory[i]);
            if (Section == SynologyPhotosSection.Folders) for (var i = 0; i < Collections.Count; i++) Collections[i] = Update(Collections[i]);
            Changed(content: true); return;
        }
        if (Section != SynologyPhotosSection.Folders || _query is not SynologyPhotoQuery.Folder current || current.Id != original.Id ||
            _folderHistory.LastOrDefault()?.Path is { } known && known != original.Path) return;
        if (change.Edit.Kind == SynologyPhotoFolderEditKind.Sort) _query = current with { Sort = result.Sort };
        await ReloadChangedPhotoWindowAsync();
    }
}
