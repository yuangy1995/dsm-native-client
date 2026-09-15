using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

/// <summary>只接受个人空间单项原件；未知结果保留身份并只读核对，不生成第二次删除。</summary>
public sealed class SynologyPhotoDeletionModel(ISynologyPhotosRepository repository, Action<SynologyPhoto> onConfirmed)
    : ObservableObject, IDisposable
{
    private CancellationTokenSource? _preparation;
    private readonly CancellationTokenSource _lifetime = new();
    private long _generation;
    private bool _disposed;
    public SynologyPhoto? Candidate { get; private set; }
    public SynologyPhoto? Pending { get; private set; }
    public bool IsChecking { get; private set; }
    public bool IsWriting { get; private set; }
    public bool IsBusy => IsChecking || IsWriting;
    public bool Enabled => repository.CanDeleteOriginals;
    public string? ErrorKey { get; private set; }

    public async Task PrepareAsync(SynologyPhoto photo)
    {
        if (_disposed || IsBusy || Pending is not null) return;
        if (!Enabled) { ErrorKey = "PhotosDeleteUnverified"; Changed(); return; }
        CancelCandidate(); _preparation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var token = _preparation.Token; var generation = ++_generation;
        IsChecking = true; ErrorKey = null; Changed();
        try
        {
            await repository.PrepareDeletionAsync(photo, token);
            if (!_disposed && generation == _generation && !token.IsCancellationRequested) Candidate = photo;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception error) { if (!_disposed && generation == _generation) ErrorKey = FailureKey(error); }
        finally { if (!_disposed && generation == _generation) { IsChecking = false; Changed(); } }
    }

    public void CancelCandidate()
    {
        _generation++; _preparation?.Cancel(); _preparation?.Dispose(); _preparation = null;
        Candidate = null; IsChecking = false; Changed();
    }

    public async Task ConfirmAsync()
    {
        if (_disposed || !Enabled || IsBusy || Pending is not null || Candidate is not { } photo) return;
        Candidate = null; Pending = photo; IsWriting = true; ErrorKey = null; Changed();
        try { Apply(await repository.DeleteAsync(photo, Guid.NewGuid(), _lifetime.Token), photo); }
        catch (OperationCanceledException) { /* 发送是否完成未知，保留待核对身份。 */ }
        catch (Exception error)
        {
            // 仓储只会在写前检查抛出异常；写后错误必须转换为 PendingReview。
            if (!_disposed) { Pending = null; ErrorKey = FailureKey(error); }
        }
        finally { if (!_disposed) { IsWriting = false; Changed(); } }
    }

    public async Task ReviewAsync()
    {
        if (_disposed || IsBusy || Pending is not { } photo) return;
        IsWriting = true; ErrorKey = null; Changed();
        try { Apply(await repository.ReviewDeletionAsync(photo, _lifetime.Token), photo); }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!_disposed) ErrorKey = FailureKey(error); }
        finally { if (!_disposed) { IsWriting = false; Changed(); } }
    }
    private void Apply(SynologyPhotoDeletionResult result, SynologyPhoto photo)
    {
        if (_disposed) return;
        if (result == SynologyPhotoDeletionResult.Confirmed) { Pending = null; onConfirmed(photo); }
        else Pending = photo;
    }
    private static string FailureKey(Exception error) => error switch
    {
        SynologyPhotoException { Failure: SynologyPhotoFailure.TargetChanged } => "PhotosDeleteChanged",
        SynologyPhotoException { Failure: SynologyPhotoFailure.DeleteDenied or SynologyPhotoFailure.Permission } => "PhotosDeleteDenied",
        SynologyPhotoException { Failure: SynologyPhotoFailure.DeletionUnverified } => "PhotosDeleteUnverified",
        _ => "PhotosDeleteFailed",
    };
    private void Changed() => RaisePropertyChanged(string.Empty);
    public void Dispose()
    {
        if (_disposed) return;
        CancelCandidate(); _disposed = true; _lifetime.Cancel();
        // 已提交仓储仍可能完成 finally；不提前释放其取消资源。
    }
}
