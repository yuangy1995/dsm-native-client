using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private readonly SemaphoreSlim _folderCoverSlots = new(4, 4);
    private async Task<BitmapImage?> LoadFolderCoverImageAsync(SynologyPhotoCollection folder, CancellationToken token)
    {
        await _folderCoverSlots.WaitAsync(token);
        try
        {
            var images = await _model.Repository.FolderCoverImagesAsync(folder, token);
            return images.Count > 0 ? (await SynologyPhotoImages.DecodeAsync(images[0], 240, token)).Value : null;
        }
        finally { _folderCoverSlots.Release(); }
    }
    private async Task ApplyFolderResultAsync(SynologyPhotoFolderChange change)
    {
        await _model.ApplyFolderChangeAsync(change);
        if (_disposed || change.State != SynologyPhotoChangeState.Completed || change.Edit.Kind != SynologyPhotoFolderEditKind.Cover || change.Result is not { } folder ||
            folder.Space != _model.SelectedSpace) return;
        var item = LibraryGrid.Items.OfType<SynologyPhotoCell>().FirstOrDefault(cell => cell.Collection?.Id == folder.Id);
        if (item is null || LibraryGrid.ContainerFromItem(item) is not FrameworkElement container || FindChild<Image>(container) is not { } image) return;
        try
        {
            var generation = _viewGeneration; var bitmap = await LoadFolderCoverImageAsync(folder.Collection, _viewCancellation.Token);
            if (!_disposed && generation == _viewGeneration && LibraryGrid.ContainerFromItem(item) == container) image.Source = bitmap;
        }
        catch (Exception) { /* 已保存事实独立保留，下一次显示目录时再取封面。 */ }
    }
    private async Task ShowFolderCoverAsync(SynologyPhotoCollection target)
    {
        if (_disposed || _dialog is not null || _managementPreparing) return;
        _managementPreparing = true; RenderManagementControls(); var generation = _viewGeneration; var closed = false; var loading = false;
        SynologyPhotoFolder? original = null; SynologyPhotoFolderChange? submitted = null;
        var history = new List<SynologyPhotoFolder>(); var cells = new List<SynologyPhotoCell>(); var folderIds = new HashSet<long>(); var photoIds = new HashSet<SynologyPhotoIdentity>();
        CancellationTokenSource? previewCancellation = null;
        var folderOffset = 0; var photoOffset = 0; var moreFolders = true; var morePhotos = true;
        var location = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap }; var progress = new ProgressRing { Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, DisplayMemberPath = nameof(SynologyPhotoCell.Title), MaxHeight = 220 };
        var preview = new Image { Height = 100, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(preview, _l.Get("PhotosSelectedCoverPreview"));
        AutomationProperties.SetName(list, _l.Get("PhotosChooseCoverPhoto"));
        var back = QueueButton("PhotosBack"); var open = QueueButton("PhotosOpenFolder"); var more = QueueButton("PhotosLoadMore"); var retry = QueueButton("PhotosRefresh");
        var navigation = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; navigation.Children.Add(back); navigation.Children.Add(open);
        var paging = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; paging.Children.Add(more); paging.Children.Add(retry);
        var panel = new StackPanel { MinWidth = 290, MaxWidth = 620, Spacing = 12 };
        foreach (var child in new FrameworkElement[] { location, navigation, progress, list, preview, message, paging }) panel.Children.Add(child);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = _l.Get("PhotosSetFolderCover"),
            PrimaryButtonText = _l.Get("PhotosUseAsCover"), CloseButtonText = _l.Get("PhotosCancel"), IsPrimaryButtonEnabled = false,
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 } };
        bool Current() => !closed && !_disposed && generation == _viewGeneration;
        void Render()
        {
            location.Text = history.LastOrDefault()?.Name ?? target.Name; progress.IsActive = loading; progress.Visibility = Visible(loading);
            back.IsEnabled = !loading && history.Count > 1; open.IsEnabled = !loading && list.SelectedItem is SynologyPhotoCell { Collection: not null };
            back.Visibility = Visible(history.Count > 1); open.Visibility = Visible(list.SelectedItem is SynologyPhotoCell { Collection: not null });
            more.IsEnabled = !loading && (moreFolders || morePhotos); retry.IsEnabled = !loading; list.IsEnabled = !loading;
            more.Visibility = Visible(moreFolders || morePhotos); list.Visibility = Visible(cells.Count > 0);
            dialog.IsPrimaryButtonEnabled = !loading && original is not null && list.SelectedItem is SynologyPhotoCell { Photo: not null };
        }
        async Task Load(bool reset)
        {
            if (!Current() || loading) return; loading = true; Render();
            try
            {
                if (original is null)
                {
                    var value = await _model.Repository.FolderAsync(target.Id, target.Space, _viewCancellation.Token);
                    if (!Current()) return;
                    if (value.IsRoot || target.Path is { } path && value.Path != path || target.ParentId is { } parent && value.ParentId != parent)
                        throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    original = value;
                    history.Add(original);
                }
                if (reset) { cells.Clear(); folderIds.Clear(); photoIds.Clear(); folderOffset = photoOffset = 0; moreFolders = morePhotos = true; list.ItemsSource = Array.Empty<SynologyPhotoCell>(); }
                var folder = history[^1]; var additions = new List<SynologyPhotoCell>();
                if (moreFolders)
                {
                    var page = await _model.Repository.FoldersAsync(folder.Id, folderOffset, 100, folder.Sort?.Descending == true, _viewCancellation.Token, folder.Space);
                    if (page.Count > 100 || page.Any(value => value.ParentId != folder.Id || value.Space != folder.Space || folderIds.Contains(value.Id)) || page.DistinctBy(value => value.Id).Count() != page.Count) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                    additions.AddRange(page.Select(value => new SynologyPhotoCell { Id = $"folder:{value.Id}", Collection = value }));
                    folderOffset += page.Count; moreFolders = page.Count == 100; foreach (var value in page) folderIds.Add(value.Id);
                }
                else if (morePhotos)
                {
                    var page = await _model.Repository.PhotosAsync(new SynologyPhotoQuery.Folder(folder.Id, folder.Sort) { Space = folder.Space }, photoOffset, 100, _viewCancellation.Token);
                    if (page.Offset != photoOffset || page.NextOffset != photoOffset + page.Items.Count || page.Items.Count > 100 ||
                        page.HasMore && page.Items.Count == 0 || page.Items.Any(photo => photo.Id.ProfileId != _model.Repository.ProfileId || photo.Id.Space != folder.Space || photo.FolderId != folder.Id || photo.AlbumContext is not null || photoIds.Contains(photo.Id)) ||
                        page.Items.DistinctBy(photo => photo.Id).Count() != page.Items.Count) throw new SynologyPhotoException(SynologyPhotoFailure.InvalidResponse);
                    additions.AddRange(page.Items.Select(PhotoCell)); photoOffset = page.NextOffset; morePhotos = page.HasMore; foreach (var photo in page.Items) photoIds.Add(photo.Id);
                }
                if (!Current()) return; cells.AddRange(additions); list.ItemsSource = cells.ToArray();
                message.Text = cells.Count == 0 && !moreFolders && !morePhotos ? _l.Get(history.Count > 1 ? "PhotosCoverFolderEmpty" : "PhotosCoverFolderEmptyRoot") : "";
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { loading = false; if (Current()) Render(); }
            if (Current() && cells.Count == 0 && !moreFolders && morePhotos && message.Text.Length == 0) await Load(false);
        }
        list.SelectionChanged += async (_, _) =>
        {
            if (!Current()) return;
            previewCancellation?.Cancel(); previewCancellation?.Dispose(); previewCancellation = null; preview.Source = null; preview.Visibility = Visibility.Collapsed; Render();
            if (list.SelectedItem is not SynologyPhotoCell { Photo: { Thumbnail: not null } photo }) return;
            var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token); previewCancellation = cancellation;
            try
            {
                var bitmap = await _thumbnails.GetAsync(photo, cancellation.Token);
                if (Current() && ReferenceEquals(previewCancellation, cancellation) && !cancellation.IsCancellationRequested)
                { preview.Source = bitmap; preview.Visibility = Visibility.Visible; }
            }
            catch (Exception) { /* 缩略图失败不扩大选择范围，仍可按原照片名称选择。 */ }
        };
        back.Click += async (_, _) => { if (history.Count > 1 && !loading) { history.RemoveAt(history.Count - 1); await Load(true); } };
        open.Click += async (_, _) =>
        {
            if (loading || list.SelectedItem is not SynologyPhotoCell { Collection: { } child } || original is null) return;
            loading = true; Render(); var entered = false;
            try
            {
                var value = await _model.Repository.FolderAsync(child.Id, target.Space, _viewCancellation.Token);
                if (!Current()) return;
                if (value.ParentId != history[^1].Id || !value.Path.StartsWith(original.Path + "/", StringComparison.Ordinal)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                history.Add(value); entered = true;
            }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { loading = false; if (Current()) Render(); }
            if (entered && Current()) await Load(true);
        };
        more.Click += async (_, _) => await Load(false); retry.Click += async (_, _) => await Load(true);
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; if (loading || original is null || list.SelectedItem is not SynologyPhotoCell { Photo: { } photo }) return;
            var deferral = args.GetDeferral(); loading = true; Render();
            try { submitted = await _model.Repository.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Cover, original) { Photo = photo }); if (Current()) args.Cancel = false; }
            catch (Exception error) { if (Current()) message.Text = _l.Get(ManagementErrorKey(error)); }
            finally { loading = false; if (Current()) Render(); deferral.Complete(); }
        };
        dialog.Closed += (_, _) => { closed = true; previewCancellation?.Cancel(); };
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); var showing = ShowPhotoDialogAsync(dialog); await Load(true); await showing; }
        finally { closed = true; var cancellation = previewCancellation; previewCancellation = null; cancellation?.Cancel(); cancellation?.Dispose(); _managementPreparing = false; if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); RenderManagementControls(); }
        if (submitted is not null && !_disposed && generation == _viewGeneration)
        { await ApplyFolderResultAsync(submitted); if (!_disposed && generation == _viewGeneration) await ShowFolderChangesAsync(submitted.Id); }
    }
}
