using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    public SynologyPhotoAlbum? CurrentAlbum { get; private set; }
    public SynologyPhotoAlbumListSort? AlbumListSort { get; private set; }
    public SynologyPhotoAlbumDisplay? AlbumDisplay { get; private set; }
    public SynologyPhotoAlbumListScope? AlbumListScope => Section == SynologyPhotosSection.Albums && Album is null && Category is null
        ? SynologyPhotoAlbumListScope.Albums : Section == SynologyPhotosSection.Sharing && Album is null
            ? ShareScope switch { SynologyPhotoShareScope.WithMe => SynologyPhotoAlbumListScope.WithMe, SynologyPhotoShareScope.WithOthers => SynologyPhotoAlbumListScope.ByMe, _ => null } : null;
    private readonly HashSet<Guid> _appliedAlbumChanges = [];
    private readonly HashSet<(Guid, SynologyPhotoIdentity)> _appliedAlbumMembers = [];

    public async Task ApplyTemporaryChangeAsync(SynologyPhotoTemporaryChange change)
    {
        if (_disposed || change.State != SynologyPhotoChangeState.Completed || !_appliedAlbumChanges.Add(change.Id)) return;
        var removed = !change.FromCreation || change.CancelRequested;
        if (removed && Album is not null && Album.Id == change.AlbumId)
        { Album = null; CurrentAlbum = null; await RefreshAsync(); }
        else if (AlbumListScope is not null) await RefreshAsync();
    }

    private async Task ReadAlbumPreferencesAsync(long generation, CancellationToken token)
    {
        AlbumListSort = null; AlbumDisplay = null;
        if (!_repository.SupportsAlbumManagement || AlbumListScope is not { } scope) return;
        try { var sort = await _repository.AlbumListSortAsync(scope, token); EnsureCurrent(generation, token); AlbumListSort = sort; }
        catch (Exception error) when (error is not OperationCanceledException) { EnsureCurrent(generation, token); ErrorKey = "PhotosAlbumPreferencesFailed"; }
        if (scope != SynologyPhotoAlbumListScope.Albums) return;
        try { var display = await _repository.AlbumDisplayAsync(token); EnsureCurrent(generation, token); AlbumDisplay = display; }
        catch (Exception error) when (error is not OperationCanceledException) { EnsureCurrent(generation, token); ErrorKey = "PhotosAlbumPreferencesFailed"; }
    }
    private Task<IReadOnlyList<SynologyPhotoCollection>> ReadAlbumsPageAsync(int offset, CancellationToken token) => AlbumListSort is { } sort && AlbumDisplay is { } display
        ? _repository.AlbumsAsync(offset, PageSize, display, sort, token) : _repository.AlbumsAsync(offset, PageSize, token);
    private Task<IReadOnlyList<SynologyPhotoSharedEntry>> ReadSharedPageAsync(int offset, CancellationToken token) => AlbumListSort is { } sort && AlbumListScope is not null
        ? _repository.SharedEntriesAsync(ShareScope, offset, PageSize, sort, token) : _repository.SharedEntriesAsync(ShareScope, offset, PageSize, token);

    public async Task ApplyAlbumChangeAsync(SynologyPhotoAlbumChange change)
    {
        if (_disposed || change.Edit.Album is { } target && target.ProfileId != _repository.ProfileId ||
            change.Result is { } resultOwner && resultOwner.ProfileId != _repository.ProfileId || change.Edit.Photos.Any(photo => photo.Id.ProfileId != _repository.ProfileId)) return;
        var edit = change.Edit; var current = Album?.Id == edit.Album?.Id && Album is not null;
        var membersChanged = false;
        if (current && edit.Kind is SynologyPhotoAlbumEditKind.AddMembers or SynologyPhotoAlbumEditKind.RemoveMembers)
        {
            foreach (var member in change.Members.Where(member => member.State == SynologyPhotoChangeState.Completed))
            {
                if (!_appliedAlbumMembers.Add((change.Id, member.Photo.Id))) continue;
                // 移除成员只影响当前相册；原件仍应出现在时间线和其他相册中。
                if (edit.Kind == SynologyPhotoAlbumEditKind.RemoveMembers) RemoveVisibleFilePhoto(member.Photo);
                membersChanged = true;
            }
        }
        if (change.State != SynologyPhotoChangeState.Completed)
        { if (membersChanged) { Changed(content: true); await ReloadChangedPhotoWindowAsync(); } return; }
        if (!_appliedAlbumChanges.Add(change.Id))
        { if (current && NeedsChangesRefresh) await ReloadChangedPhotoWindowAsync(); return; }
        if (edit.Kind is SynologyPhotoAlbumEditKind.ListSort or SynologyPhotoAlbumEditKind.ListDisplay)
        {
            if (AlbumListScope == edit.Scope) await RefreshAsync();
            return;
        }
        if (edit.Kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.CreateCondition)
        { if (ShowsCategories) await RefreshAsync(); return; }
        if (edit.Kind == SynologyPhotoAlbumEditKind.Rebuild && change.Result is { } rebuilt)
        { if (current) { Album = rebuilt.Collection; CurrentAlbum = rebuilt; await RefreshAsync(); } else if (AlbumListScope is not null) await RefreshAsync(); return; }
        if (edit.Kind == SynologyPhotoAlbumEditKind.Delete)
        {
            if (current) { Album = null; CurrentAlbum = null; await RefreshAsync(); return; }
            if (AlbumListScope is not null) await RefreshAsync();
            return;
        }
        if (change.Result is { } result)
        {
            if (current) { CurrentAlbum = result; Album = result.Collection; }
            if (Section == SynologyPhotosSection.Albums && Category is null)
                for (var index = 0; index < Collections.Count; index++)
                    if (Collections[index].Id == result.Id) Collections[index] = result.Collection;
            for (var index = 0; index < SharedEntries.Count; index++)
                if (SharedEntries[index].AlbumId == result.Id) SharedEntries[index] = SharedEntries[index] with { Title = result.Name };
            if (current && edit.Kind == SynologyPhotoAlbumEditKind.Sort && _query is SynologyPhotoQuery.Album query) _query = query with { Sort = result.Sort };
        }
        Changed(content: true);
        if (current && (membersChanged || edit.Kind is SynologyPhotoAlbumEditKind.Sort or SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Unfreeze)) await ReloadChangedPhotoWindowAsync();
    }
}
