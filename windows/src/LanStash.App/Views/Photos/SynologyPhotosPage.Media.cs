using System.ComponentModel;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage
{
    private MediaPlayer? _player;
    private StrictRangeMediaSource? _playerSource;
    private IReadOnlyMediaSource? _displayedSource;
    private byte[]? _displayedImage;
    private long _imageGeneration;
    private CancellationTokenSource? _saveCancellation;
    private bool _isSaving;

    private async void PreviewChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_disposed) return;
        RenderPreviewControls();
        var preview = _model.Preview;
        if (preview.Photo is null)
        {
            _imageGeneration++; _displayedImage = null; PreviewImage.Source = null; ClosePlayer();
            return;
        }
        if (!ReferenceEquals(_displayedSource, preview.MediaSource))
        {
            ClosePlayer();
            if (preview.MediaSource is { } source)
            {
                try
                {
                    _displayedSource = source; _playerSource = StrictRangeMediaSource.FromPhotos(source);
                    _player = new MediaPlayer { AutoPlay = true };
                    _player.MediaFailed += PlayerFailed; _player.MediaEnded += PlayerEnded;
                    _player.Source = MediaSource.CreateFromStream(_playerSource.Stream, _playerSource.ContentType);
                    PlayerElement.SetMediaPlayer(_player);
                }
                catch (Exception) { ClosePlayer(); PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true; }
            }
        }
        if (!ReferenceEquals(_displayedImage, preview.ImageBytes))
        {
            _displayedImage = preview.ImageBytes; PreviewImage.Source = null; var generation = ++_imageGeneration;
            if (preview.ImageBytes is { } bytes)
            {
                try
                {
                    var bitmap = await SynologyPhotoImages.DecodeAsync(bytes, 2560, _viewCancellation.Token);
                    if (!_disposed && generation == _imageGeneration && ReferenceEquals(preview.ImageBytes, bytes))
                    { PreviewImage.Source = bitmap.Value; ImageScroll.ChangeView(null, null, 1, disableAnimation: true); FitPreviewImage(); }
                }
                catch (OperationCanceledException) { }
                catch (Exception) { if (!_disposed && generation == _imageGeneration) { PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true; } }
            }
        }
    }
    private void RenderPreviewControls()
    {
        if (!_ready || _disposed) return;
        var preview = _model.Preview;
        PreviewRoot.Visibility = Visible(preview.Photo is not null);
        LibraryRoot.IsHitTestVisible = preview.Photo is null;
        PreviewTitle.Text = preview.Photo?.Filename ?? "";
        PreviewProgress.IsActive = preview.IsLoading; PreviewProgress.Visibility = Visible(preview.IsLoading);
        PreviewErrorBar.IsOpen = preview.ErrorKey is not null; PreviewErrorBar.Message = preview.ErrorKey is { } key ? _l.Get(key) : "";
        PlayerElement.Visibility = Visible(preview.MediaSource is not null);
        ImageScroll.Visibility = Visible(preview.MediaSource is null);
        MotionButton.Visibility = Visible(preview.Photo?.MediaType == "live"); MotionButton.IsEnabled = !preview.IsLoading;
        MotionButton.Label = _l.Get(preview.IsPlayingMotion ? "PhotosStopLive" : "PhotosPlayLive");
        CancelSaveButton.Visibility = Visible(_isSaving); PreviewCancelSaveButton.Visibility = Visible(_isSaving);
        PreviewDeletionBar.IsOpen = _model.Deletion.Pending is not null || _model.Deletion.ErrorKey is not null;
        PreviewDeletionBar.Message = _l.Get(_model.Deletion.ErrorKey ?? "PhotosDeletePending");
        PreviewReviewButton.Visibility = Visible(_model.Deletion.Pending is not null);
        PreviewReviewButton.IsEnabled = !_model.Deletion.IsBusy;
        SaveButton.IsEnabled = !_isSaving && !preview.IsLoading && preview.Photo is not null;
        DeleteButton.IsEnabled = _model.Deletion.Enabled && !_model.Deletion.IsBusy && _model.Deletion.Pending is null && !preview.IsLoading;
        var index = preview.Photo is { } photo ? _model.Items.ToList().FindIndex(item => item.Id == photo.Id) : -1;
        PreviousPhotoButton.IsEnabled = index > 0; NextPhotoButton.IsEnabled = index >= 0 && index < _model.Items.Count - 1;
    }
    private void PlayerFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (_disposed || !ReferenceEquals(sender, _player)) return;
        PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true;
    });
    private void PlayerEnded(MediaPlayer sender, object args) => DispatcherQueue.TryEnqueue(() =>
    { if (!_disposed && ReferenceEquals(sender, _player) && _model.Preview.IsPlayingMotion) _model.Preview.FinishMotion(); });
    private void ClosePlayer()
    {
        if (_player is { } player)
        {
            player.MediaFailed -= PlayerFailed; player.MediaEnded -= PlayerEnded;
            player.Pause(); player.Source = null; PlayerElement.SetMediaPlayer(null); player.Dispose(); _player = null;
        }
        _playerSource?.Dispose(); _playerSource = null; _displayedSource = null;
    }
    private void ImageScroll_SizeChanged(object sender, SizeChangedEventArgs args) => FitPreviewImage();
    private void FitPreviewImage()
    { PreviewImage.Width = Math.Max(1, ImageScroll.ActualWidth); PreviewImage.Height = Math.Max(1, ImageScroll.ActualHeight); }
    private async Task AdjacentAsync(int direction)
    {
        var photo = _model.Preview.Photo;
        if (photo is null || _model.Deletion.IsBusy) return;
        var index = _model.Items.ToList().FindIndex(item => item.Id == photo.Id) + direction;
        if (index >= 0 && index < _model.Items.Count) await _model.Preview.OpenAsync(_model.Items[index]);
    }
    private async void PreviousPhoto_Click(object sender, RoutedEventArgs args) => await AdjacentAsync(-1);
    private async void NextPhoto_Click(object sender, RoutedEventArgs args) => await AdjacentAsync(1);
    private void ClosePreview_Click(object sender, RoutedEventArgs args) => _model.Preview.Close();
    private async void PreviewRetry_Click(object sender, RoutedEventArgs args)
    { if (_model.Preview.Photo is { } photo) await _model.Preview.OpenAsync(photo, _model.Preview.IsPlayingMotion); }
    private async void Motion_Click(object sender, RoutedEventArgs args)
    { if (_model.Preview.IsPlayingMotion) _model.Preview.FinishMotion(); else await _model.Preview.PlayMotionAsync(); }

    private async void Save_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _isSaving || _model.Preview.Photo is not { } photo) return;
        _isSaving = true; var generation = _viewGeneration;
        _saveCancellation?.Dispose(); _saveCancellation = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token);
        var token = _saveCancellation.Token; RenderPreviewControls();
        try
        {
            var target = await _savePicker.PickSavePathAsync(Path.GetFileName(photo.Filename));
            if (target is null || _disposed || generation != _viewGeneration || token.IsCancellationRequested) return;
            var temporaryDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Photos", "Transfers");
            ShowSaveMessage("PhotosSaving", false);
            var progress = new Progress<long>(done =>
            {
                if (!_disposed && generation == _viewGeneration && photo.SizeBytes > 0)
                    PreviewSaveBar.Message = SaveBar.Message = _l.Format("PhotosSaveProgress", Math.Clamp(done / (double)photo.SizeBytes, 0, 1).ToString("P0", System.Globalization.CultureInfo.CurrentCulture));
            });
            await new SynologyPhotoSaveService().SaveAsync(_model.Repository, photo, temporaryDirectory,
                async () => await WindowsTransactionalDownloadDestination.CreateAsync(target, allowReplaceExisting: true), progress, token);
            if (!_disposed && generation == _viewGeneration) ShowSaveMessage("PhotosSaved", false);
        }
        catch (OperationCanceledException) { if (!_disposed) { SaveBar.IsOpen = false; PreviewSaveBar.IsOpen = false; } }
        catch (Exception) { if (!_disposed && generation == _viewGeneration) ShowSaveMessage("PhotosSaveFailed", true); }
        finally { _isSaving = false; if (!_disposed) RenderPreviewControls(); }
    }
    private void ShowSaveMessage(string key, bool error)
    {
        PreviewSaveBar.Message = SaveBar.Message = _l.Get(key);
        PreviewSaveBar.Severity = SaveBar.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Informational;
        PreviewSaveBar.IsOpen = SaveBar.IsOpen = true;
    }
    private void CancelSave_Click(object sender, RoutedEventArgs args) => _saveCancellation?.Cancel();

    private async void Delete_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _dialog is not null || _model.Preview.Photo is not { } photo) return;
        var generation = _viewGeneration;
        await _model.Deletion.PrepareAsync(photo);
        if (_disposed || generation != _viewGeneration || _model.Deletion.Candidate?.Id != photo.Id) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = _l.Get("PhotosDeleteOriginal"), Content = _l.Format("PhotosDeleteConfirmBody", photo.Filename),
            PrimaryButtonText = _l.Get("PhotosDeleteOriginal"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            _dialog = dialog;
            var result = await dialog.ShowAsync();
            if (!_disposed && generation == _viewGeneration && result == ContentDialogResult.Primary) await _model.Deletion.ConfirmAsync();
            else _model.Deletion.CancelCandidate();
        }
        finally { if (ReferenceEquals(_dialog, dialog)) _dialog = null; }
    }
    private async void Details_Click(object sender, RoutedEventArgs args)
    {
        if (_disposed || _dialog is not null || _model.Preview.Photo is not { } photo) return;
        var rows = new StackPanel { Spacing = 10, MinWidth = 240, MaxWidth = 520 };
        void Add(string key, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            var group = new StackPanel { Spacing = 2 };
            group.Children.Add(new TextBlock { Text = _l.Get(key), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            group.Children.Add(new TextBlock { Text = value, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap }); rows.Children.Add(group);
        }
        var culture = System.Globalization.CultureInfo.CurrentCulture;
        Add("PhotosMetadataFilename", photo.Filename);
        Add("PhotosMetadataTaken", photo.TakenAt.LocalDateTime.ToString("f", culture));
        Add("PhotosMetadataIndexed", photo.IndexedAt.LocalDateTime.ToString("f", culture));
        Add("PhotosMetadataSize", _l.Format("PhotosBytes", photo.SizeBytes.ToString("N0", culture)));
        if (photo.Width is { } width && photo.Height is { } height) Add("PhotosMetadataResolution", _l.Format("PhotosResolution", width, height));
        Add("PhotosMetadataDescription", photo.Description); Add("PhotosFilterCamera", photo.Camera); Add("PhotosFilterLens", photo.Lens);
        Add("PhotosFilterAperture", photo.Aperture); Add("PhotosFilterExposure", photo.ExposureTime); Add("PhotosFilterFocal", photo.FocalLength); Add("PhotosFilterIso", photo.Iso);
        if (photo.Rating is { } rating) Add("PhotosFilterRating", rating.ToString(culture));
        if (photo.Duration is { } seconds) Add("PhotosMetadataDuration", _l.Format("PhotosSeconds", seconds.ToString("N1", culture)));
        if (photo.Address.Count > 0) Add("PhotosFilterLocation", string.Join(Environment.NewLine, photo.Address));
        if (photo.Latitude is { } latitude && photo.Longitude is { } longitude) Add("PhotosMetadataCoordinates", _l.Format("PhotosCoordinates", latitude, longitude));
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = _l.Get("PhotosDetails"), CloseButtonText = _l.Get("PhotosClose"),
            Content = new ScrollViewer { Content = rows, MaxHeight = 600, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        try { _dialog = dialog; await dialog.ShowAsync(); }
        finally { if (ReferenceEquals(_dialog, dialog)) _dialog = null; }
    }
}
