using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private CancellationTokenSource? _attachmentReadCancellation;
    private string? _attachmentConversationId;

    private void UpdateAttachmentState()
    {
        var conversationId = _viewModel.SelectedConversation?.Id;
        if (!string.Equals(_attachmentConversationId, conversationId, StringComparison.Ordinal))
        {
            _attachmentConversationId = conversationId;
            CancelAttachmentRead();
        }

        ChooseAttachmentButton.IsEnabled = _attachmentComposer.CanSelect;
        AttachmentCard.Visibility = Visible(_attachmentComposer.Draft is not null || _attachmentComposer.IsSending);
        AttachmentName.Text = _attachmentComposer.Draft?.FileName ?? string.Empty;
        AttachmentSize.Text = _attachmentComposer.Draft is { } draft
            ? FormatByteCount(draft.Length)
            : string.Empty;
        RemoveAttachmentButton.Visibility = Visible(_attachmentComposer.CanRemove);
        CancelAttachmentButton.Visibility = Visible(_attachmentComposer.IsSending);
    }

    private async void ChooseAttachment_Click(object sender, RoutedEventArgs e)
    {
        if (!_attachmentComposer.CanSelect ||
            (Application.Current as App)?.MainWindow is not { } window)
        {
            return;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(window));
        var picker = new FileOpenPicker(windowId);
        picker.FileTypeFilter.Add("*");
        var file = await picker.PickSingleFileAsync();
        if (file is null || _disposed)
        {
            return;
        }

        var info = new FileInfo(file.Path);
        if (!info.Exists || info.Length < 0)
        {
            return;
        }

        var path = file.Path;
        _attachmentComposer.Select(new(
            info.Name,
            MediaTypeForPath(path),
            info.Length,
            cancellationToken => OpenAttachmentSourceAsync(path, cancellationToken)));
        UpdateState();
    }

    private void RemoveAttachment_Click(object sender, RoutedEventArgs e)
    {
        _attachmentComposer.Remove();
        UpdateState();
    }

    private void CancelAttachment_Click(object sender, RoutedEventArgs e)
    {
        _attachmentComposer.Cancel();
        UpdateState();
    }

    private void ChooseAttachmentAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_attachmentComposer.CanSelect)
        {
            return;
        }
        args.Handled = true;
        ChooseAttachment_Click(ChooseAttachmentButton, new RoutedEventArgs());
    }

    private async void AttachmentPreview_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatMessageAttachmentItem item } || !item.IsImage)
        {
            return;
        }

        await ShowAttachmentPreviewAsync(item);
    }

    private async void AttachmentSave_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: ChatMessageAttachmentItem item } || !item.CanSave)
        {
            return;
        }

        await SaveAttachmentAsync(item);
    }

    private async Task ShowAttachmentPreviewAsync(ChatMessageAttachmentItem item)
    {
        if (!CanReadAttachmentThumbnail(item) ||
            (Application.Current as App)?.MainWindow is null)
        {
            return;
        }

        using var cancellation = BeginAttachmentRead(item);
        try
        {
            var thumbnail = await _repository.ReadAttachmentThumbnailAsync(
                item.MessageId,
                item.Attachment,
                cancellation.Token);
            if (!IsCurrentAttachmentRead(item, cancellation))
            {
                return;
            }

            var bitmap = new BitmapImage();
            using var bytes = new MemoryStream(thumbnail.Bytes, writable: false);
            await bitmap.SetSourceAsync(bytes.AsRandomAccessStream());
            if (!IsCurrentAttachmentRead(item, cancellation))
            {
                return;
            }

            var preview = new Image
            {
                Source = bitmap,
                Stretch = Stretch.Uniform,
                MaxHeight = 560,
                MaxWidth = 720,
            };
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = LocalizationService.Current.Get("ChatAttachmentPreviewTitle"),
                CloseButtonText = LocalizationService.Current.Get("ChatAttachmentClose"),
                Content = preview,
            };
            await dialog.ShowAsync();
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            ShowAttachmentStatus("ChatAttachmentPreviewFailed", InfoBarSeverity.Warning);
        }
        finally
        {
            EndAttachmentRead(cancellation);
        }
    }

    private async Task SaveAttachmentAsync(ChatMessageAttachmentItem item)
    {
        if (!item.CanSave ||
            (Application.Current as App)?.MainWindow is not { } window)
        {
            return;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(window));
        var extension = Path.GetExtension(item.FileName);
        var picker = new FileSavePicker(windowId)
        {
            SuggestedFileName = item.FileName,
        };
        if (!string.IsNullOrWhiteSpace(extension))
        {
            picker.DefaultFileExtension = extension;
            picker.FileTypeChoices.Add(
                LocalizationService.Current.Get("ChatAttachmentFileType"),
                [extension]);
        }
        var destination = await picker.PickSaveFileAsync();
        if (destination is null || _disposed)
        {
            return;
        }

        using var cancellation = BeginAttachmentRead(item);
        try
        {
            await using var stream = new FileStream(
                destination.Path,
                FileMode.CreateNew,
                FileAccess.ReadWrite,
                FileShare.None,
                bufferSize: 64 * 1024,
                useAsync: true);
            var result = await _repository.SaveAttachmentAsync(
                item.MessageId,
                item.Attachment,
                stream,
                progress: null,
                cancellation.Token);
            if (!IsCurrentAttachmentRead(item, cancellation))
            {
                return;
            }

            ShowAttachmentStatus(
                result.Status == ChatAttachmentContentReadStatus.Completed
                    ? "ChatAttachmentSaveCompleted"
                    : "ChatAttachmentSaveFailed",
                result.Status == ChatAttachmentContentReadStatus.Completed
                    ? InfoBarSeverity.Success
                    : InfoBarSeverity.Warning);
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            ShowAttachmentStatus("ChatAttachmentSaveFailed", InfoBarSeverity.Warning);
        }
        finally
        {
            EndAttachmentRead(cancellation);
        }
    }

    private bool CanReadAttachmentThumbnail(ChatMessageAttachmentItem item) =>
        item.IsImage &&
        _repository.Availability.Status == ChatAvailabilityStatus.Available &&
        _repository.Availability.SupportedFeatures.Contains(ChatReadFeature.AttachmentThumbnail) &&
        IsCurrentAttachment(item);

    private bool IsCurrentAttachment(ChatMessageAttachmentItem item) =>
        !_disposed &&
        _viewModel.SelectedConversation is { IsEncrypted: false } conversation &&
        string.Equals(conversation.Id, item.ConversationId, StringComparison.Ordinal);

    private CancellationTokenSource BeginAttachmentRead(ChatMessageAttachmentItem item)
    {
        CancelAttachmentRead();
        _attachmentReadCancellation = new CancellationTokenSource();
        return _attachmentReadCancellation;
    }

    private bool IsCurrentAttachmentRead(
        ChatMessageAttachmentItem item,
        CancellationTokenSource cancellation) =>
        ReferenceEquals(_attachmentReadCancellation, cancellation) &&
        !cancellation.IsCancellationRequested &&
        IsCurrentAttachment(item);

    private void EndAttachmentRead(CancellationTokenSource cancellation)
    {
        if (ReferenceEquals(_attachmentReadCancellation, cancellation))
        {
            _attachmentReadCancellation = null;
        }
    }

    private void CancelAttachmentRead()
    {
        _attachmentReadCancellation?.Cancel();
        _attachmentReadCancellation?.Dispose();
        _attachmentReadCancellation = null;
    }

    private void ShowAttachmentStatus(string resourceKey, InfoBarSeverity severity)
    {
        if (_disposed)
        {
            return;
        }
        AttachmentFeedback.Title = LocalizationService.Current.Get(resourceKey);
        AttachmentFeedback.Severity = severity;
        AutomationProperties.SetName(AttachmentFeedback, AttachmentFeedback.Title);
        AttachmentFeedback.IsOpen = true;
    }

    private string AttachmentStatusText()
    {
        var localization = LocalizationService.Current;
        return _attachmentComposer.State switch
        {
            ChatAttachmentComposerState.Sending => localization.Get("ChatAttachmentSending"),
            ChatAttachmentComposerState.Sent => localization.Get("ChatAttachmentSent"),
            ChatAttachmentComposerState.NeedsReview => localization.Get("ChatAttachmentReview"),
            ChatAttachmentComposerState.CancelledBeforeSubmission => localization.Get("ChatAttachmentCancelled"),
            ChatAttachmentComposerState.PermissionDenied => localization.Get("ChatAttachmentPermission"),
            ChatAttachmentComposerState.Failure => localization.Get("ChatAttachmentFailed"),
            _ => string.Empty,
        };
    }

    private static Task<Stream> OpenAttachmentSourceAsync(
        string path,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Stream stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Task.FromResult(stream);
    }

    private static string? MediaTypeForPath(string path) =>
        Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".jpg" or ".jpeg" => "image/jpeg",
            ".png" => "image/png",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".heic" => "image/heic",
            ".mp4" => "video/mp4",
            ".mov" => "video/quicktime",
            _ => null,
        };

    private static string FormatByteCount(long value) =>
        value.ToString("N0", System.Globalization.CultureInfo.CurrentCulture);
}
