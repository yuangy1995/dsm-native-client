using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    public async Task LoadNextAsync(bool automatic = false)
    {
        if (_disposed || Deletion.IsBusy || IsLoading || IsLoadingMore || (!HasMore && !HasMoreCollections) || (automatic && ErrorKey is not null)) return;
        var generation = _generation; var token = _request.Token;
        IsLoadingMore = true; ErrorKey = null; Changed();
        try
        {
            if (HasMoreCollections)
            {
                if (Section == SynologyPhotosSection.Sharing && Album is null)
                {
                    var entries = await _repository.SharedEntriesAsync(ShareScope, _collectionOffset, PageSize, token);
                    EnsureCurrent(generation, token); AcceptShared(entries);
                }
                else
                {
                    var page = Category is { } category && CategoryItem is null
                        ? await _repository.CategoryItemsAsync(category, _collectionOffset, PageSize, token)
                        : Section == SynologyPhotosSection.Albums
                            ? await _repository.AlbumsAsync(_collectionOffset, PageSize, token)
                            : await _repository.FoldersAsync(_folderHistory[^1].Id, _collectionOffset, PageSize, token);
                    EnsureCurrent(generation, token); AcceptCollections(page);
                }
            }
            else
            {
                var offset = _nextOffset;
                var page = await _repository.PhotosAsync(_query, offset, PageSize, token);
                EnsureCurrent(generation, token); Accept(page, offset);
            }
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) ErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoadingMore = false; Changed(content: true); } }
    }

    public async Task JumpToMonthAsync(SynologyPhotoMonth month)
    {
        if (_disposed || Deletion.IsBusy || !Months.Contains(month) || _timelineBase is not { } baseline) return;
        var destination = Constrain(baseline, 0, StartOfDay(month.Date.AddMonths(1)) - 1);
        var (generation, token) = StartRequest();
        _query = destination; PreviousMonthId = month.Id; SelectedMonth = month;
        PreviousErrorKey = null; _nextOffset = 0; HasMore = false; ErrorKey = null;
        Items.Clear(); _itemIds.Clear(); IsLoading = true; Changed(content: true);
        try
        {
            var page = await _repository.PhotosAsync(destination, 0, PageSize, token);
            EnsureCurrent(generation, token); Accept(page, 0); HasLoaded = true;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) ErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoading = false; Changed(content: true); } }
    }

    /// <summary>完整读完相邻月份再补入；中途失败不移动边界，避免同月分页产生日期缺口。</summary>
    public async Task LoadPreviousAsync(bool automatic = false)
    {
        if (_disposed || Deletion.IsBusy || IsLoading || IsLoadingPrevious || !HasPrevious ||
            (automatic && PreviousErrorKey is not null) || PreviousMonthId is not { } previous || _timelineBase is not { } baseline) return;
        var upper = Months.Last(month => month.Id > previous);
        var lower = Months.First(month => month.Id == previous);
        var query = Constrain(baseline, StartOfDay(lower.Date.AddMonths(1)), StartOfDay(upper.Date.AddMonths(1)) - 1);
        var generation = _generation; var token = _request.Token;
        IsLoadingPrevious = true; PreviousErrorKey = null; Changed();
        try
        {
            var offset = 0;
            var additions = new List<SynologyPhoto>();
            var seen = new HashSet<SynologyPhotoIdentity>(_itemIds);
            while (true)
            {
                var page = await _repository.PhotosAsync(query, offset, PageSize, token);
                EnsureCurrent(generation, token); Validate(page, offset);
                var fresh = page.Items.Where(item => seen.Add(item.Id) && !_confirmedDeleted.Contains(item.Id)).ToArray();
                if (page.HasMore && fresh.Length == 0) throw Invalid();
                additions.AddRange(fresh); offset = page.NextOffset;
                if (!page.HasMore) break;
            }
            EnsureCurrent(generation, token);
            // 向下分页可以并发完成；再次去重，不能覆盖它已经加入的照片。
            additions = additions.Where(item => !_itemIds.Contains(item.Id) && !_confirmedDeleted.Contains(item.Id)).ToList();
            for (var index = additions.Count - 1; index >= 0; index--)
            { Items.Insert(0, additions[index]); _itemIds.Add(additions[index].Id); }
            PreviousMonthId = upper.Id;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception error) { if (IsCurrent(generation, token)) PreviousErrorKey = FailureKey(error); }
        finally { if (IsCurrent(generation, token)) { IsLoadingPrevious = false; Changed(content: true); } }
    }

    private void Accept(SynologyPhotoPage page, int offset)
    {
        Validate(page, offset);
        var fresh = page.Items.Where(item => !_itemIds.Contains(item.Id) && !_confirmedDeleted.Contains(item.Id)).ToArray();
        if (page.HasMore && fresh.Length == 0) throw Invalid();
        foreach (var photo in fresh) { _itemIds.Add(photo.Id); Items.Add(photo); }
        _nextOffset = page.NextOffset; HasMore = page.HasMore;
    }

    private void Validate(SynologyPhotoPage page, int offset)
    {
        if (page.Offset != offset || page.Items.Count > PageSize || page.NextOffset != checked(offset + page.Items.Count) ||
            (page.HasMore && page.Items.Count == 0) || page.Items.Select(item => item.Id).Distinct().Count() != page.Items.Count ||
            page.Items.Any(item => item.Id.ProfileId != _repository.ProfileId || item.Id.Space != SynologyPhotoSpace.Personal)) throw Invalid();
    }

    private void AcceptCollections(IReadOnlyList<SynologyPhotoCollection> page)
    {
        if (page.Count > PageSize || page.Select(item => item.Id).Distinct().Count() != page.Count) throw Invalid();
        var seen = Collections.Select(item => item.Id).ToHashSet();
        var fresh = page.Where(item => seen.Add(item.Id)).ToArray();
        if (page.Count == PageSize && fresh.Length == 0) throw Invalid();
        foreach (var collection in fresh) Collections.Add(collection);
        _collectionOffset = checked(_collectionOffset + page.Count); HasMoreCollections = page.Count == PageSize;
    }

    private void AcceptShared(IReadOnlyList<SynologyPhotoSharedEntry> page)
    {
        if (page.Count > PageSize || page.Select(item => item.Id).Distinct().Count() != page.Count) throw Invalid();
        var seen = SharedEntries.Select(item => item.Id).ToHashSet();
        var fresh = page.Where(item => seen.Add(item.Id)).ToArray();
        if (page.Count == PageSize && fresh.Length == 0) throw Invalid();
        foreach (var entry in fresh) SharedEntries.Add(entry);
        _collectionOffset = checked(_collectionOffset + page.Count); HasMoreCollections = page.Count == PageSize;
    }

    private void RemoveConfirmed(SynologyPhoto photo)
    {
        _confirmedDeleted.Add(photo.Id); _itemIds.Remove(photo.Id);
        var existing = Items.FirstOrDefault(item => item.Id == photo.Id);
        if (existing is not null) Items.Remove(existing);
        if (Preview.Photo?.Id == photo.Id) Preview.Close();
        Changed(content: true);
    }

    internal static SynologyPhotoQuery Constrain(SynologyPhotoQuery query, long start, long end) => query switch
    {
        SynologyPhotoQuery.Timeline value => new SynologyPhotoQuery.Timeline(Math.Max(start, value.Start), Math.Min(end, value.End)),
        SynologyPhotoQuery.Search value => new SynologyPhotoQuery.Search(value.Keyword, Math.Max(start, value.Start), Math.Min(end, value.End)),
        SynologyPhotoQuery.Filtered value => new SynologyPhotoQuery.Filtered(value.Filter with
        {
            StartTime = value.Filter.StartTime is { } lower ? Math.Max(start, lower) : null,
            EndTime = value.Filter.EndTime is { } upper ? Math.Min(end, upper) : null,
        }, Math.Max(start, value.Start), Math.Min(end, value.End)),
        SynologyPhotoQuery.Category value => new SynologyPhotoQuery.Category(value.Kind, value.Id, Math.Max(start, value.Start), Math.Min(end, value.End)),
        _ => throw Invalid(),
    };
    private static SynologyPhotoException Invalid() => new(SynologyPhotoFailure.InvalidResponse);
}
