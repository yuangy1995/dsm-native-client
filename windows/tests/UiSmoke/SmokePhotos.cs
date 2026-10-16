using LanStash.App.Features.Photos.Synology;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

/// <summary>合成 Photos 数据只存在于测试宿主，不读取登录配置或访问网络。</summary>
internal sealed partial class SmokePhotosRepository : ISynologyPhotosRepository
{
    private static string State => Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
    private static bool AlbumOnly => State is "albums-only" or "album-open" or "album-preview" or "pref-tasks-nohome";
    public Guid ProfileId { get; } = Guid.Parse("11111111-1111-1111-1111-111111111111");
    public Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(new SynologyPhotoAccess(State.StartsWith("pref-shared", StringComparison.Ordinal) || State.StartsWith("pref-members", StringComparison.Ordinal) ? SharedPreferences.CanAccess ? [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared] : [SynologyPhotoSpace.Personal] : AlbumOnly ? [] : State is "shared-only" or "req-shared-entry" or "req-shared-default" ? [SynologyPhotoSpace.Shared] :
            State.StartsWith("pref-tasks", StringComparison.Ordinal) || State.StartsWith("pref-maint-shared", StringComparison.Ordinal) || State.StartsWith("file-", StringComparison.Ordinal) || State.StartsWith("cond-", StringComparison.Ordinal) || State.StartsWith("fperm-", StringComparison.Ordinal) || State.StartsWith("regen-", StringComparison.Ordinal) || SupportsRecognitionManagement || State is "mixed-album" or "sources" or "shared-switch" or "shared-folders" or "shared-preview" or "preview-stress" or "filtered-empty" or "shared-pages" or "shared-error" or "manage-history-tag-cold"
                ? [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared] : [SynologyPhotoSpace.Personal], "synthetic") { IsAdministrator = (State.StartsWith("pref-shared", StringComparison.Ordinal) || State.StartsWith("pref-global", StringComparison.Ordinal) || State.StartsWith("pref-members", StringComparison.Ordinal) || State == "pref-maint-shared") && State is not ("pref-shared-nonadmin" or "pref-global-nonadmin" or "pref-members-nonadmin"), CanManageSharedSpace = State.StartsWith("pref-shared", StringComparison.Ordinal) || State.StartsWith("pref-members", StringComparison.Ordinal) ? SharedPreferences.CanAccess && SharedPreferences.Role == SynologyPhotoSharedRole.Management : State.StartsWith("cond-", StringComparison.Ordinal) || State.StartsWith("fperm-", StringComparison.Ordinal) || SupportsRecognitionManagement || State == "req-shared-default" });
    public Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoDay>>(State == "photo-empty" || query is SynologyPhotoQuery.Search
            ? [] : [new(new DateOnly(2026, 9, 16), State == "shared-pages" ? 120 : 8)]);
    public async Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit, CancellationToken cancellationToken = default)
    {
        if (query is SynologyPhotoQuery.Category { Kind: SynologyPhotoCategory.Similar })
        {
            var representatives = _similarGroups.Values.OfType<SynologyPhotoSimilarGroup>().Select(group => SimilarPhoto(group.TopPickId, query.Space) with { SimilarGroup = group with { Space = query.Space } }).Skip(offset).Take(limit).ToArray();
            return new(representatives, offset, offset + representatives.Length, false);
        }
        if (State == "export-similar")
        { var group = (await SimilarGroupAsync(11, query.Space, cancellationToken))!; return new([group.Photos[0]], offset, offset + 1, false); }
        if (State == "photo-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (State == "photo-error" || State == "shared-error" && query.Space == SynologyPhotoSpace.Shared)
            throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
        var count = State is "folder-cover-empty" or "slide-empty" or "export-empty" ? 0 : State is "shared-pages" or "slide-pages" ? 120 : 8;
        var date = new DateTimeOffset(2026, 9, 16, 0, 0, 0, TimeSpan.Zero);
        var items = Enumerable.Range(1, count).Skip(offset).Take(limit).Select(index =>
        {
            var album = query as SynologyPhotoQuery.Album;
            var source = album is null ? query.Space : index % 2 == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal;
            return new SynologyPhoto(new(ProfileId, source, index), State == "face-long-name" ? string.Concat(Enumerable.Repeat("Synthetic-photo-name-", 12)) + ".jpg" : $"Sample-{index:000}.jpg", 2048, date, date, (query as SynologyPhotoQuery.Folder)?.Id ?? 1, State is "slide-video" or "slide-video-pause" && index == 1 ? "video" : "photo")
            { Thumbnail = new(index, "synthetic"), AlbumContext = album is null ? null : new(album.Id, source == SynologyPhotoSpace.Shared ? 0 : 19, 23),
                Rating = SubmittedEdit is { Kind: SynologyPhotoEditKind.Rating, Value: { } rating } edit && edit.Photos.Any(photo => photo.Id.ItemId == index && photo.Id.Space == source) ? (int)rating : null };
        }).ToArray();
        if (query is SynologyPhotoQuery.Category { Kind: SynologyPhotoCategory.Subjects } && _recognitionChanges is { } changes)
        {
            items = items.Where(item => !changes.Any(change => change.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && change.RemovedPhotoIds.Contains(item.Id.ItemId))).ToArray();
            return new(items, offset, offset + items.Length, false);
        }
        if (State is "export-full-jpeg" or "export-jpeg" or "export-preserved")
            items = items.Select(item => item with { Filename = Path.ChangeExtension(item.Filename, State == "export-preserved" && item.Id.ItemId == 2 ? ".mp4" : ".heic") }).ToArray();
        return new(items, offset, offset + items.Length, offset + items.Length < count);
    }
    public Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        Task.FromResult(new SynologyPhotoCollection(1, "Synthetic library", 0) { Space = space, Path = "/" });
    public Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        State == "req-folder-pages" ? Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(parentId == 1 ? Enumerable.Range(2, 101).Skip(offset).Take(limit).Select(id =>
            new SynologyPhotoCollection(id, "Synthetic folder " + id, 1) { Space = space, Path = "/Synthetic folder " + id }).ToArray() : []) :
        State.StartsWith("cond-", StringComparison.Ordinal) ? ConditionFoldersAsync(parentId, offset, limit, space) :
        State.StartsWith("file-", StringComparison.Ordinal) ? FileFoldersAsync(parentId, offset, limit, space) :
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(parentId == 1 ? [new(2, "Synthetic folder", 1) { Space = space, Path = "/Synthetic folder" }] :
            parentId == 2 && State == "folder-cover-subfolder" ? [new(4, "Child", 2) { Space = space, Path = "/Synthetic folder/Child" }] : []);
    public Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(offset == 0 ? [new(41, "Synthetic shared album", Count: 8)] : []);
    public Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        Task.FromResult<IReadOnlySet<SynologyPhotoCategory>>((State.StartsWith("pref-global-category", StringComparison.Ordinal) || State == "pref-global-close") ? GlobalPreferences.People == true ? new HashSet<SynologyPhotoCategory> { SynologyPhotoCategory.People } : new HashSet<SynologyPhotoCategory>() : State == "pref-shared-category-off" ? SharedPreferences.People == true ? new HashSet<SynologyPhotoCategory> { SynologyPhotoCategory.People } : new HashSet<SynologyPhotoCategory>() : State.StartsWith("sim-", StringComparison.Ordinal) ? State == "sim-capability" ? new HashSet<SynologyPhotoCategory>() : new HashSet<SynologyPhotoCategory> { SynologyPhotoCategory.Similar } : State.StartsWith("concept-", StringComparison.Ordinal) ? new HashSet<SynologyPhotoCategory> { SynologyPhotoCategory.Subjects } : SupportsRecognitionManagement ? new HashSet<SynologyPhotoCategory> { SynologyPhotoCategory.People } : new HashSet<SynologyPhotoCategory>());
    public Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default) =>
        State.StartsWith("manage-", StringComparison.Ordinal) ? ManagementDetailAsync(photo) : Task.FromResult(State.StartsWith("regen-", StringComparison.Ordinal) && PreviewGenerationStarts + PreviewGenerationContinues > 0 ? photo with { Thumbnail = new(photo.Id.ItemId, "generated-preview") } : photo);
    public async Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default)
    {
        if (large && SlideReadGate is { } gate) await gate.Task;
        if (large && SlideFailRead) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (large && SlideDecodeFails) return [1, 2, 3];
        // 合成 PNG 编码可能同步等待 COM，不能在 XAML 容器更新回调内执行；生产解码仍由 UI 正常覆盖。
        return await Task.Run(async () =>
        {
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
            var pixels = Enumerable.Range(0, 64 * 64).SelectMany(index => new byte[]
            { (byte)(photo.Id.Space == SynologyPhotoSpace.Shared ? 190 : 75), (byte)(110 + index / 64), 160, 255 }).ToArray();
            SmokeSnapshot.RecordNativePhase("photo-thumbnail-set-pixels");
            encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Straight, 64, 64, 96, 96, pixels);
            SmokeSnapshot.RecordNativePhase("photo-thumbnail-pixels-set");
            await encoder.FlushAsync(); cancellationToken.ThrowIfCancellationRequested(); stream.Seek(0);
            using var reader = new Windows.Storage.Streams.DataReader(stream);
            await reader.LoadAsync((uint)stream.Size); var bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes); return bytes;
        }, cancellationToken);
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task VerifyPhotosAsync(FrameworkElement page, NavigationView navigation)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(page)!;
        var picker = (ComboBox)page.FindName("SourcePicker");
        var expectedPicker = state is "mixed-album" or "sources" or "shared-switch" or "shared-folders" or "shared-preview" or "preview-stress" or "filtered-empty" or "shared-pages" or "shared-error";
        if ((picker.Visibility == Visibility.Visible) != expectedPicker) throw new InvalidOperationException("来源选择器没有按实际来源数量显示。");
        if (state == "preview-stress")
        {
            var image = (Image)page.FindName("PreviewImage");
            var wasOpen = navigation.IsPaneOpen;
            try
            {
                for (var iteration = 0; iteration < 12; iteration++)
                {
                    var space = iteration % 2 == 0 ? SynologyPhotoSpace.Personal : SynologyPhotoSpace.Shared;
                    picker.SelectedIndex = iteration % 2;
                    for (var attempt = 0; attempt < 100 && (model.IsLoading || model.SelectedSpace != space); attempt++) await Task.Delay(20);
                    if (model.IsLoading || model.SelectedSpace != space || model.Items.Count != 8 || model.Items.Any(item => item.Id.Space != space))
                        throw new InvalidOperationException("快速切换照片来源后列表归属不正确。");
                    var photo = model.Items[iteration % model.Items.Count];
                    await model.Preview.OpenAsync(photo);
                    navigation.IsPaneOpen = !navigation.IsPaneOpen;
                    // 在异步图像解码完成前关闭并重开，覆盖迟到图像和侧栏布局竞争。
                    if (iteration % 3 == 0)
                    {
                        model.Preview.Close();
                        await model.Preview.OpenAsync(photo);
                    }
                    for (var attempt = 0; attempt < 100 && image.Source is null; attempt++) await Task.Delay(20);
                    if (model.Preview.Photo?.Id != photo.Id || model.Preview.ErrorKey is not null || image.Source is null)
                        throw new InvalidOperationException("快速切换后预览丢失或显示了其他来源。");
                    model.Preview.Close(); await Task.Delay(30);
                    if (image.Source is not null || page.FindName("PreviewRoot") is not FrameworkElement { Visibility: Visibility.Collapsed })
                        throw new InvalidOperationException("关闭预览后迟到图像重新显示。");
                }
            }
            finally { model.Preview.Close(); navigation.IsPaneOpen = wasOpen; }
        }
        if (state is "shared-switch" or "shared-folders" or "shared-preview" or "shared-pages" or "shared-error")
        {
            picker.SelectedIndex = 1;
            for (var index = 0; index < 100 && (model.IsLoading || model.SelectedSpace != SynologyPhotoSpace.Shared); index++) await Task.Delay(30);
            if (model.SelectedSpace != SynologyPhotoSpace.Shared) throw new InvalidOperationException("原生来源选择未接入共享读取。");
        }
        if (state is "albums-only" or "album-open" or "album-preview" or "mixed-album")
        {
            if (state == "mixed-album") await model.SelectSectionAsync(SynologyPhotosSection.Albums);
            if (model.Section != SynologyPhotosSection.Albums || model.Collections.Count != 1 || model.ErrorKey is not null)
                throw new InvalidOperationException("没有原图库权限时无法读取授权相册。");
            if (state != "albums-only")
            {
                await model.OpenCollectionAsync(model.Collections[0]);
                if (model.Items.Count != 8 || model.Items.Select(item => item.Id.Space).Distinct().Count() != 2 || model.Items.Any(item => item.AlbumContext?.AlbumId != 41))
                    throw new InvalidOperationException("相册混合来源或原上下文丢失。");
                if (picker.Visibility != Visibility.Collapsed) throw new InvalidOperationException("混合相册误显示单一图库来源。");
            }
        }
        if (state == "shared-folders")
        {
            ((Pivot)page.FindName("Sections")).SelectedIndex = (int)SynologyPhotosSection.Folders;
            for (var index = 0; index < 100 && (model.IsLoading || model.Section != SynologyPhotosSection.Folders); index++) await Task.Delay(30);
            if (model.Collections.Count != 1 || model.FolderHistory.Count != 1 || model.Collections[0].Space != SynologyPhotoSpace.Shared)
                throw new InvalidOperationException("共享目录导航没有保持原来源。");
        }
        if (state is "shared-preview" or "album-preview")
        {
            await model.Preview.OpenAsync(model.Items.First(item => item.Id.Space == SynologyPhotoSpace.Shared));
            for (var index = 0; index < 100 && ((Image)page.FindName("PreviewImage")).Source is null; index++) await Task.Delay(30);
            if (model.Preview.ErrorKey is not null || ((Image)page.FindName("PreviewImage")).Source is null ||
                page.FindName("PreviewRoot") is not FrameworkElement { Visibility: Visibility.Visible }) throw new InvalidOperationException("共享或相册照片无法原生预览。");
        }
        if (state == "filtered-empty")
        {
            await model.SearchAsync("synthetic missing");
            if (!model.IsFiltering || model.Items.Count != 0 || ((TextBlock)page.FindName("EmptyTitle")).Text != Localization.LocalizationService.Current.Get("PhotosFilteredEmpty"))
                throw new InvalidOperationException("筛选空状态不正确。");
        }
        if (state == "shared-pages")
        {
            await model.LoadNextAsync();
            if (model.Items.Count != 120 || model.HasMore || model.Items.Any(item => item.Id.Space != SynologyPhotoSpace.Shared))
                throw new InvalidOperationException("共享完整分页没有保持数量和来源。");
        }
        if (state == "shared-error" && (model.Items.Count != 0 || model.ErrorKey is null || page.FindName("ErrorBar") is not InfoBar { IsOpen: true }))
            throw new InvalidOperationException("共享读取失败保留了个人旧内容或没有恢复入口。");
        if (state is "shared-switch" or "shared-only" && (model.Items.Count != 8 || model.Items.Any(item => item.Id.Space != SynologyPhotoSpace.Shared)))
            throw new InvalidOperationException("共享列表仍混有个人照片。");
    }
}
