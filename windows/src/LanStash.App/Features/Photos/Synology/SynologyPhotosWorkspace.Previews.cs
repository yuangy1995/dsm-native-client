using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private readonly HashSet<(Guid, SynologyPhotoIdentity)> _appliedPreviews = [];
    public event Action? AutomaticPreviewChanged;
    public SynologyPhotoAutomaticContext AutomaticContext(bool busy = false) => new(SelectedSpace, Spaces, CanManageSharedSpace,
        Items.ToArray(), Preview.Photo, Slideshow.IsPresented ? Slideshow.Photos.ToArray() : Preview.SimilarDetail?.Photos ?? Items.ToArray(),
        !Slideshow.IsPresented && Preview.SimilarDetail is null && Section == SynologyPhotosSection.Timeline,
        Slideshow.IsPresented ? !Slideshow.HasMore : Preview.SimilarDetail is not null || !HasMore && !HasPrevious,
        busy || !HasLoaded || IsLoading || Deletion.IsBusy);
    private async Task ApplyAutomaticPreviewAsync(SynologyPhotoAutomaticPreview result)
    {
        if (_disposed || result.State != SynologyPhotoChangeState.Completed) return;
        var candidate = result.Candidate;
        var photos = Items.Concat(Preview.Photo is { } preview ? [preview] : []).Where(photo => photo.Id.Space == candidate.Space &&
            (photo.Thumbnail?.UnitId == candidate.UnitId || photo.Id == candidate.SourcePhoto?.Id)).DistinctBy(photo => photo.Id).ToArray();
        if (photos.Length == 0) return;
        // 后台候选只有单元身份；仅刷新当前已存在的对应照片，不重查月份或改变选中项。
        if (await ApplyPreviewGenerationAsync(new(result.Id, false, photos.Select(photo => new SynologyPhotoPreviewGenerationItem(photo,
            SynologyPhotoChangeState.Completed, photo)).ToArray(), false, false))) AutomaticPreviewChanged?.Invoke();
    }
    public async Task<bool> ApplyPreviewGenerationAsync(SynologyPhotoPreviewGeneration result)
    {
        if (_disposed || IsLoading) return false;
        var updates = result.Items.Where(item => item.State == SynologyPhotoChangeState.Completed && item.Updated is not null &&
            !_appliedPreviews.Contains((result.Id, item.Original.Id))).ToArray();
        if (updates.Length == 0) return false;
        var generation = _generation; var token = _request.Token; var applied = false;
        foreach (var item in updates)
        {
            bool Matches(SynologyPhoto? value) => value is not null && item.Original.IsSameDeletionTarget(value) && item.Original.AlbumContext == value.AlbumContext;
            if (!Items.Any(Matches) && !Matches(Preview.Photo)) continue;
            // 历史任务只触发刷新；不能用旧回读缓存覆盖后来生成的预览或当前资料。
            var current = await _repository.DetailsAsync(item.Original, token);
            if (_disposed || generation != _generation) return false;
            if (!Matches(current)) continue;
            var index = Items.ToList().FindIndex(Matches);
            if (index >= 0) Items[index] = Items[index] with { Thumbnail = current.Thumbnail };
            _appliedPreviews.Add((result.Id, item.Original.Id)); applied = true;
            if (Matches(Preview.Photo)) await Preview.OpenAsync(Preview.Photo! with { Thumbnail = current.Thumbnail });
            if (_disposed || generation != _generation) return false;
        }
        if (applied) ContentChanged?.Invoke(); return applied;
    }
}
