using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private bool _exportStarting;
    private void RenderExportControls()
    {
        if (!_ready || _disposed) return;
        SaveButton.Label = _l.Get("PhotosExport"); AutomationProperties.SetName(SaveButton, SaveButton.Label);
        ExportSelectionMenu.Text = _l.Get("PhotosExportSelected"); ExportArchiveMenu.Text = _l.Get("PhotosExportCollection");
        ExportOriginalMenu.Text = PreviewExportOriginalMenu.Text = ExportArchiveOriginalMenu.Text = _l.Get("PhotosSaveOriginal");
        ExportJpegMenu.Text = PreviewExportJpegMenu.Text = ExportArchiveJpegMenu.Text = _l.Get("PhotosExportJpeg");
        ExportFullJpegMenu.Text = PreviewExportFullJpegMenu.Text = _l.Get("PhotosExportFullJpeg");
        var photos = SelectedManagementPhotos(); var folders = SelectedFileFolders();
        var ready = !_isSaving && !_exportStarting && !_model.IsLoading && !_managementPreparing && !_model.Slideshow.IsPresented;
        ExportSelectionMenu.IsEnabled = ready && photos.Length > 0 && photos.Length == LibraryGrid.SelectedItems.Count && _uploadPicker is not null;
        ExportFullJpegMenu.Visibility = Visible(photos.Length == 1 && photos[0].SimilarGroup is null && photos[0].SupportsOriginalSizeJpeg && _model.Repository.SupportsOriginalSizeJpeg);
        ExportJpegMenu.IsEnabled = photos.Length > 1 || photos.FirstOrDefault() is { SupportsOptimizedJpeg: true };
        var selectedCollection = LibraryGrid.SelectedItems.Count == 1 ? (LibraryGrid.SelectedItems[0] as SynologyPhotoCell)?.Collection : null;
        var album = _model.Album is not null || _model.AlbumListScope is not null && selectedCollection is not null;
        ExportArchiveMenu.IsEnabled = ready && (folders.Length > 0 || album || _model.Section == SynologyPhotosSection.Folders && _model.FolderHistory.Count > 0);
        PreviewExportJpegMenu.Visibility = Visible(_model.Preview.Photo?.SupportsOptimizedJpeg == true && _uploadPicker is not null);
        PreviewExportFullJpegMenu.Visibility = Visible(_model.Preview.Photo?.SupportsOriginalSizeJpeg == true && _model.Repository.SupportsOriginalSizeJpeg);
    }

    private async void ExportOriginal_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.Original, false);
    private async void ExportJpeg_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.OptimizedJpeg, false);
    private async void ExportFullJpeg_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.OriginalSizeJpeg, false);
    private async void PreviewExportJpeg_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.OptimizedJpeg, true);
    private async void PreviewExportFullJpeg_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.OriginalSizeJpeg, true);
    private async void ExportArchiveOriginal_Click(object sender, RoutedEventArgs args) => await ExportArchiveAsync(SynologyPhotoDownloadFormat.Original);
    private async void ExportArchiveJpeg_Click(object sender, RoutedEventArgs args) => await ExportArchiveAsync(SynologyPhotoDownloadFormat.OptimizedJpeg);

    private string ExportTemporaryDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Photos", "Transfers");
    private async Task<CancellationToken> BeginExportAsync()
    {
        _exportStarting = true; _saveCancellation?.Dispose(); _saveCancellation = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token);
        var token = _saveCancellation.Token;
        await _model.Automatic.YieldAsync();
        // 选择器立即取消时也不能在弹出层退场期间反复启停其所属按钮。
        foreach (var flyout in new[] { SaveButton.Flyout, MoreButton.Flyout }.Where(value => value?.IsOpen == true))
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            void Closed(object? sender, object args) => closed.TrySetResult();
            flyout!.Closed += Closed;
            try { flyout.Hide(); await closed.Task.WaitAsync(token); }
            finally { flyout.Closed -= Closed; }
        }
        token.ThrowIfCancellationRequested(); _isSaving = true; _exportStarting = false;
        RenderPreviewControls(); RenderManagementControls(); return _saveCancellation.Token;
    }
    private bool ExportCurrent(long generation, CancellationToken token) => !_disposed && generation == _viewGeneration && !token.IsCancellationRequested;
    private static string ExportErrorKey(Exception error) => error is SynologyPhotoException photo ? photo.Failure switch
    {
        SynologyPhotoFailure.Permission => "PhotosExportDenied", SynologyPhotoFailure.TargetChanged => "PhotosExportChanged",
        SynologyPhotoFailure.Unavailable => "PhotosExportUnavailable", SynologyPhotoFailure.SessionExpired => "PhotosUploadSignInAgain", _ => "PhotosSaveFailed",
    } : "PhotosSaveFailed";

    private async Task ExportPhotosAsync(SynologyPhotoDownloadFormat format, bool preview)
    {
        if (_disposed || _isSaving || _exportStarting || _model.Slideshow.IsPresented || preview && !CanSavePreview) return;
        var selection = preview ? _model.Preview.Photo is { } photo ? new[] { photo } : [] : SelectedManagementPhotos();
        if (selection.Length == 0 || !preview && selection.Length != LibraryGrid.SelectedItems.Count ||
            format == SynologyPhotoDownloadFormat.OriginalSizeJpeg && (selection.Length != 1 || !preview && selection[0].SimilarGroup is not null)) return;
        var generation = _viewGeneration; CancellationToken token = default;
        var completed = 0; var failed = 0; var preserved = 0; var total = selection.Length; var cancelled = false; var started = false;
        try
        {
            token = await BeginExportAsync();
            var single = (preview || format == SynologyPhotoDownloadFormat.OriginalSizeJpeg) && format != SynologyPhotoDownloadFormat.OptimizedJpeg;
            var location = single ? await _savePicker.PickSavePathAsync(Path.GetFileName(format == SynologyPhotoDownloadFormat.Original ? selection[0].Filename : Path.ChangeExtension(selection[0].Filename, ".jpg")))
                : _uploadPicker is null ? null : await _uploadPicker.PickSingleFolderPathAsync();
            if (location is null || !ExportCurrent(generation, token)) return;
            using var directory = ForegroundDownloadDirectoryLease.Acquire(single ? Path.GetDirectoryName(location)! : location);
            ShowSaveMessage("PhotosSaving", false);
            var photos = preview || format == SynologyPhotoDownloadFormat.OriginalSizeJpeg ? selection : await SynologyPhotoSaveService.ExpandSelectionAsync(_model.Repository, selection, token);
            token.ThrowIfCancellationRequested(); total = photos.Count; started = true;
            foreach (var item in photos)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var progress = new Progress<long>(done =>
                    {
                        if (!_isSaving || !ExportCurrent(generation, token)) return;
                        PreviewSaveBar.Message = SaveBar.Message = total == 1 && format == SynologyPhotoDownloadFormat.Original && item.SizeBytes > 0
                            ? _l.Format("PhotosSaveProgress", Math.Clamp(done / (double)item.SizeBytes, 0, 1).ToString("P0", System.Globalization.CultureInfo.CurrentCulture))
                            : _l.Format("PhotosExportProgress", completed + failed + 1, total);
                    });
                    var result = await new SynologyPhotoSaveService().SaveAsync(_model.Repository, item, format, ExportTemporaryDirectory,
                        async actual =>
                        {
                            token.ThrowIfCancellationRequested(); directory.Validate();
                            var path = single ? location : SynologyPhotoSaveService.AvailablePath(location, item.Filename, actual.Format);
                            return await WindowsTransactionalDownloadDestination.CreateAsync(path, allowReplaceExisting: single, validateTarget: directory.Validate);
                        }, progress, token);
                    completed++; if (format == SynologyPhotoDownloadFormat.OptimizedJpeg && result.Format == SynologyPhotoDownloadFormat.Original) preserved++;
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception error)
                {
                    failed++;
                    if (total == 1) { if (ExportCurrent(generation, token)) ShowSaveMessage(ExportErrorKey(error), true); return; }
                }
            }
        }
        catch (OperationCanceledException) { cancelled = true; }
        catch (Exception error) { if (ExportCurrent(generation, token)) ShowSaveMessage(ExportErrorKey(error), true); return; }
        finally
        {
            if (!_disposed && generation == _viewGeneration && started)
            {
                if (total > 1 || cancelled || preserved > 0)
                {
                    ShowSaveMessage("PhotosSaved", failed > 0);
                    PreviewSaveBar.Message = SaveBar.Message = _l.Format(cancelled ? "PhotosExportCancelled" : "PhotosExportResult", completed, total, failed, preserved);
                }
                else if (completed == 1) ShowSaveMessage("PhotosSaved", false);
            }
            _isSaving = false; _exportStarting = false; if (!_disposed) { RenderPreviewControls(); RenderManagementControls(); }
        }
    }

    private async Task ExportArchiveAsync(SynologyPhotoDownloadFormat format)
    {
        if (_disposed || _isSaving || _exportStarting) return;
        var photos = SelectedManagementPhotos(); var folders = SelectedFileFolders();
        var selected = LibraryGrid.SelectedItems.OfType<SynologyPhotoCell>().ToArray();
        var album = _model.CurrentAlbum; var albumId = _model.Album?.Id ?? (_model.AlbumListScope is not null && selected.Length == 1 ? selected[0].Collection?.Id : null);
        var currentFolder = _model.Section == SynologyPhotosSection.Folders ? _model.FolderHistory.LastOrDefault() : null;
        var generation = _viewGeneration; CancellationToken token = default;
        try
        {
            token = await BeginExportAsync();
            SynologyPhotoArchiveTarget target; string name;
            if (folders.Length > 0)
            {
                if (photos.Length + folders.Length != selected.Length || folders.Any(value => value.Path is null || value.ParentId is null)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                target = new SynologyPhotoArchiveTarget.Selection(photos, folders.Select(value => new SynologyPhotoFolder(value.Space, value.Id, value.ParentId!.Value, value.Path!)).ToArray());
                name = _l.Get("PhotosExportArchiveName");
            }
            else if (albumId is { } id)
            {
                album ??= await _model.Repository.AlbumAsync(id, token);
                target = new SynologyPhotoArchiveTarget.Album(album); name = album.Name;
            }
            else if (currentFolder is { Path: not null, ParentId: not null } folder)
            { target = new SynologyPhotoArchiveTarget.Folder(new(folder.Space, folder.Id, folder.ParentId.Value, folder.Path)); name = folder.Name; }
            else return;
            if (!ExportCurrent(generation, token)) return;
            if (!BoundedFileDownloadBatch.IsValidLocalName(name)) name = _l.Get("PhotosExportArchiveName");
            var path = await _savePicker.PickArchiveSavePathAsync(name + ".zip");
            if (path is null || !ExportCurrent(generation, token)) return;
            using var directory = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(path)!);
            ShowSaveMessage("PhotosSaving", false);
            await new SynologyPhotoSaveService().SaveArchiveAsync(_model.Repository, target, format, ExportTemporaryDirectory,
                async () => await WindowsTransactionalDownloadDestination.CreateAsync(path, allowReplaceExisting: true, validateTarget: directory.Validate),
                cancellationToken: token);
            if (ExportCurrent(generation, token)) ShowSaveMessage("PhotosSaved", false);
        }
        catch (OperationCanceledException) { if (!_disposed && generation == _viewGeneration) ShowSaveMessage("PhotosExportStopped", false); }
        catch (Exception error) { if (ExportCurrent(generation, token)) ShowSaveMessage(ExportErrorKey(error), true); }
        finally { _isSaving = false; _exportStarting = false; if (!_disposed) { RenderPreviewControls(); RenderManagementControls(); } }
    }
}
