using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed partial class SynologyPhotosWorkspace
{
    public async Task LoadNextAsync(bool automatic = false)
    {
        if (_needsConceptRefresh) { if (!automatic || ErrorKey is null) await ReloadConceptCollectionsAsync(); return; }
        if (_needsPeopleRefresh) { if (!automatic || ErrorKey is null) await ReloadPeopleCollectionsAsync(); return; }
        if (NeedsChangesRefresh) { if (!automatic && !IsLoading) await ReloadChangedPhotoWindowAsync(); return; }
        if (_disposed || Deletion.IsBusy || IsLoading || IsLoadingMore || (!HasMore && !HasMoreCollections) || (automatic && ErrorKey is not null)) return;
        var generation = _generation; var token = _request.Token;
        IsLoadingMore = true; ErrorKey = null; Changed();
        try
        {
            if (HasMoreCollections)
            {
                if (Section == SynologyPhotosSection.Sharing && Album is null)
                {
                    var entries = await ReadSharedPageAsync(_collectionOffset, token);
                    EnsureCurrent(generation, token); AcceptShared(entries);
                }
                else
                {
                    var page = Category is { } category && CategoryItem is null
                        ? await _repository.CategoryItemsAsync(category, _collectionOffset, PageSize, token, SelectedSpace)
                        : Section == SynologyPhotosSection.Albums
                            ? await ReadAlbumsPageAsync(_collectionOffset, token)
                            : await _repository.FoldersAsync(_folderHistory[^1].Id, _collectionOffset, PageSize, (_query as SynologyPhotoQuery.Folder)?.Sort?.Descending == true, token, SelectedSpace);
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
        Items.Clear(); _itemIds.Clear(); _pagedPhotoIds.Clear(); IsLoading = true; Changed(content: true);
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
        foreach (var photo in page.Items) _pagedPhotoIds.Add(photo.Id);
        foreach (var photo in fresh) { _itemIds.Add(photo.Id); Items.Add(photo); }
        _nextOffset = page.NextOffset; HasMore = page.HasMore;
    }

    private void Validate(SynologyPhotoPage page, int offset, SynologyPhotoQuery? query = null)
    {
        query ??= _query;
        if (page.Offset != offset || page.Items.Count > PageSize || page.NextOffset != checked(offset + page.Items.Count) ||
            (page.HasMore && page.Items.Count == 0) || page.Items.Select(item => item.Id).Distinct().Count() != page.Items.Count ||
            page.Items.Any(item => item.Id.ProfileId != _repository.ProfileId || (query is SynologyPhotoQuery.Album album
                ? item.AlbumContext is not { } context || context.AlbumId != album.Id || context.OwnerUserId < 0 ||
                    item.Id.Space != (context.OwnerUserId == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal)
                : item.Id.Space != query.Space || item.AlbumContext is not null))) throw Invalid();
        if (query is SynologyPhotoQuery.Album && page.Items.Any(item => _itemIds.Contains(item.Id) &&
            Items.First(existing => existing.Id == item.Id).AlbumContext?.OwnerUserId != item.AlbumContext?.OwnerUserId)) throw Invalid();
    }

    /// <summary>编辑后刷新已加载窗口并重建真实偏移；保留月份、筛选、目录、预览与选择，不跳到最新照片。</summary>
    public async Task ReloadChangedPhotoWindowAsync()
    {
        if (_disposed || !HasLoaded) return;
        var query = _query;
        if (PreviousMonthId is { } previous && _timelineBase is { } baseline && Months.FirstOrDefault(month => month.Id == previous) is { } upper)
            query = Constrain(baseline, 0, StartOfDay(upper.Date.AddMonths(1)) - 1);
        var count = Math.Max(PageSize, Math.Max(Items.Count, _memberReloadCount ?? 0)); var old = _request; _request = new(); var generation = ++_generation; var token = _request.Token;
        old.Cancel(); old.Dispose(); _optionsRequest?.Cancel(); _optionsGeneration++; IsLoadingOptions = false;
        IsLoadingMore = false; IsLoadingPrevious = false; IsLoading = true; NeedsChangesRefresh = true; ErrorKey = null; Changed();
        try
        {
            List<SynologyPhotoCollection>? folders = null;
            var folderOffset = 0; var moreFolders = false;
            if (query is SynologyPhotoQuery.Folder directory)
            {
                folders = []; var ids = new HashSet<long>(); var loaded = Math.Max(PageSize, _collectionOffset);
                do
                {
                    var page = await _repository.FoldersAsync(directory.Id, folderOffset, PageSize, directory.Sort?.Descending == true, token, query.Space);
                    EnsureCurrent(generation, token);
                    if (page.Count > PageSize || page.Any(item => item.Space != query.Space || item.ParentId != directory.Id || !ids.Add(item.Id))) throw Invalid();
                    folders.AddRange(page); folderOffset += page.Count; moreFolders = page.Count == PageSize;
                } while (moreFolders && folderOffset < loaded);
            }
            var values = new List<SynologyPhoto>(); var seen = new HashSet<SynologyPhotoIdentity>(); var offset = 0; var more = false;
            do
            {
                var page = await _repository.PhotosAsync(query, offset, PageSize, token); EnsureCurrent(generation, token); Validate(page, offset, query);
                if (page.Items.Any(item => !seen.Add(item.Id))) throw Invalid();
                values.AddRange(page.Items.Where(item => !_confirmedDeleted.Contains(item.Id))); offset = page.NextOffset; more = page.HasMore;
            } while (more && offset < count);
            EnsureCurrent(generation, token); _query = query; _nextOffset = offset; HasMore = more; NeedsChangesRefresh = false; _memberReloadCount = null;
            Items.Clear(); _itemIds.Clear(); _pagedPhotoIds.Clear(); foreach (var photo in values) { Items.Add(photo); _itemIds.Add(photo.Id); _pagedPhotoIds.Add(photo.Id); }
            if (folders is not null)
            { Collections.Clear(); foreach (var folder in folders) Collections.Add(folder); _collectionOffset = folderOffset; HasMoreCollections = moreFolders; }
        }
        catch (OperationCanceledException) when (!IsCurrent(generation, token)) { }
        catch (Exception) { if (IsCurrent(generation, token)) { ErrorKey = query is SynologyPhotoQuery.Folder ? "PhotosFolderReloadFailed" : "PhotosEditReloadFailed"; HasMore = false; HasMoreCollections = false; } }
        finally { if (IsCurrent(generation, token)) { IsLoading = false; Changed(content: true); } }
    }

    private void AcceptCollections(IReadOnlyList<SynologyPhotoCollection> page)
    {
        if (page.Count > PageSize || page.Select(item => item.Id).Distinct().Count() != page.Count) throw Invalid();
        if ((Section == SynologyPhotosSection.Folders || Category is not null) && page.Any(item => item.Space != SelectedSpace)) throw Invalid();
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
        if (IsRequestList && page.Any(item => seen.Contains(item.Id))) throw Invalid();
        var fresh = page.Where(item => seen.Add(item.Id)).ToArray();
        if (page.Count == PageSize && fresh.Length == 0) throw Invalid();
        foreach (var entry in fresh) SharedEntries.Add(entry);
        _collectionOffset = checked(_collectionOffset + page.Count); HasMoreCollections = page.Count == PageSize;
    }

    private void RemoveConfirmed(SynologyPhoto photo)
    {
        if (!_confirmedDeleted.Add(photo.Id)) return;
        RemoveVisibleFilePhoto(photo);
        Changed(content: true);
    }

    internal static SynologyPhotoQuery Constrain(SynologyPhotoQuery query, long start, long end) => query switch
    {
        SynologyPhotoQuery.Timeline value => value with { Start = Math.Max(start, value.Start), End = Math.Min(end, value.End) },
        SynologyPhotoQuery.Search value => value with { Start = Math.Max(start, value.Start), End = Math.Min(end, value.End) },
        SynologyPhotoQuery.Filtered value => new SynologyPhotoQuery.Filtered(value.Filter with
        {
            StartTime = value.Filter.StartTime is { } lower ? Math.Max(start, lower) : null,
            EndTime = value.Filter.EndTime is { } upper ? Math.Min(end, upper) : null,
        }, Math.Max(start, value.Start), Math.Min(end, value.End)) { Space = value.Space },
        SynologyPhotoQuery.Category value => value with { Start = Math.Max(start, value.Start), End = Math.Min(end, value.End) },
        _ => throw Invalid(),
    };
    private static SynologyPhotoException Invalid() => new(SynologyPhotoFailure.InvalidResponse);
}
