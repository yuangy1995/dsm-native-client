using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    public async Task OpenBackgroundTaskLocationAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default)
    {
        if (_disposed || Deletion.IsBusy) return;
        var generation = _generation;
        var chain = await _repository.BackgroundTaskLocationAsync(task, cancellationToken);
        if (_disposed || generation != _generation || cancellationToken.IsCancellationRequested) return;
        if (chain.Count == 0 || task.TargetSpace is not { } space || chain.Any(folder => folder.Space != space) ||
            chain[^1].Id != task.TargetFolderId || !chain[0].IsRoot) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
        SelectedSpace = space; Section = SynologyPhotosSection.Folders; Album = null; ResetSourceNavigation();
        _folderHistory.AddRange(chain.Select(folder => folder.Collection));
        await RefreshAsync();
    }
}
