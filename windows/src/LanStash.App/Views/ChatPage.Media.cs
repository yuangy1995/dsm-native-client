using System.Runtime.InteropServices.WindowsRuntime;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ContentDialog? _mediaDialog;
    private MediaPlayer? _chatMediaPlayer;
    private Task _chatMediaTask = Task.CompletedTask;

    private Task ShowChatMediaAsync(ChatMessageAttachmentItem item) => _disposed || _mediaDialog is not null
        ? Task.CompletedTask : _chatMediaTask = ShowChatMediaCoreAsync(item);

    private async Task ShowChatMediaCoreAsync(ChatMessageAttachmentItem item)
    {
        if (_disposed || !IsCurrentAttachment(item) || _mediaDialog is not null || XamlRoot is null) return;
        using var cancellation = BeginAttachmentRead(item);
        var l = LocalizationService.Current;
        var loading = new ProgressRing { IsActive = true, Width = 36, Height = 36 };
        var status = new TextBlock { Text = l.Get("ChatMediaLoading"), TextWrapping = TextWrapping.Wrap };
        var element = new MediaPlayerElement { AreTransportControlsEnabled = true, MinWidth = 420, MaxWidth = 720, MaxHeight = 380, Visibility = Visibility.Collapsed };
        if (item.Attachment.Kind == LanStash.Domain.ChatAttachmentKind.Voice) element.Height = 100;
        var content = new StackPanel { Spacing = 12 }; content.Children.Add(loading); content.Children.Add(status); content.Children.Add(element);
        var player = _chatMediaPlayer = new MediaPlayer { AutoPlay = true };
        element.SetMediaPlayer(player);
        var save = false; var closed = false; ChatMediaArtifact? artifact = null; MediaSource? source = null;
        Windows.Storage.Streams.IRandomAccessStream? nativeStream = null;
        var dialog = _mediaDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = item.FileName, Content = content,
            CloseButtonText = l.Get("ActionClose"), PrimaryButtonText = l.Get("ChatMediaSaveCopy"), DefaultButton = ContentDialogButton.Close,
        };
        AutomationProperties.SetAutomationId(dialog, "ChatMediaDialog");
        AutomationProperties.SetName(element, l.Get("ChatMediaPlayer"));
        dialog.PrimaryButtonClick += (_, _) => save = true;
        void Failed(MediaPlayer sender, MediaPlayerFailedEventArgs args) => DispatcherQueue.TryEnqueue(() =>
        {
            if (!closed) { status.Text = l.Get("ChatMediaUnsupported"); status.Visibility = Visibility.Visible; }
        });
        player.MediaFailed += Failed;
        async Task LoadAsync()
        {
            try
            {
                artifact = await new ChatMediaService().ReadAsync(_repository, item, cancellation.Token);
                if (closed || !IsCurrentAttachmentRead(item, cancellation)) return;
                nativeStream = artifact.Stream.AsRandomAccessStream();
                source = MediaSource.CreateFromStream(nativeStream, artifact.MediaType);
                player.Source = source; element.Visibility = Visibility.Visible; status.Visibility = Visibility.Collapsed;
            }
            catch (OperationCanceledException) { }
            catch { if (!closed) status.Text = l.Get(item.Attachment.SizeBytes > ChatMediaService.MaximumBytes ? "ChatMediaTooLarge" : "ChatMediaFailed"); }
            finally { if (!closed) { loading.IsActive = false; loading.Visibility = Visibility.Collapsed; } }
        }
        var load = LoadAsync();
        try { await dialog.ShowAsync(); }
        finally
        {
            closed = true; cancellation.Cancel(); await load; player.MediaFailed -= Failed;
            _mediaDialog = null; _chatMediaPlayer = null;
            PauseChatPlayer(player); player.Source = null; element.SetMediaPlayer(null);
            player.Dispose(); source?.Dispose(); nativeStream?.Dispose(); artifact?.Dispose(); EndAttachmentRead(cancellation);
        }
        if (save && !_disposed) await SaveAttachmentAsync(item);
    }

    private void StopChatMedia()
    {
        if (_chatMediaPlayer is { } player) PauseChatPlayer(player);
        _mediaDialog?.Hide();
    }

    internal static void PauseChatPlayer(MediaPlayer player)
    {
        try { player.Pause(); }
        catch (System.Runtime.InteropServices.COMException error) when (error.HResult is unchecked((int)0x80004004) or unchecked((int)0x80000013))
        { /* 媒体管线已经中止或关闭时，继续释放源和临时流。 */ }
    }
}
