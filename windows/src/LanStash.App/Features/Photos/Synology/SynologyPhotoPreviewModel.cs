using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

/// <summary>详情与媒体分别绑定当前预览代际；关闭时回收 Range 会话，迟到媒体不能泄漏。</summary>
public sealed class SynologyPhotoPreviewModel(ISynologyPhotosRepository repository) : ObservableObject, IDisposable
{
    private CancellationTokenSource? _request;
    private long _generation;
    private bool _disposed;
    public SynologyPhoto? Photo { get; private set; }
    public byte[]? ImageBytes { get; private set; }
    public IReadOnlyMediaSource? MediaSource { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsPlayingMotion { get; private set; }
    public string? ErrorKey { get; private set; }

    public async Task OpenAsync(SynologyPhoto photo, bool motion = false)
    {
        if (_disposed || photo.Id.ProfileId != repository.ProfileId || photo.Id.Space != SynologyPhotoSpace.Personal) return;
        Close(); var generation = ++_generation; _request = new(); var token = _request.Token;
        Photo = photo; IsLoading = true; ErrorKey = null; Changed();
        try
        {
            var detail = await repository.DetailsAsync(photo, token);
            if (!Current(generation, token)) return;
            Photo = detail; Changed();
            if (detail.MediaType == "video" || (detail.MediaType == "live" && motion))
            {
                var source = await repository.VideoSourceAsync(detail, token);
                if (!Current(generation, token)) { source.Dispose(); return; }
                MediaSource = source; IsPlayingMotion = detail.MediaType == "live";
            }
            else
            {
                var bytes = await repository.ThumbnailAsync(detail, large: true, cancellationToken: token);
                if (!Current(generation, token)) return;
                ImageBytes = bytes;
            }
        }
        catch (OperationCanceledException) when (!Current(generation, token)) { }
        catch (Exception) { if (Current(generation, token)) ErrorKey = "PhotosMediaFailed"; }
        finally { if (Current(generation, token)) { IsLoading = false; Changed(); } }
    }

    public async Task PlayMotionAsync()
    {
        if (Photo is not { MediaType: "live" } photo || IsPlayingMotion || IsLoading || _request is null) return;
        var generation = _generation; var token = _request.Token;
        IsLoading = true; ErrorKey = null; Changed();
        try
        {
            var source = await repository.VideoSourceAsync(photo, token);
            if (!Current(generation, token)) { source.Dispose(); return; }
            MediaSource = source; IsPlayingMotion = true;
        }
        catch (OperationCanceledException) when (!Current(generation, token)) { }
        catch (Exception) { if (Current(generation, token)) ErrorKey = "PhotosMediaFailed"; }
        finally { if (Current(generation, token)) { IsLoading = false; Changed(); } }
    }

    public void FinishMotion()
    {
        if (!IsPlayingMotion) return;
        MediaSource?.Dispose(); MediaSource = null; IsPlayingMotion = false; Changed();
    }
    private bool Current(long generation, CancellationToken token) => !_disposed && generation == _generation && !token.IsCancellationRequested;
    private void Changed() => RaisePropertyChanged(string.Empty);
    public void Close()
    {
        _generation++; _request?.Cancel(); _request?.Dispose(); _request = null;
        MediaSource?.Dispose(); MediaSource = null; ImageBytes = null; Photo = null;
        IsLoading = false; IsPlayingMotion = false; ErrorKey = null; Changed();
    }
    public void Dispose() { if (_disposed) return; Close(); _disposed = true; }
}
