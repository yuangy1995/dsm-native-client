using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage;

namespace LanStash.App.Views;

internal sealed class ChatVoiceDialog : ContentDialog, IDisposable
{
    private readonly ChatVoiceRecordingModel _model;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly TextBlock _duration = new() { FontSize = 28, HorizontalAlignment = HorizontalAlignment.Center },
        _hint = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _status = new() { IsClosable = false };
    private readonly Button _start, _stop, _play, _discard, _send, _refresh, _save, _cancelSend;
    private readonly StackPanel _discardConfirmation = new() { Spacing = 8, Visibility = Visibility.Collapsed };
    private readonly MediaPlayerElement _element = new() { AreTransportControlsEnabled = true, Visibility = Visibility.Collapsed, Height = 84 };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _timer;
    private MediaPlayer? _player;
    private MediaSource? _source;
    private bool _disposed;
    public ChatVoiceDialog(ChatVoiceRecordingModel model, Func<Task> export)
    {
        _model = model; Title = _l.Get("ChatVoiceTitle"); CloseButtonText = _l.Get("ActionClose"); DefaultButton = ContentDialogButton.Close;
        AutomationProperties.SetAutomationId(this, "ChatVoiceDialog");
        AutomationProperties.SetName(_duration, _l.Get("ChatVoiceDuration")); AutomationProperties.SetAutomationId(_duration, "ChatVoiceDuration");
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        var body = new StackPanel { Spacing = 12, MinWidth = 420, MaxWidth = 650 };
        body.Children.Add(new TextBlock { Text = model.Conversation.Title, TextWrapping = TextWrapping.Wrap });
        body.Children.Add(_duration); body.Children.Add(_hint); body.Children.Add(_element);
        var recordButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _start = Add(recordButtons, "ChatVoiceStart", () => model.StartAsync());
        _stop = Add(recordButtons, "ChatVoiceStop", () => model.StopAsync()); body.Children.Add(recordButtons);
        var draftButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _play = Add(draftButtons, "ChatVoicePreview", PlayAsync);
        _save = Add(draftButtons, "ChatVoiceSaveCopy", export);
        _discard = Add(draftButtons, "ChatVoiceDiscard", () =>
        {
            StopPlayback();
            if (model.Composer.HasReview) _discardConfirmation.Visibility = Visibility.Visible;
            else model.Discard();
            return Task.CompletedTask;
        }); body.Children.Add(draftButtons);
        _discardConfirmation.Children.Add(new TextBlock { Text = _l.Get("ChatVoiceDiscardPending"), TextWrapping = TextWrapping.Wrap });
        Add(_discardConfirmation, "ChatVoiceDiscardConfirm", () => { model.Discard(); _discardConfirmation.Visibility = Visibility.Collapsed; return Task.CompletedTask; });
        Add(_discardConfirmation, "ActionCancel", () => { _discardConfirmation.Visibility = Visibility.Collapsed; return Task.CompletedTask; });
        body.Children.Add(_discardConfirmation);
        var sendButtons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        _send = Add(sendButtons, "ChatVoiceSend", async () => { StopPlayback(); await model.SendAsync(); });
        _refresh = Add(sendButtons, "ChatVoiceRefresh", async () => { StopPlayback(); await model.SendAsync(true); });
        _cancelSend = Add(sendButtons, "ChatVoiceCancelSend", () => { model.Composer.Cancel(); return Task.CompletedTask; });
        body.Children.Add(sendButtons); body.Children.Add(_status);
        Content = new ScrollViewer { Content = body, MaxHeight = 540, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        model.PropertyChanged += Changed;
        _timer = DispatcherQueue.CreateTimer(); _timer.Interval = TimeSpan.FromMilliseconds(250);
        _timer.Tick += Tick; _timer.Start();
        Closing += ClosingAsync; Closed += (_, _) => Dispose(); Update();
    }
    private Button Add(StackPanel panel, string key, Func<Task> action)
    {
        var button = new Button { Content = _l.Get(key), MinHeight = 44 }; AutomationProperties.SetAutomationId(button, key);
        button.Click += async (_, _) =>
        {
            try { await action(); }
            catch { if (!_disposed) { _status.Message = _l.Get("ChatVoiceFailed"); _status.IsOpen = true; _status.Severity = InfoBarSeverity.Warning; } }
        };
        panel.Children.Add(button); return button;
    }
    private async void Tick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args) => await _model.TickAsync();
    private async void ClosingAsync(ContentDialog sender, ContentDialogClosingEventArgs args)
    {
        if (_disposed) return;
        if (_model.Composer.IsSending) { args.Cancel = true; return; }
        var deferral = args.GetDeferral();
        try { StopPlayback(); await _model.SetVisibleAsync(false); }
        finally { deferral.Complete(); }
    }
    private async Task PlayAsync()
    {
        if (!_model.CanPreview || _model.Recording is not { } recording) return;
        StopPlayback();
        var file = await StorageFile.GetFileFromPathAsync(recording.Path);
        if (_disposed || _model.Recording != recording) return;
        _source = MediaSource.CreateFromStorageFile(file); _player = new() { Source = _source, AutoPlay = true };
        _player.MediaFailed += PlayerFailed; _element.SetMediaPlayer(_player); _element.Visibility = Visibility.Visible;
    }
    private void PlayerFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args) => DispatcherQueue.TryEnqueue(() =>
    { if (!_disposed) { _status.Message = _l.Get("ChatMediaUnsupported"); _status.IsOpen = true; } });
    private void StopPlayback()
    {
        if (_player is { } player) { _player = null; player.MediaFailed -= PlayerFailed; ChatPage.PauseChatPlayer(player); player.Source = null; _element.SetMediaPlayer(null); player.Dispose(); }
        _player = null; _source?.Dispose(); _source = null; _element.Visibility = Visibility.Collapsed;
    }
    private void Changed(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Update();
    private void Update()
    {
        if (_disposed) return;
        _duration.Text = _l.Format("ChatVoiceDurationValue", (int)_model.Duration.TotalMinutes, _model.Duration.Seconds);
        _start.IsEnabled = _model.CanStart; _start.Visibility = Visible(_model.Recording is null && !_model.IsCapturing);
        _stop.Visibility = Visible(_model.IsCapturing); _stop.IsEnabled = _model.State is ChatVoiceState.Starting or ChatVoiceState.Recording;
        _play.IsEnabled = _model.CanPreview; _save.IsEnabled = _model.CanPreview; _discard.IsEnabled = _model.CanDiscard;
        _play.Visibility = _save.Visibility = _discard.Visibility = Visible(_model.Recording is not null);
        _send.IsEnabled = _model.CanSend; _send.Visibility = Visible(_model.Recording is not null && !_model.Composer.HasReview);
        _refresh.Visibility = Visible(_model.Composer.CanRefreshSend); _refresh.IsEnabled = _model.Composer.CanRefreshSend;
        _cancelSend.Visibility = Visible(_model.Composer.IsSending);
        var hint = _model.State == ChatVoiceState.Starting ? "ChatVoiceStarting" : _model.IsCapturing ? "ChatVoiceLimit" :
            _model.Recording is { Duration.TotalMilliseconds: < 500 } ? "ChatVoiceTooShort" : null;
        _hint.Text = hint is null ? "" : _l.Get(hint); _hint.Visibility = Visible(hint is not null);
        var key = _model.State switch { ChatVoiceState.PermissionDenied => "ChatVoicePermission", ChatVoiceState.Failed => "ChatVoiceFailed", _ => null };
        key ??= _model.Composer.State switch
        {
            ChatAttachmentComposerState.NeedsReview => "ChatInteractionPending", ChatAttachmentComposerState.PermissionDenied => "ChatInteractionPermission",
            ChatAttachmentComposerState.Failure => "ChatVoiceFailed", ChatAttachmentComposerState.Sent => "ChatAttachmentSent", _ => null,
        };
        _status.IsOpen = key is not null; _status.Message = key is null ? "" : _l.Get(key);
        _status.Severity = key == "ChatAttachmentSent" ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
    }
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _timer.Stop(); _timer.Tick -= Tick; StopPlayback(); _model.PropertyChanged -= Changed;
    }
}
