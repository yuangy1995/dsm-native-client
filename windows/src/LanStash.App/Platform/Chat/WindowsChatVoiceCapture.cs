using System.Diagnostics;
using LanStash.App.Features.Chat;
using Microsoft.UI.Dispatching;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace LanStash.App.Platform.Chat;

internal sealed class WindowsChatVoiceCapture(DispatcherQueue dispatcher) : IChatVoiceCapture
{
    internal static string DraftDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "ChatVoice");
    private static readonly HashSet<string> ActivePaths = new(StringComparer.OrdinalIgnoreCase);
    internal static IReadOnlyList<string> CapturingPaths { get { lock (ActivePaths) return ActivePaths.ToArray(); } }
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Stopwatch _clock = new();
    private MediaCapture? _capture;
    private string? _path;
    private bool _recording, _disposed;
    public event EventHandler? Interrupted;
    public TimeSpan Duration => _clock.Elapsed;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_capture is not null) throw new InvalidOperationException("chat.voice.already-started");
            var capture = _capture = new MediaCapture();
            capture.Failed += Failed; capture.RecordLimitationExceeded += LimitationExceeded;
            // 仅从用户录音按钮的 UI/STA 线程调用；音频模式不初始化摄像头。
            await capture.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = StreamingCaptureMode.Audio }).AsTask(cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            Directory.CreateDirectory(DraftDirectory);
            var folder = await StorageFolder.GetFolderFromPathAsync(DraftDirectory);
            var file = await folder.CreateFileAsync(Guid.NewGuid().ToString("N") + ".m4a", CreationCollisionOption.FailIfExists);
            _path = file.Path;
            lock (ActivePaths) ActivePaths.Add(_path);
            var encoding = MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Medium);
            encoding.Audio.ChannelCount = 1; encoding.Audio.SampleRate = 44100; encoding.Audio.Bitrate = 64000;
            await capture.StartRecordToStorageFileAsync(encoding, file).AsTask(cancellationToken);
            _recording = true; _clock.Restart();
        }
        catch
        {
            ReleaseCapture();
            if (_path is { } failed) lock (ActivePaths) ActivePaths.Remove(failed);
            if (_path is { } path && File.Exists(path)) File.Delete(path);
            _path = null; throw;
        }
        finally { _gate.Release(); }
    }

    public async Task<ChatVoiceRecording?> StopAsync()
    {
        await _gate.WaitAsync();
        var stoppedPath = _path;
        try
        {
            if (_capture is null) return null;
            if (_recording) await _capture.StopRecordAsync();
            _clock.Stop();
            var result = _path is { } path ? new ChatVoiceRecording(path, _clock.Elapsed) : null;
            _path = null; return result;
        }
        finally
        {
            ReleaseCapture();
            lock (ActivePaths)
            {
                if (stoppedPath is not null) ActivePaths.Remove(stoppedPath);
            }
            _gate.Release();
        }
    }
    private void Failed(MediaCapture sender, MediaCaptureFailedEventArgs args) => NotifyInterrupted();
    private void LimitationExceeded(MediaCapture sender) => NotifyInterrupted();
    private void NotifyInterrupted() => dispatcher.TryEnqueue(() => Interrupted?.Invoke(this, EventArgs.Empty));
    private void ReleaseCapture()
    {
        _recording = false; _clock.Stop();
        if (_capture is not { } capture) return;
        capture.Failed -= Failed; capture.RecordLimitationExceeded -= LimitationExceeded; capture.Dispose(); _capture = null;
    }
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        var abandoned = await StopAsync();
        if (abandoned is not null && File.Exists(abandoned.Path)) File.Delete(abandoned.Path);
    }
}
