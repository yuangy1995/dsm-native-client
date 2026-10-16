namespace LanStash.Domain;

/// <summary>已注册原单元的只读通知句柄；等待和重连不能发起转换。</summary>
public interface ISynologyPhotoPreviewCompletion : IAsyncDisposable
{
    Task<bool> CompletionAsync(CancellationToken cancellationToken = default);
}

public sealed record SynologyPhotoConvertedPreview(byte[] Large, byte[] Small, byte[] Medium);
public interface ISynologyPhotoPreviewConverter
{
    Task<SynologyPhotoConvertedPreview> ConvertAsync(string source, string mediaType, CancellationToken cancellationToken = default);
    Task<SynologyPhotoConversionSupport> SupportAsync(CancellationToken cancellationToken = default) => Task.FromResult(new SynologyPhotoConversionSupport(false, false, false));
    Task ConvertVideoAsync(string source, string destination, CancellationToken cancellationToken = default) =>
        Task.FromException(new SynologyPhotoConversionException(false));
    Task<SynologyPhotoVideoSignature> VideoSignatureAsync(string source, CancellationToken cancellationToken = default) =>
        Task.FromException<SynologyPhotoVideoSignature>(new SynologyPhotoConversionException(false));
}

public sealed record SynologyPhotoPreviewGenerationRequest(IReadOnlyList<SynologyPhoto> Photos, bool Resuming = false);
public sealed record SynologyPhotoPreviewGenerationItem(SynologyPhoto Original, SynologyPhotoChangeState State,
    SynologyPhoto? Updated = null, SynologyPhotoFailure? Failure = null);
public sealed record SynologyPhotoPreviewGeneration(Guid Id, bool Resuming, IReadOnlyList<SynologyPhotoPreviewGenerationItem> Items,
    bool Running, bool CanContinue)
{
    public bool Pending => Items.Any(item => item.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview);
    public bool Completed => Items.All(item => item.State == SynologyPhotoChangeState.Completed);
}
