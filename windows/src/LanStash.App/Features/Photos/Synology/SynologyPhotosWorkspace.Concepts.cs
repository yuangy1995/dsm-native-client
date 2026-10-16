using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private bool _needsConceptRefresh;
    private static bool IsConceptChange(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.ShowConcepts or SynologyPhotoRecognitionKind.SetConceptCover or SynologyPhotoRecognitionKind.RemoveConceptPhotos;
    private async Task ApplyConceptChangeAsync(SynologyPhotoRecognitionChange change)
    {
        if (_disposed || IsLoading || change.Space != SelectedSpace || Category != SynologyPhotoCategory.Subjects || change.CompletedCount == 0) return;
        var marker = (change.State, change.CompletedCount); if (_appliedRecognition.GetValueOrDefault(change.Id) == marker) return;
        if (CategoryItem is null)
        {
            _needsConceptRefresh = true; await ReloadConceptCollectionsAsync();
            if (!_needsConceptRefresh) _appliedRecognition[change.Id] = marker; return;
        }
        var generation = _generation; var token = _request.Token; var id = CategoryItem.Id;
        if (!change.TargetIds.Contains(id)) return;
        try
        {
            var current = await _repository.ConceptAsync(id, SelectedSpace, token); EnsureCurrent(generation, token);
            if (current.Concept.Id != id || current.Concept.Space != SelectedSpace) throw Invalid();
            CategoryItem = current.Concept; Changed(content: true); _appliedRecognition[change.Id] = marker;
            if (change.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos)
            {
                // 只关闭当前主题中移出项目的预览，不把分类变化登记为原件删除。
                if (Preview.Photo is { } photo && photo.Id.Space == change.Space && change.RemovedPhotoIds.Contains(photo.Id.ItemId)) Preview.Close();
                await ReloadChangedPhotoWindowAsync();
            }
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) { ErrorKey = FailureKey(error); Changed(); } }
    }
    private async Task ReloadConceptCollectionsAsync()
    {
        if (_disposed || IsLoading || IsLoadingMore || Category != SynologyPhotoCategory.Subjects || CategoryItem is not null) return;
        var generation = _generation; var token = _request.Token; IsLoadingMore = true; Changed();
        try
        {
            var concepts = await _repository.ConceptsAsync(SelectedSpace, token); EnsureCurrent(generation, token);
            if (concepts.Any(value => value.Concept.Space != SelectedSpace) || concepts.DistinctBy(value => value.Concept.Id).Count() != concepts.Count) throw Invalid();
            Collections.Clear(); foreach (var value in concepts.Where(value => value.AppearsInList)) Collections.Add(value.Concept);
            _collectionOffset = concepts.Count; HasMoreCollections = false; _needsConceptRefresh = false; ErrorKey = null;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) ErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoadingMore = false; Changed(content: true); } }
    }
}
