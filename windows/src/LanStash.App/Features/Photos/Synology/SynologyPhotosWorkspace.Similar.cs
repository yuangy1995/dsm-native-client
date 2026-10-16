using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    private readonly Dictionary<long, (SynologyPhotoQuery Query, SynologyPhoto Photo)> _similarSlots = [];
    private async Task ApplySimilarChangeAsync(SynologyPhotoRecognitionChange change)
    {
        if (_disposed || IsLoading || change.Space != SelectedSpace || Category != SynologyPhotoCategory.Similar || change.CompletedCount == 0) return;
        var marker = (change.State, change.CompletedCount); if (_appliedRecognition.GetValueOrDefault(change.Id) == marker) return;
        var generation = _generation; var token = _request.Token;
        try
        {
            var changed = false;
            foreach (var result in change.SimilarGroups.Where(result => result.State == SynologyPhotoChangeState.Completed))
            {
                var positions = Items.Select((photo, index) => (photo, index)).Where(value => value.photo.SimilarGroup?.Id == result.GroupId).ToArray();
                if (positions.Length == 0 && (!_similarSlots.TryGetValue(result.GroupId, out var slot) || slot.Query != _query)) continue;
                var detail = await _repository.SimilarGroupAsync(result.GroupId, change.Space, token); EnsureCurrent(generation, token);
                changed = true;
                // 只更新原查询已出现过的组；撤销旧月份不能把卡片插入新月份。
                if (positions.Length > 0) _similarSlots[result.GroupId] = (_query, positions[0].photo);
                if (detail is null)
                {
                    foreach (var (photo, _) in positions) { Items.Remove(photo); _itemIds.Remove(photo.Id); }
                }
                else
                {
                    var representative = detail.Photos.Single(photo => photo.Id.ItemId == detail.Group.TopPickId) with { SimilarGroup = detail.Group };
                    if (positions.Length > 0)
                    {
                        Items[positions[0].index] = representative; _itemIds.Remove(positions[0].photo.Id); _itemIds.Add(representative.Id);
                        foreach (var (photo, _) in positions.Skip(1)) { Items.Remove(photo); _itemIds.Remove(photo.Id); }
                    }
                    else if (!_itemIds.Contains(representative.Id))
                    {
                        var index = Items.TakeWhile(photo => photo.TakenAt >= representative.TakenAt).Count(); Items.Insert(index, representative); _itemIds.Add(representative.Id);
                    }
                }
                if (Preview.Photo?.SimilarGroup?.Id == result.GroupId) await Preview.RefreshSimilarAsync();
                EnsureCurrent(generation, token);
            }
            _appliedRecognition[change.Id] = marker; Changed(content: true);
            // 当前页的代表项目变化会移动后续偏移，下一次分页从原窗口重新读取。
            if (changed) NeedsChangesRefresh = true;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) { ErrorKey = FailureKey(error); Changed(); } }
    }
}
