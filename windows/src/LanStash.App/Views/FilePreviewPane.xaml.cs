using LanStash.App.Features.Files.Preview;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Data.Pdf;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Streams;

namespace LanStash.App.Views;

public sealed partial class FilePreviewPane : UserControl, IDisposable
{
    private FilePreviewViewModel? _viewModel;
    private MediaSource? _mediaSource;
    private MediaPlayer? _mediaPlayer;
    private FilePreviewViewModel? _mediaViewModel;
    private long _mediaPresenterGeneration;
    private PdfDocument? _pdfDocument;
    private uint _pdfPageIndex;
    private long _renderGeneration;
    private CancellationTokenSource? _presenterCancellation;
    private Task _presenterTask = Task.CompletedTask;
    private bool _isClosingPresenter;
    private bool _disposed;
    private int _imageRotation;

    public FilePreviewPane() => InitializeComponent();

    public event EventHandler? CloseRequested;
    public event EventHandler<FilePreviewKeyboardCloseRequestedEventArgs>? KeyboardCloseRequested;
    public event EventHandler? RetryRequested;
    public event EventHandler<FilePreviewSaveCopyRequestedEventArgs>? SaveCopyRequested;

    public void Attach(FilePreviewViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        if (ReferenceEquals(_viewModel, viewModel))
        {
            return;
        }
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        }
        _viewModel = viewModel;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        UpdateState();
    }

    public void FocusHeading() => BackButton.Focus(FocusState.Programmatic);

    public void SetSaveCopyEnabled(bool isEnabled)
    {
        DetailsSaveCopyButton.IsEnabled = isEnabled;
        FailedSaveCopyButton.IsEnabled = isEnabled;
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(FilePreviewViewModel.Snapshot))
        {
            DispatcherQueue.TryEnqueue(UpdateState);
        }
    }

    private void UpdateState()
    {
        if (_disposed || _isClosingPresenter || _viewModel is null)
        {
            return;
        }
        var snapshot = _viewModel.Snapshot;
        FileNameText.Text = snapshot.Item?.Name ?? string.Empty;
        PreparingState.Visibility = snapshot.Phase == FilePreviewPhase.Preparing
            ? Visibility.Visible
            : Visibility.Collapsed;
        DetailsOnlyState.Visibility = snapshot.Phase is
            FilePreviewPhase.DetailsOnly or FilePreviewPhase.Cancelled
                ? Visibility.Visible
                : Visibility.Collapsed;
        FailedState.Visibility = snapshot.Phase == FilePreviewPhase.Failed
            ? Visibility.Visible
            : Visibility.Collapsed;
        ReadyState.Visibility = snapshot.Phase == FilePreviewPhase.Ready
            ? Visibility.Visible
            : Visibility.Collapsed;

        var localization = LocalizationService.Current;
        ProgressText.Text = snapshot.TotalBytes is > 0
            ? localization.Format(
                "FilePreviewProgress",
                snapshot.CompletedBytes,
                snapshot.TotalBytes.Value)
            : localization.Format("FilePreviewProgressUnknownTotal", snapshot.CompletedBytes);
        ApplyUnavailableText(snapshot.UnavailableReason, snapshot.Phase == FilePreviewPhase.Cancelled);
        RetryDetailsButton.Visibility = snapshot.Phase == FilePreviewPhase.Cancelled
            ? Visibility.Visible
            : Visibility.Collapsed;

        StartPresenter(snapshot);
    }

    private void StartPresenter(FilePreviewSnapshot snapshot)
    {
        var generation = Interlocked.Increment(ref _renderGeneration);
        _presenterCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _presenterCancellation = cancellation;
        var previous = _presenterTask;
        _presenterTask = PresentSnapshotAsync(previous, snapshot, generation, cancellation);
    }

    private async Task PresentSnapshotAsync(
        Task previous,
        FilePreviewSnapshot snapshot,
        long generation,
        CancellationTokenSource cancellation)
    {
        try
        {
            try
            {
                await previous.ConfigureAwait(true);
            }
            catch
            {
                // 前一代只负责完成自身清理，不得覆盖当前预览。
            }
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrentPresenter(generation, cancellation.Token))
            {
                return;
            }
            ReleasePresenterCore();
            if (snapshot.Phase != FilePreviewPhase.Ready)
            {
                return;
            }

            var localization = LocalizationService.Current;
            switch (snapshot.Kind)
            {
                case FilePreviewKind.Text:
                    TextPreview.Text = snapshot.Text ?? string.Empty;
                    TextTruncatedNotice.IsOpen = snapshot.IsTextTruncated;
                    AutomationProperties.SetName(
                        TextPreview,
                        localization.Format("FilePreviewTextAutomationName", snapshot.Item?.Name ?? string.Empty));
                    TextScroller.Visibility = Visibility.Visible;
                    break;
                case FilePreviewKind.Image:
                    await PresentImageAsync(snapshot, generation, cancellation.Token);
                    break;
                case FilePreviewKind.Pdf:
                    await PresentPdfAsync(snapshot, generation, cancellation.Token);
                    break;
                case FilePreviewKind.Audio:
                case FilePreviewKind.Video:
                    if (snapshot.Media is { } media)
                    {
                        _mediaSource = MediaSource.CreateFromStream(media.Stream, media.ContentType);
                        _mediaPlayer = new MediaPlayer
                        {
                            AutoPlay = false,
                        };
                        _mediaViewModel = _viewModel;
                        _mediaPresenterGeneration = generation;
                        _mediaPlayer.MediaFailed += MediaPlayer_MediaFailed;
                        MediaPreview.SetMediaPlayer(_mediaPlayer);
                        _mediaPlayer.Source = _mediaSource;
                        AutomationProperties.SetName(
                            MediaPreview,
                            localization.Format("FilePreviewMediaAutomationName", snapshot.Item?.Name ?? string.Empty));
                        MediaPreview.Visibility = Visibility.Visible;
                    }
                    break;
            }
        }
        catch (OperationCanceledException) when (!IsCurrentPresenter(generation, cancellation.Token))
        {
        }
        catch
        {
            if (IsCurrentPresenter(generation, cancellation.Token) && _viewModel is not null)
            {
                ReleasePresenterCore();
                await _viewModel.ReportPresentationFailureAsync();
            }
        }
        finally
        {
            if (ReferenceEquals(_presenterCancellation, cancellation))
            {
                _presenterCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    private async Task PresentImageAsync(
        FilePreviewSnapshot snapshot,
        long generation,
        CancellationToken cancellationToken)
    {
        if (snapshot.Artifact?.File is not { } file)
        {
            return;
        }
        using var stream = await file.OpenReadAsync().AsTask(cancellationToken);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellationToken);
        var scale = Math.Min(
            1d,
            2048d / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        stream.Seek(0);
        var bitmap = new BitmapImage();
        bitmap.DecodePixelType = DecodePixelType.Physical;
        bitmap.DecodePixelWidth = checked((int)Math.Max(1, Math.Round(decoder.PixelWidth * scale)));
        bitmap.DecodePixelHeight = checked((int)Math.Max(1, Math.Round(decoder.PixelHeight * scale)));
        await bitmap.SetSourceAsync(stream).AsTask(cancellationToken);
        if (!IsCurrentPresenter(generation, cancellationToken))
        {
            return;
        }
        ImagePreview.Source = bitmap;
        ResetImageTransform();
        AutomationProperties.SetName(
            ImagePreview,
            LocalizationService.Current.Format(
                "FilePreviewImageAutomationName",
                snapshot.Item?.Name ?? string.Empty));
        ImagePreviewSurface.Visibility = Visibility.Visible;
    }

    private async Task PresentPdfAsync(
        FilePreviewSnapshot snapshot,
        long generation,
        CancellationToken cancellationToken)
    {
        if (snapshot.Artifact?.File is not { } file)
        {
            return;
        }
        var document = await PdfDocument.LoadFromFileAsync(file).AsTask(cancellationToken);
        if (!IsCurrentPresenter(generation, cancellationToken))
        {
            return;
        }
        _pdfDocument = document;
        _pdfPageIndex = 0;
        PdfPreview.Visibility = Visibility.Visible;
        await RenderPdfPageAsync(generation, cancellationToken);
    }

    private async Task RenderPdfPageAsync(long generation, CancellationToken cancellationToken)
    {
        if (_pdfDocument is null || _pdfDocument.PageCount == 0)
        {
            return;
        }
        using var page = _pdfDocument.GetPage(_pdfPageIndex);
        using var stream = new InMemoryRandomAccessStream();
        var scale = Math.Min(1d, 2048d / Math.Max(page.Size.Width, page.Size.Height));
        var renderOptions = new PdfPageRenderOptions
        {
            DestinationWidth = checked((uint)Math.Max(1, Math.Round(page.Size.Width * scale))),
            DestinationHeight = checked((uint)Math.Max(1, Math.Round(page.Size.Height * scale))),
        };
        await page.RenderToStreamAsync(stream, renderOptions).AsTask(cancellationToken);
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream).AsTask(cancellationToken);
        if (!IsCurrentPresenter(generation, cancellationToken))
        {
            return;
        }
        PdfPageImage.Source = bitmap;
        var localization = LocalizationService.Current;
        PdfPageText.Text = localization.Format(
            "FilePreviewPdfPage",
            _pdfPageIndex + 1,
            _pdfDocument.PageCount);
        AutomationProperties.SetName(
            PdfPageImage,
            localization.Format(
                "FilePreviewPdfAutomationName",
                _viewModel?.Snapshot.Item?.Name ?? string.Empty,
                _pdfPageIndex + 1,
                _pdfDocument.PageCount));
        PreviousPdfPage.IsEnabled = _pdfPageIndex > 0;
        NextPdfPage.IsEnabled = _pdfPageIndex + 1 < _pdfDocument.PageCount;
    }

    private void ApplyUnavailableText(FilePreviewUnavailableReason reason, bool cancelled)
    {
        var localization = LocalizationService.Current;
        var suffix = cancelled
            ? "Cancelled"
            : reason switch
            {
                FilePreviewUnavailableReason.UnknownSize => "UnknownSize",
                FilePreviewUnavailableReason.Empty => "Empty",
                FilePreviewUnavailableReason.TooLarge => "TooLarge",
                _ => "Unsupported",
            };
        UnavailableTitle.Text = localization.Get($"FilePreview{suffix}Title");
        UnavailableMessage.Text = localization.Get($"FilePreview{suffix}Message");
    }

    private bool IsCurrentPresenter(long generation, CancellationToken cancellationToken) =>
        !_disposed &&
        !cancellationToken.IsCancellationRequested &&
        generation == Volatile.Read(ref _renderGeneration);

    private void MediaPlayer_MediaFailed(
        MediaPlayer sender,
        MediaPlayerFailedEventArgs args)
    {
        var generation = _mediaPresenterGeneration;
        var viewModel = _mediaViewModel;
        DispatcherQueue.TryEnqueue(
            async () => await ReportMediaPresentationFailureAsync(sender, generation, viewModel));
    }

    private async Task ReportMediaPresentationFailureAsync(
        MediaPlayer sender,
        long generation,
        FilePreviewViewModel? viewModel)
    {
        if (_disposed ||
            _isClosingPresenter ||
            viewModel is null ||
            !ReferenceEquals(_viewModel, viewModel) ||
            !ReferenceEquals(_mediaViewModel, viewModel) ||
            !ReferenceEquals(_mediaPlayer, sender) ||
            generation != _mediaPresenterGeneration ||
            generation != Volatile.Read(ref _renderGeneration))
        {
            return;
        }

        ReleasePresenterCore();
        await viewModel.ReportPresentationFailureAsync();
    }

    public void PauseMediaPlayback()
    {
        if (!_disposed)
        {
            _mediaPlayer?.Pause();
        }
    }

    private void ReleasePresenterCore()
    {
        var mediaPlayer = _mediaPlayer;
        _mediaPlayer = null;
        _mediaViewModel = null;
        _mediaPresenterGeneration = 0;
        if (mediaPlayer is not null)
        {
            mediaPlayer.MediaFailed -= MediaPlayer_MediaFailed;
            mediaPlayer.Pause();
            mediaPlayer.Source = null;
        }
        MediaPreview.SetMediaPlayer(null);
        MediaPreview.Visibility = Visibility.Collapsed;
        mediaPlayer?.Dispose();
        _mediaSource?.Dispose();
        _mediaSource = null;
        _pdfDocument = null;
        PdfPageImage.Source = null;
        PdfPreview.Visibility = Visibility.Collapsed;
        ImagePreview.Source = null;
        ImagePreviewSurface.Visibility = Visibility.Collapsed;
        ResetImageTransform();
        TextPreview.Text = string.Empty;
        TextScroller.Visibility = Visibility.Collapsed;
    }

    private void Close_Click(object sender, RoutedEventArgs e)
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private void CloseAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        var request = new FilePreviewKeyboardCloseRequestedEventArgs();
        KeyboardCloseRequested?.Invoke(this, request);
        args.Handled = true;
        if (request.Handled)
        {
            return;
        }
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private async void Cancel_Click(object sender, RoutedEventArgs e)
    {
        await CloseAsync();
        if (_viewModel is not null)
        {
            await _viewModel.CancelAsync();
        }
    }

    private void Retry_Click(object sender, RoutedEventArgs e) =>
        RetryRequested?.Invoke(this, EventArgs.Empty);

    private void SaveCopy_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel?.Snapshot is
                { ProfileId: { } profileId, Item: { IsDirectory: false } item } snapshot &&
            snapshot.IsSaveCopyAvailable())
        {
            SaveCopyRequested?.Invoke(
                this,
                new FilePreviewSaveCopyRequestedEventArgs(
                    new FilePreviewSaveCopyTarget(profileId, item)));
        }
    }

    private void ImageZoomOut_Click(object sender, RoutedEventArgs e) => ChangeImageZoom(-0.25f);

    private void ImageZoomIn_Click(object sender, RoutedEventArgs e) => ChangeImageZoom(0.25f);

    private void ImageFit_Click(object sender, RoutedEventArgs e) => FitImage();

    private void ImageRotateLeft_Click(object sender, RoutedEventArgs e) => RotateImage(-90);

    private void ImageRotateRight_Click(object sender, RoutedEventArgs e) => RotateImage(90);

    private void ZoomInAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args) =>
        HandleImageAccelerator(args, () => ChangeImageZoom(0.25f));

    private void ZoomOutAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args) =>
        HandleImageAccelerator(args, () => ChangeImageZoom(-0.25f));

    private void FitImageAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args) =>
        HandleImageAccelerator(args, FitImage);

    private void RotateLeftAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args) =>
        HandleImageAccelerator(args, () => RotateImage(-90));

    private void RotateRightAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args) =>
        HandleImageAccelerator(args, () => RotateImage(90));

    private void HandleImageAccelerator(
        KeyboardAcceleratorInvokedEventArgs args,
        Action action)
    {
        if (ImagePreviewSurface.Visibility != Visibility.Visible)
        {
            return;
        }
        action();
        args.Handled = true;
    }

    private void ChangeImageZoom(float delta)
    {
        var target = Math.Clamp(
            ImageScroller.ZoomFactor + delta,
            ImageScroller.MinZoomFactor,
            ImageScroller.MaxZoomFactor);
        ImageScroller.ChangeView(null, null, target, true);
    }

    private void FitImage()
    {
        ImageScroller.ChangeView(0, 0, 1, true);
        UpdateImageTransformStatus();
    }

    private void RotateImage(int delta)
    {
        _imageRotation = ((_imageRotation + delta) % 360 + 360) % 360;
        ImageRotationTransform.Rotation = _imageRotation;
        UpdateImageRotationScale();
        UpdateImageTransformStatus();
    }

    private void ResetImageTransform()
    {
        _imageRotation = 0;
        ImageRotationTransform.Rotation = 0;
        ImageRotationTransform.ScaleX = 1;
        ImageRotationTransform.ScaleY = 1;
        ImageScroller.ChangeView(0, 0, 1, true);
        UpdateImageTransformStatus();
    }

    private void ImagePreview_SizeChanged(object sender, SizeChangedEventArgs e) =>
        UpdateImageRotationScale();

    private void UpdateImageRotationScale()
    {
        var swapsAxes = _imageRotation is 90 or 270;
        var width = ImagePreview.ActualWidth;
        var height = ImagePreview.ActualHeight;
        var scale = swapsAxes && width > 0 && height > 0
            ? Math.Min(width / height, height / width)
            : 1;
        ImageRotationTransform.ScaleX = scale;
        ImageRotationTransform.ScaleY = scale;
    }

    private void ImageScroller_ViewChanged(object sender, ScrollViewerViewChangedEventArgs e) =>
        UpdateImageTransformStatus();

    private void UpdateImageTransformStatus()
    {
        ImageZoomOutButton.IsEnabled = ImageScroller.ZoomFactor > ImageScroller.MinZoomFactor;
        ImageZoomInButton.IsEnabled = ImageScroller.ZoomFactor < ImageScroller.MaxZoomFactor;
        ImageTransformStatus.Text = LocalizationService.Current.Format(
            "FilePreviewImageTransformStatus",
            Math.Round(ImageScroller.ZoomFactor * 100),
            _imageRotation);
    }

    private void PreviousPdfPage_Click(object sender, RoutedEventArgs e)
    {
        if (_pdfPageIndex == 0)
        {
            return;
        }
        _pdfPageIndex--;
        StartPdfPageRender();
    }

    private void NextPdfPage_Click(object sender, RoutedEventArgs e)
    {
        if (_pdfDocument is null || _pdfPageIndex + 1 >= _pdfDocument.PageCount)
        {
            return;
        }
        _pdfPageIndex++;
        StartPdfPageRender();
    }

    private void StartPdfPageRender()
    {
        var generation = Interlocked.Increment(ref _renderGeneration);
        _presenterCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        _presenterCancellation = cancellation;
        var previous = _presenterTask;
        _presenterTask = RenderPdfPageAfterAsync(previous, generation, cancellation);
    }

    private async Task RenderPdfPageAfterAsync(
        Task previous,
        long generation,
        CancellationTokenSource cancellation)
    {
        try
        {
            try
            {
                await previous.ConfigureAwait(true);
            }
            catch
            {
            }
            cancellation.Token.ThrowIfCancellationRequested();
            await RenderPdfPageAsync(generation, cancellation.Token);
        }
        catch (OperationCanceledException) when (!IsCurrentPresenter(generation, cancellation.Token))
        {
        }
        catch
        {
            if (IsCurrentPresenter(generation, cancellation.Token) && _viewModel is not null)
            {
                ReleasePresenterCore();
                await _viewModel.ReportPresentationFailureAsync();
            }
        }
        finally
        {
            if (ReferenceEquals(_presenterCancellation, cancellation))
            {
                _presenterCancellation = null;
            }
            cancellation.Dispose();
        }
    }

    public async Task CloseAsync()
    {
        if (_disposed)
        {
            return;
        }
        _isClosingPresenter = true;
        Interlocked.Increment(ref _renderGeneration);
        _presenterCancellation?.Cancel();
        try
        {
            await _presenterTask.ConfigureAwait(true);
        }
        catch
        {
        }
        _presenterCancellation = null;
        _presenterTask = Task.CompletedTask;
        ReleasePresenterCore();
        _isClosingPresenter = false;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        }
        Interlocked.Increment(ref _renderGeneration);
        _presenterCancellation?.Cancel();
        ReleasePresenterCore();
    }
}

public sealed class FilePreviewKeyboardCloseRequestedEventArgs : EventArgs
{
    public bool Handled { get; set; }
}

public sealed class FilePreviewSaveCopyRequestedEventArgs : EventArgs
{
    public FilePreviewSaveCopyRequestedEventArgs(FilePreviewSaveCopyTarget target) =>
        Target = target;

    public FilePreviewSaveCopyTarget Target { get; }
}
