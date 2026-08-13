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
    private FileTextEditViewModel? _textEditViewModel;
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
    public event EventHandler? UnsavedDiscardRequested;

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

    public void AttachTextEdit(FileTextEditViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        if (ReferenceEquals(_textEditViewModel, viewModel))
        {
            return;
        }
        if (_textEditViewModel is not null)
        {
            _textEditViewModel.PropertyChanged -= TextEditViewModel_PropertyChanged;
        }
        _textEditViewModel = viewModel;
        _textEditViewModel.PropertyChanged += TextEditViewModel_PropertyChanged;
        UpdateTextEditState();
    }

    public bool HasUnsavedTextEdits =>
        _textEditViewModel?.HasUnsavedChanges ?? false;

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
        if (e.PropertyName is nameof(FilePreviewViewModel.Snapshot) or
            nameof(FilePreviewViewModel.IsCalculatingMD5) or
            nameof(FilePreviewViewModel.MD5Digest) or
            nameof(FilePreviewViewModel.MD5Failure) or
            nameof(FilePreviewViewModel.CanCalculateMD5) or
            nameof(FilePreviewViewModel.IsMD5Available))
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
        MD5Button.Visibility = _viewModel.IsMD5Available
            ? Visibility.Visible
            : Visibility.Collapsed;
        MD5Button.IsEnabled = _viewModel.CanCalculateMD5;
        MD5ResultText.Text = MD5StatusText(_viewModel);
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

    private async void MD5_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is null || !_viewModel.CanCalculateMD5)
        {
            return;
        }
        MD5Button.IsEnabled = false;
        try
        {
            await _viewModel.CalculateMD5Async();
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            // ViewModel 会把领域失败映射为本地化状态，事件处理器不重复弹窗。
        }
        finally
        {
            MD5Button.IsEnabled = _viewModel.CanCalculateMD5;
        }
    }

    private static string MD5StatusText(FilePreviewViewModel viewModel)
    {
        if (viewModel.IsCalculatingMD5)
        {
            return LocalizationService.Current.Get("FileMd5Calculating");
        }
        if (viewModel.MD5Digest is { } digest)
        {
            return digest;
        }
        return viewModel.MD5Failure switch
        {
            FileMD5Failure.Timeout => LocalizationService.Current.Get("FileMd5TimedOut"),
            FileMD5Failure.AlreadyRunning =>
                LocalizationService.Current.Get("FileMd5AlreadyRunning"),
            null => string.Empty,
            _ => LocalizationService.Current.Get("FileMd5Failed"),
        };
    }

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

    private void TextEditViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(UpdateTextEditState);
    }

    private void UpdateTextEditState()
    {
        if (_disposed || _textEditViewModel is null)
        {
            return;
        }

        var vm = _textEditViewModel;
        var isEditing = vm.IsEditing;
        var isViewing = vm.IsViewing;
        var canEdit = vm.CanEdit;
        var canFormat = vm.CanFormat;

        // 查看模式显示只读文本和编辑按钮。
        TextEditButtonBar.Visibility = isViewing && canEdit
            ? Visibility.Visible
            : Visibility.Collapsed;

        // 编辑模式显示文本框和工具栏。
        TextEditBox.Visibility = isEditing
            ? Visibility.Visible
            : Visibility.Collapsed;
        TextEditToolbar.Visibility = isEditing
            ? Visibility.Visible
            : Visibility.Collapsed;
        TextEditFormatButton.IsEnabled = canFormat;

        // 编辑时隐藏只读预览，否则显示只读预览。
        TextPreview.Visibility = isEditing
            ? Visibility.Collapsed
            : Visibility.Visible;

        // 同步文本内容。
        if (isEditing)
        {
            TextEditBox.Text = vm.EditableText;
            TextEditBox.Focus(FocusState.Programmatic);
        }
        else
        {
            if (_viewModel?.Snapshot is { Text: { } text })
            {
                TextPreview.Text = text;
            }
        }

        // 仅在内容实际变化时启用保存按钮。
        TextEditSaveButton.IsEnabled = vm.CanSubmitSave;

        // 更新保存状态。
        var localization = LocalizationService.Current;
        if (vm.IsSaveCompleted)
        {
            TextEditSaveStatus.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Success;
            TextEditSaveStatus.Title = localization.Get("FileTextEdit_SavedMessage");
            TextEditSaveStatus.Message = string.Empty;
            TextEditSaveStatus.IsOpen = true;
            TextEditSaveStatus.Visibility = Visibility.Visible;
        }
        else if (vm.IsSaveFailed)
        {
            TextEditSaveStatus.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error;
            TextEditSaveStatus.Title = localization.Get("FileTextEdit_SaveFailedMessage");
            TextEditSaveStatus.Message = string.Empty;
            TextEditSaveStatus.IsOpen = true;
            TextEditSaveStatus.Visibility = Visibility.Visible;
        }
        else if (vm.IsSaveNeedsReview)
        {
            TextEditSaveStatus.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Warning;
            TextEditSaveStatus.Title = localization.Get("FileTextEdit_NeedsReviewTitle");
            TextEditSaveStatus.Message = localization.Get("FileTextEdit_NeedsReviewMessage");
            TextEditSaveStatus.IsOpen = true;
            TextEditSaveStatus.Visibility = Visibility.Visible;
        }
        else if (vm.IsSavingIndicator)
        {
            TextEditSaveStatus.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational;
            TextEditSaveStatus.Title = localization.Get("FileTextEdit_Saving");
            TextEditSaveStatus.Message = string.Empty;
            TextEditSaveStatus.IsOpen = true;
            TextEditSaveStatus.Visibility = Visibility.Visible;
        }
        else if (vm.IsViewing)
        {
            TextEditSaveStatus.IsOpen = false;
            TextEditSaveStatus.Visibility = Visibility.Collapsed;
        }
    }

    private async void TextEdit_Click(object sender, RoutedEventArgs e)
    {
        if (_textEditViewModel is null || _disposed)
        {
            return;
        }

        TextEditButton.IsEnabled = false;
        try
        {
            var entered = await _textEditViewModel.EnterEditModeAsync();
            if (!entered)
            {
                TextEditButton.IsEnabled = true;
            }
        }
        catch
        {
            TextEditButton.IsEnabled = true;
        }
    }

    private async void TextEditSave_Click(object sender, RoutedEventArgs e)
    {
        if (_textEditViewModel is null || _disposed)
        {
            return;
        }

        TextEditSaveButton.IsEnabled = false;
        try
        {
            var localization = LocalizationService.Current;
            var confirmation = new ContentDialog
            {
                Title = localization.Get("FileTextEdit_SaveConfirmTitle"),
                Content = localization.Get("FileTextEdit_SaveConfirmMessage"),
                PrimaryButtonText = localization.Get("FileTextEdit_SaveConfirmAction"),
                CloseButtonText = localization.Get("ActionCancel"),
                DefaultButton = ContentDialogButton.Close,
                XamlRoot = XamlRoot,
            };
            if (await confirmation.ShowAsync() != ContentDialogResult.Primary)
            {
                return;
            }
            await _textEditViewModel.SaveAsync();
        }
        finally
        {
            if (_textEditViewModel.IsEditing)
            {
                TextEditSaveButton.IsEnabled = _textEditViewModel.CanSubmitSave;
            }
        }
    }

    private void TextEditCancel_Click(object sender, RoutedEventArgs e)
    {
        if (_textEditViewModel is null || _disposed)
        {
            return;
        }

        if (_textEditViewModel.HasUnsavedChanges)
        {
            UnsavedDiscardRequested?.Invoke(this, EventArgs.Empty);
        }
        else
        {
            _textEditViewModel.CancelEdit();
        }
    }

    public void ConfirmDiscardTextEdits()
    {
        _textEditViewModel?.CancelEdit();
    }

    private async void TextEditFormat_Click(object sender, RoutedEventArgs e)
    {
        if (_textEditViewModel is null || _disposed)
        {
            return;
        }

        TextEditFormatButton.IsEnabled = false;
        try
        {
            await _textEditViewModel.FormatAsync();
        }
        finally
        {
            TextEditFormatButton.IsEnabled = _textEditViewModel.CanFormat &&
                _textEditViewModel.IsEditing;
        }
    }

    private void TextEditDismissStatus_Click(object sender, RoutedEventArgs e)
    {
        TextEditSaveStatus.IsOpen = false;
        TextEditSaveStatus.Visibility = Visibility.Collapsed;
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
        if (_textEditViewModel is not null)
        {
            _textEditViewModel.PropertyChanged -= TextEditViewModel_PropertyChanged;
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
