using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public sealed record ChatVoiceRecording(string Path, TimeSpan Duration)
{
    public ChatAttachmentDraft Draft => new("recording.m4a", "audio/mp4", new FileInfo(Path).Length,
        token =>
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult<Stream>(new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read,
                64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan));
        });
}

public interface IChatVoiceCapture : IAsyncDisposable
{
    event EventHandler? Interrupted;
    TimeSpan Duration { get; }
    Task StartAsync(CancellationToken cancellationToken);
    Task<ChatVoiceRecording?> StopAsync();
}

public enum ChatVoiceState { Ready, Starting, Recording, Stopping, Recorded, Failed, PermissionDenied }

/// <summary>采集与发送分别由显式用户动作启动；关闭录音页只停止采集，草稿继续归属原会话。</summary>
public sealed class ChatVoiceRecordingModel : ObservableObject, IAsyncDisposable
{
    public static readonly TimeSpan MaximumDuration = TimeSpan.FromMinutes(5);
    private readonly IChatVoiceCapture _capture;
    private CancellationTokenSource? _start;
    private bool _disposed, _visible = true;
    private long _generation;
    private ChatVoiceState _state = ChatVoiceState.Ready;
    private ChatVoiceRecording? _recording;
    private TimeSpan _duration;
    public ChatVoiceRecordingModel(IChatRepository repository, ChatConversation conversation, IChatVoiceCapture capture)
    {
        _capture = capture; Conversation = conversation;
        Composer = new(ChatAttachmentSendReviewBlocker.Current); Composer.Configure(repository, new(conversation));
        Composer.PropertyChanged += ComposerChanged; capture.Interrupted += CaptureInterrupted;
    }
    public ChatConversation Conversation { get; }
    public ChatAttachmentComposerViewModel Composer { get; }
    public ChatVoiceState State => _state;
    public ChatVoiceRecording? Recording => _recording;
    public TimeSpan Duration => _duration;
    public bool IsCapturing => _start is not null || _state is ChatVoiceState.Starting or ChatVoiceState.Recording or ChatVoiceState.Stopping;
    public bool IsBusy => IsCapturing || Composer.IsSending;
    public bool CanStart => !_disposed && _visible && _recording is null && !IsBusy && Composer.IsAvailable;
    public bool CanSend => !IsCapturing && _recording?.Duration >= TimeSpan.FromMilliseconds(500) && Composer.CanSend;
    public bool CanDiscard => _recording is not null && !IsBusy;
    public bool CanPreview => _recording is not null && !IsBusy;

    public async Task StartAsync()
    {
        if (!CanStart) return;
        var generation = ++_generation;
        using var cancellation = _start = new();
        _state = ChatVoiceState.Starting; Changed();
        try
        {
            await _capture.StartAsync(cancellation.Token);
            if (_disposed || generation != _generation || !_visible)
            {
                var abandoned = await _capture.StopAsync();
                if (abandoned is not null && File.Exists(abandoned.Path)) File.Delete(abandoned.Path);
                return;
            }
            _state = ChatVoiceState.Recording; _duration = TimeSpan.Zero;
        }
        catch (UnauthorizedAccessException) { if (!_disposed && generation == _generation) _state = ChatVoiceState.PermissionDenied; }
        catch (OperationCanceledException) { if (!_disposed && generation == _generation) _state = ChatVoiceState.Ready; }
        catch { if (!_disposed && generation == _generation) _state = ChatVoiceState.Failed; }
        finally { if (ReferenceEquals(_start, cancellation)) _start = null; Changed(); }
    }

    public async Task StopAsync()
    {
        if (_state == ChatVoiceState.Starting) { _generation++; _start?.Cancel(); _state = ChatVoiceState.Ready; Changed(); return; }
        if (_state != ChatVoiceState.Recording) return;
        _state = ChatVoiceState.Stopping; Changed();
        try
        {
            var recording = await _capture.StopAsync();
            if (recording is null || !File.Exists(recording.Path) || new FileInfo(recording.Path).Length == 0) throw new IOException("chat.voice.empty");
            _recording = recording; _duration = recording.Duration;
            if (!Composer.Select(recording.Draft)) throw new IOException("chat.voice.draft-unavailable");
            _state = ChatVoiceState.Recorded;
        }
        catch { _state = ChatVoiceState.Failed; }
        Changed();
    }

    public async Task TickAsync()
    {
        if (_state != ChatVoiceState.Recording) return;
        _duration = _capture.Duration; Changed();
        if (_duration >= MaximumDuration) await StopAsync();
    }

    public async Task SetVisibleAsync(bool visible)
    {
        _visible = visible;
        if (!visible) await StopAsync();
        Changed();
    }

    public async Task<bool> SendAsync(bool refresh = false)
    {
        if (refresh ? !Composer.CanRefreshSend : !CanSend) return false;
        var sent = refresh ? await Composer.RefreshSendAsync() : await Composer.SendAsync(null);
        if (sent)
        {
            DeleteRecording(); _state = ChatVoiceState.Ready; _duration = TimeSpan.Zero;
        }
        Changed(); return sent;
    }

    public void Discard()
    {
        if (!CanDiscard) return;
        DeleteRecording(); Composer.Remove(); _state = ChatVoiceState.Ready; _duration = TimeSpan.Zero; Changed();
    }
    public async Task ExportAsync(Stream destination, CancellationToken cancellationToken = default)
    {
        if (_recording is not { } recording || IsBusy) throw new InvalidOperationException("chat.voice.unavailable");
        await using var source = await recording.Draft.OpenReadAsync(cancellationToken);
        await source.CopyToAsync(destination, cancellationToken); await destination.FlushAsync(cancellationToken);
    }
    private void DeleteRecording()
    {
        if (_recording is not { } recording) return;
        if (File.Exists(recording.Path)) File.Delete(recording.Path);
        _recording = null;
    }
    private async void CaptureInterrupted(object? sender, EventArgs args) => await StopAsync();
    private void ComposerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args) => Changed();
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        await SetVisibleAsync(false); _disposed = true; _generation++; _start?.Cancel();
        _capture.Interrupted -= CaptureInterrupted; Composer.PropertyChanged -= ComposerChanged;
        await _capture.DisposeAsync(); Composer.Dispose();
        // 未发送或未知的唯一副本留给工作区退出保护和本机副本导出，不能按临时预览清理。
    }
}
