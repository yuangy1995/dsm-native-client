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
    private bool _imageDecodePending;
    private bool _imageDecodeFailed;
    private CancellationTokenSource? _saveCancellation;
    private bool _isSaving;

    private async void PreviewChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (_disposed) return;
        RenderPreviewControls();
        var preview = _model.Preview;
        if (preview.Photo is null)
        {
            _imageGeneration++; _imageDecodePending = false; _imageDecodeFailed = false; _displayedImage = null; PreviewImage.Source = null; ClosePlayer();
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
                    _playerSlideGeneration = _model.Slideshow.MediaGeneration;
                    _player = new MediaPlayer { AutoPlay = !_model.Slideshow.IsPresented || _model.Slideshow.IsPlaying };
                    _player.MediaFailed += PlayerFailed; _player.MediaEnded += PlayerEnded;
                    _player.MediaOpened += PlayerOpened;
                    _player.Source = MediaSource.CreateFromStream(_playerSource.Stream, _playerSource.ContentType);
                    PlayerElement.SetMediaPlayer(_player);
                }
                catch (Exception) { ClosePlayer(); _model.Slideshow.PlaybackFailed(_playerSlideGeneration); PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true; }
            }
        }
        if (!ReferenceEquals(_displayedImage, preview.ImageBytes))
        {
            _displayedImage = preview.ImageBytes; PreviewImage.Source = null; _imageDecodePending = false; _imageDecodeFailed = false; var generation = ++_imageGeneration;
            var slideGeneration = _model.Slideshow.MediaGeneration;
            if (preview.ImageBytes is { } bytes)
            {
                _imageDecodePending = true; RenderPreviewControls();
                try
                {
                    var bitmap = await SynologyPhotoImages.DecodeAsync(bytes, 2560, _viewCancellation.Token);
                    if (!_disposed && generation == _imageGeneration && ReferenceEquals(preview.ImageBytes, bytes))
                    { PreviewImage.Source = bitmap.Value; ImageScroll.ChangeView(null, null, 1, disableAnimation: true); FitPreviewImage(); _model.Slideshow.MediaPresented(slideGeneration); }
                }
                catch (OperationCanceledException) { }
                catch (Exception) { if (!_disposed && generation == _imageGeneration) { _imageDecodeFailed = true; _model.Slideshow.PlaybackFailed(slideGeneration); PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true; } }
                finally
                {
                    // 让图片或错误状态先完成本轮 XAML 更新，再开放其弹出菜单。
                    DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
                    {
                        if (_disposed || generation != _imageGeneration) return;
                        _imageDecodePending = false; SaveButton.IsEnabled = CanSavePreview; RenderExportControls(); RenderPreviewGenerationControls();
                    });
                }
            }
        }
    }
    private void RenderPreviewControls()
    {
        if (!_ready || _disposed) return;
        var preview = _model.Preview;
        PreviewRoot.Visibility = Visible(preview.Photo is not null || _model.Slideshow.IsPresented);
        LibraryRoot.IsHitTestVisible = preview.Photo is null && !_model.Slideshow.IsPresented;
        PreviewTitle.Text = preview.Photo?.Filename ?? "";
        RenderPreviewInformation();
        PreviewProgress.IsActive = preview.IsLoading; PreviewProgress.Visibility = Visible(preview.IsLoading);
        var previewError = preview.ErrorKey ?? (preview.MediaSource is null && _imageDecodeFailed ? "PhotosMediaFailed" : null);
        PreviewErrorBar.IsOpen = previewError is not null; PreviewErrorBar.Message = previewError is { } key ? _l.Get(key) : "";
        PlayerElement.Visibility = Visible(preview.MediaSource is not null);
        ImageScroll.Visibility = Visible(preview.MediaSource is null);
        MotionButton.Visibility = Visible(preview.Photo?.MediaType == "live"); MotionButton.IsEnabled = !preview.IsLoading;
        MotionButton.Label = _l.Get(preview.IsPlayingMotion ? "PhotosStopLive" : "PhotosPlayLive");
        CancelSaveButton.Visibility = Visible(_isSaving); PreviewCancelSaveButton.Visibility = Visible(_isSaving);
        PreviewDeletionBar.IsOpen = _model.Deletion.Pending is not null || _model.Deletion.ErrorKey is not null;
        PreviewDeletionBar.Message = _l.Get(_model.Deletion.ErrorKey ?? "PhotosDeletePending");
        PreviewReviewButton.Visibility = Visible(_model.Deletion.Pending is not null);
        PreviewReviewButton.IsEnabled = !_model.Deletion.IsBusy;
        SaveButton.IsEnabled = CanSavePreview;
        DeleteButton.IsEnabled = _model.Deletion.Enabled && !_model.Deletion.IsBusy && _model.Deletion.Pending is null && !preview.IsLoading;
        EditPhotoButton.Visibility = Visible(_model.Repository.SupportsManagement);
        EditPhotoButton.IsEnabled = !_managementPreparing && !_model.Deletion.IsBusy && !preview.IsLoading && preview.Photo is not null;
        EditPhotoFacesButton.Visibility = Visible(preview.Photo is { MediaType: not "video" } facePhoto && _model.Repository.SupportsManualFaceEditing(facePhoto.Id.Space));
        EditPhotoFacesButton.IsEnabled = EditPhotoButton.IsEnabled && preview.ImageBytes is not null &&
            (preview.Photo?.Id.Space == SynologyPhotoSpace.Personal || _model.CanManageSharedSpace);
        RenderSimilarControls();
        var navigation = preview.SimilarDetail?.Photos ?? _model.Items.ToArray();
        var index = preview.Photo is { } photo ? navigation.ToList().FindIndex(item => item.Id == photo.Id) : -1;
        PreviousPhotoButton.IsEnabled = index > 0; NextPhotoButton.IsEnabled = index >= 0 && index < navigation.Count - 1;
        RenderSlideshowControls();
        RenderExportControls();
        RenderPreviewGenerationControls();
        RenderAutomaticPreviews();
    }
    private bool CanSavePreview => !_isSaving && !_exportStarting && !_model.Preview.IsLoading && !_imageDecodePending && _model.Preview.Photo is not null;
    private void RenderPreviewInformation()
    {
        if (!_ready || _disposed) return;
        var preview = _model.Preview;
        PreviewPhotoInfo.Visibility = Visible(_model.DisplaySettings?.ShowsPreviewInfo == true && preview.Photo is { MediaType: not ("video" or "video360") } && preview.MediaSource is null && _dialog is null);
        PreviewPhotoInfoText.Text = preview.Photo is { } photo ? string.Join(Environment.NewLine,
            new[] { _model.DisplayDate(photo.TakenAt), string.Join(", ", photo.Address.Take(3)), photo.Description }.Where(value => !string.IsNullOrWhiteSpace(value))) : "";
    }
    private void PlayerFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (_disposed || !ReferenceEquals(sender, _player)) return;
        _model.Slideshow.PlaybackFailed(_playerSlideGeneration);
        PreviewErrorBar.Message = _l.Get("PhotosMediaFailed"); PreviewErrorBar.IsOpen = true;
    });
    private void PlayerOpened(MediaPlayer sender, object args) => DispatcherQueue.TryEnqueue(() =>
    { if (!_disposed && ReferenceEquals(sender, _player)) _model.Slideshow.MediaPresented(_playerSlideGeneration); });
    private void PlayerEnded(MediaPlayer sender, object args) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (_disposed || !ReferenceEquals(sender, _player)) return;
        if (_model.Slideshow.IsPresented) await _model.Slideshow.VideoEndedAsync(_playerSlideGeneration);
        else if (_model.Preview.IsPlayingMotion) _model.Preview.FinishMotion();
    });
    private void ClosePlayer()
    {
        if (_player is { } player)
        {
            player.MediaFailed -= PlayerFailed; player.MediaEnded -= PlayerEnded;
            player.MediaOpened -= PlayerOpened;
            player.Pause(); player.Source = null; PlayerElement.SetMediaPlayer(null); player.Dispose(); _player = null;
        }
        _playerSource?.Dispose(); _playerSource = null; _displayedSource = null;
    }
    private void ImageScroll_SizeChanged(object sender, SizeChangedEventArgs args) => FitPreviewImage();
    private void FitPreviewImage()
    {
        PreviewImageHost.Width = PreviewImage.Width = Math.Max(1, ImageScroll.ActualWidth);
        PreviewImageHost.Height = PreviewImage.Height = Math.Max(1, ImageScroll.ActualHeight);
    }
    private async Task AdjacentAsync(int direction)
    {
        if (_model.Slideshow.IsPresented) { await _model.Slideshow.AdvanceAsync(direction); return; }
        var photo = _model.Preview.Photo;
        if (photo is null || _model.Deletion.IsBusy) return;
        var navigation = _model.Preview.SimilarDetail?.Photos ?? _model.Items.ToArray();
        var index = navigation.ToList().FindIndex(item => item.Id == photo.Id) + direction;
        if (index >= 0 && index < navigation.Count) await _model.Preview.OpenAsync(navigation[index]);
    }
    private async void PreviousPhoto_Click(object sender, RoutedEventArgs args) => await AdjacentAsync(-1);
    private async void NextPhoto_Click(object sender, RoutedEventArgs args) => await AdjacentAsync(1);
    private void ClosePreview_Click(object sender, RoutedEventArgs args) => _model.Preview.Close();
    private async void PreviewRetry_Click(object sender, RoutedEventArgs args)
    { if (_model.Slideshow.IsPresented) { if (!_model.Slideshow.IsPlaying) await _model.Slideshow.ToggleAsync(); }
      else if (_model.Preview.Photo is { } photo) await _model.Preview.OpenAsync(photo, _model.Preview.IsPlayingMotion); }
    private async void Motion_Click(object sender, RoutedEventArgs args)
    { if (_model.Preview.IsPlayingMotion) _model.Preview.FinishMotion(); else await _model.Preview.PlayMotionAsync(); }

    private async void Save_Click(object sender, RoutedEventArgs args) => await ExportPhotosAsync(SynologyPhotoDownloadFormat.Original, true);
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
        await _model.Automatic.YieldAsync();
        await _model.Deletion.PrepareAsync(photo);
        if (_disposed || generation != _viewGeneration || _model.Deletion.Candidate?.Id != photo.Id) return;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, Title = _l.Get("PhotosDeleteOriginal"), Content = _l.Format("PhotosDeleteConfirmBody", photo.Filename),
            PrimaryButtonText = _l.Get("PhotosDeleteOriginal"), CloseButtonText = _l.Get("PhotosCancel"), DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            SetPhotoDialog(dialog); await _model.Automatic.YieldAsync();
            var result = await ShowPhotoDialogAsync(dialog);
            if (!_disposed && generation == _viewGeneration && result == ContentDialogResult.Primary) await _model.Deletion.ConfirmAsync();
            else _model.Deletion.CancelCandidate();
        }
        finally { if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
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
        Add("PhotosMetadataTaken", _model.DisplayDate(photo.TakenAt));
        Add("PhotosMetadataIndexed", _model.DisplayDate(photo.IndexedAt));
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
        try { SetPhotoDialog(dialog); await _model.Automatic.YieldAsync(); await ShowPhotoDialogAsync(dialog); }
        finally { if (ReferenceEquals(_dialog, dialog)) SetPhotoDialog(null); }
    }
}
