using System.IO;
using System.Runtime.InteropServices;
using LanStash.App.Features.Transfers;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Windows.Graphics.Imaging;

namespace LanStash.App.Features.Files.Preview;

public sealed class FilePreviewViewModel : ObservableObject, IDisposable
{
    private readonly IFilePreviewArtifactStore _artifacts;
    private readonly IFilePreviewMetadataReader _metadataReader;
    private CancellationTokenSource? _operationCancellation;
    private IFilePreviewRepository? _activeRepository;
    private long _generation;
    private FilePreviewSnapshot _snapshot = new();
    private bool _disposed;

    public FilePreviewViewModel()
        : this(new FilePreviewArtifactStore())
    {
    }

    internal FilePreviewViewModel(IFilePreviewArtifactStore artifacts)
        : this(artifacts, new FilePreviewMetadataReader())
    {
    }

    internal FilePreviewViewModel(
        IFilePreviewArtifactStore artifacts,
        IFilePreviewMetadataReader metadataReader)
    {
        _artifacts = artifacts;
        _metadataReader = metadataReader;
    }

    public FilePreviewSnapshot Snapshot
    {
        get => _snapshot;
        private set
        {
            if (SetProperty(ref _snapshot, value))
            {
                RaisePropertyChanged(nameof(IsOpen));
                RaisePropertyChanged(nameof(IsPreparing));
                RaisePropertyChanged(nameof(IsReady));
                RaisePropertyChanged(nameof(HasFailed));
            }
        }
    }

    public bool IsOpen => Snapshot.Phase != FilePreviewPhase.Inactive;
    public bool IsPreparing => Snapshot.Phase == FilePreviewPhase.Preparing;
    public bool IsReady => Snapshot.Phase == FilePreviewPhase.Ready;
    public bool HasFailed => Snapshot.Phase == FilePreviewPhase.Failed;

    public bool TryGetSaveCopyTarget(
        FileItem? currentSelection,
        out FilePreviewSaveCopyTarget? target)
    {
        var snapshot = Snapshot;
        if (!_disposed &&
            snapshot.IsSaveCopyAvailable() &&
            snapshot.ProfileId is { } profileId &&
            snapshot.Item is { IsDirectory: false } item &&
            currentSelection is { IsDirectory: false } selected &&
            string.Equals(selected.Path, item.Path, StringComparison.Ordinal))
        {
            target = new FilePreviewSaveCopyTarget(profileId, item);
            return true;
        }
        target = null;
        return false;
    }

    public async Task OpenAsync(
        IFilePreviewRepository repository,
        Guid profileId,
        FileItem item)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(item);
        await StopCurrentAsync().ConfigureAwait(true);

        var kind = FilePreviewClassifier.Classify(item);
        if (repository.ProfileId != profileId)
        {
            Snapshot = Details(profileId, item, kind, FilePreviewUnavailableReason.Unsupported);
            return;
        }
        if (kind == FilePreviewKind.Unsupported)
        {
            Snapshot = Details(profileId, item, kind, FilePreviewUnavailableReason.Unsupported);
            return;
        }
        if (item.Size < 0)
        {
            Snapshot = Details(profileId, item, kind, FilePreviewUnavailableReason.UnknownSize);
            return;
        }
        if (item.Size == 0)
        {
            Snapshot = kind == FilePreviewKind.Text
                ? new FilePreviewSnapshot(
                    profileId,
                    item,
                    kind,
                    FilePreviewPhase.Ready,
                    Text: string.Empty,
                    TotalBytes: 0)
                : Details(profileId, item, kind, FilePreviewUnavailableReason.Empty);
            return;
        }
        if (kind is FilePreviewKind.Image or FilePreviewKind.Pdf &&
            item.Size > FilePreviewClassifier.DocumentPreviewByteLimit)
        {
            Snapshot = Details(profileId, item, kind, FilePreviewUnavailableReason.TooLarge);
            return;
        }

        var request = BeginOperation(repository);
        Snapshot = new FilePreviewSnapshot(
            profileId,
            item,
            kind,
            FilePreviewPhase.Preparing,
            TotalBytes: item.Size);
        try
        {
            switch (kind)
            {
                case FilePreviewKind.Text:
                    await LoadTextAsync(repository, item, profileId, request).ConfigureAwait(true);
                    break;
                case FilePreviewKind.Image:
                case FilePreviewKind.Pdf:
                    await LoadArtifactAsync(repository, item, kind, profileId, request)
                        .ConfigureAwait(true);
                    break;
                case FilePreviewKind.Audio:
                case FilePreviewKind.Video:
                    await LoadMediaAsync(repository, item, kind, profileId, request)
                        .ConfigureAwait(true);
                    break;
            }
        }
        catch (OperationCanceledException) when (!IsCurrent(request.Generation, request.Token, request.Repository))
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, request.Token, request.Repository))
            {
                Snapshot = Snapshot with
                {
                    Phase = FilePreviewPhase.Failed,
                    CompletedBytes = 0,
                    Artifact = null,
                    Media = null,
                    MediaMetadata = null,
                };
            }
        }
    }

    public async Task CancelAsync()
    {
        ThrowIfDisposed();
        if (!IsPreparing)
        {
            return;
        }
        var previous = Snapshot;
        await StopCurrentAsync().ConfigureAwait(true);
        Snapshot = previous with
        {
            Phase = FilePreviewPhase.Cancelled,
            Artifact = null,
            Media = null,
            MediaMetadata = null,
            CompletedBytes = 0,
        };
    }

    public async Task CloseAsync()
    {
        ThrowIfDisposed();
        var profile = Snapshot.ProfileId;
        await StopCurrentAsync().ConfigureAwait(true);
        Snapshot = new FilePreviewSnapshot(ProfileId: profile);
    }

    public async Task ReportPresentationFailureAsync()
    {
        ThrowIfDisposed();
        if (Snapshot.Phase != FilePreviewPhase.Ready)
        {
            return;
        }
        var previous = Snapshot;
        await StopCurrentAsync().ConfigureAwait(true);
        Snapshot = previous with
        {
            Phase = FilePreviewPhase.Failed,
            Artifact = null,
            Media = null,
            MediaMetadata = null,
            CompletedBytes = 0,
        };
    }

    private async Task LoadTextAsync(
        IFilePreviewRepository repository,
        FileItem item,
        Guid profileId,
        (long Generation, CancellationToken Token, IFilePreviewRepository Repository) request)
    {
        var requestedLength = Math.Min(
            item.Size,
            (long)FilePreviewClassifier.TextPreviewByteLimit + 1);
        var result = await repository.ReadFileRangeResultAsync(
            item.Path,
            0,
            requestedLength,
            expectedTotalLength: item.Size,
            cancellationToken: request.Token).ConfigureAwait(true);
        ValidateRange(result, 0, requestedLength, item.Size);
        if (!IsCurrent(request.Generation, request.Token, request.Repository))
        {
            return;
        }

        var truncated = result.Bytes.Length > FilePreviewClassifier.TextPreviewByteLimit ||
            result.TotalLength > FilePreviewClassifier.TextPreviewByteLimit;
        var bytes = result.Bytes.AsSpan(
            0,
            Math.Min(result.Bytes.Length, FilePreviewClassifier.TextPreviewByteLimit));
        var text = FilePreviewTextDecoder.Decode(bytes, truncated);
        Snapshot = new FilePreviewSnapshot(
            profileId,
            item,
            FilePreviewKind.Text,
            FilePreviewPhase.Ready,
            Text: text,
            IsTextTruncated: truncated,
            CompletedBytes: result.Bytes.Length,
            TotalBytes: item.Size);
    }

    private async Task LoadArtifactAsync(
        IFilePreviewRepository repository,
        FileItem item,
        FilePreviewKind kind,
        Guid profileId,
        (long Generation, CancellationToken Token, IFilePreviewRepository Repository) request)
    {
        var progress = new Progress<ForegroundTransferProgress>(value =>
        {
            if (IsCurrent(request.Generation, request.Token, request.Repository))
            {
                Snapshot = Snapshot with
                {
                    CompletedBytes = value.BytesTransferred,
                    TotalBytes = value.TotalBytes,
                };
            }
        });
        IFilePreviewArtifact? artifact = null;
        try
        {
            artifact = await _artifacts.PrepareAsync(
                repository,
                item,
                progress,
                request.Token).ConfigureAwait(true);
            var metadata = await TryReadMetadataAsync(artifact, kind, request.Token)
                .ConfigureAwait(true);
            if (!IsCurrent(request.Generation, request.Token, request.Repository))
            {
                return;
            }
            Snapshot = new FilePreviewSnapshot(
                profileId,
                item,
                kind,
                FilePreviewPhase.Ready,
                Artifact: artifact,
                MediaMetadata: metadata,
                CompletedBytes: item.Size,
                TotalBytes: item.Size);
            artifact = null;
        }
        finally
        {
            if (artifact is not null)
            {
                await artifact.DisposeAsync().ConfigureAwait(true);
            }
        }
    }

    private async Task LoadMediaAsync(
        IFilePreviewRepository repository,
        FileItem item,
        FilePreviewKind kind,
        Guid profileId,
        (long Generation, CancellationToken Token, IFilePreviewRepository Repository) request)
    {
        var media = await StrictRangeMediaSource.CreateAsync(
            repository,
            item,
            kind,
            request.Token).ConfigureAwait(true);
        if (!IsCurrent(request.Generation, request.Token, request.Repository))
        {
            media.Dispose();
            return;
        }
        Snapshot = new FilePreviewSnapshot(
            profileId,
            item,
            kind,
            FilePreviewPhase.Ready,
            Media: media,
            TotalBytes: item.Size);
    }

    private async Task<FilePreviewMediaMetadata?> TryReadMetadataAsync(
        IFilePreviewArtifact artifact,
        FilePreviewKind kind,
        CancellationToken cancellationToken)
    {
        try
        {
            return await _metadataReader.ReadAsync(artifact, kind, cancellationToken)
                .ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (
            error is IOException or
                UnauthorizedAccessException or
                ArgumentException or
                COMException)
        {
            return null;
        }
    }

    private static void ValidateRange(
        FileRangeReadResult result,
        long offset,
        long length,
        long totalLength)
    {
        if (result.RequestedStart != offset ||
            result.RequestedLength != length ||
            result.ResponseStart != offset ||
            result.ResponseLength != length ||
            result.TotalLength != totalLength ||
            result.ActualByteCount != length ||
            result.Bytes.LongLength != length)
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnsafeSegmentedRead,
                "The text preview range did not match the requested bytes.",
                result.StatusCode);
        }
    }

    private (long Generation, CancellationToken Token, IFilePreviewRepository Repository) BeginOperation(
        IFilePreviewRepository repository)
    {
        _operationCancellation?.Dispose();
        _operationCancellation = new CancellationTokenSource();
        _activeRepository = repository;
        return (
            Interlocked.Increment(ref _generation),
            _operationCancellation.Token,
            repository);
    }

    private bool IsCurrent(
        long generation,
        CancellationToken token,
        IFilePreviewRepository? repository = null) =>
        !_disposed &&
        !token.IsCancellationRequested &&
        generation == Volatile.Read(ref _generation) &&
        (repository is null || ReferenceEquals(repository, _activeRepository));

    private async Task StopCurrentAsync()
    {
        Interlocked.Increment(ref _generation);
        _operationCancellation?.Cancel();
        _operationCancellation?.Dispose();
        _operationCancellation = null;
        _activeRepository = null;

        var artifact = Snapshot.Artifact;
        var media = Snapshot.Media;
        Snapshot = Snapshot with { Artifact = null, Media = null, MediaMetadata = null };
        media?.Dispose();
        if (artifact is not null)
        {
            await artifact.DisposeAsync().ConfigureAwait(true);
        }
    }

    private static FilePreviewSnapshot Details(
        Guid profileId,
        FileItem item,
        FilePreviewKind kind,
        FilePreviewUnavailableReason reason) => new(
            profileId,
            item,
            kind,
            FilePreviewPhase.DetailsOnly,
            reason,
            TotalBytes: item.Size >= 0 ? item.Size : null);

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Interlocked.Increment(ref _generation);
        _operationCancellation?.Cancel();
        _operationCancellation?.Dispose();
        _operationCancellation = null;
        _activeRepository = null;
        Snapshot.Media?.Dispose();
        if (Snapshot.Artifact is { } artifact)
        {
            _ = artifact.DisposeAsync();
        }
        Snapshot = new FilePreviewSnapshot(ProfileId: Snapshot.ProfileId);
    }
}

internal static class FilePreviewSnapshotExtensions
{
    public static bool IsSaveCopyAvailable(this FilePreviewSnapshot snapshot) =>
        snapshot.Phase is FilePreviewPhase.Ready or
            FilePreviewPhase.DetailsOnly or
            FilePreviewPhase.Failed or
            FilePreviewPhase.Cancelled;
}

internal interface IFilePreviewMetadataReader
{
    Task<FilePreviewMediaMetadata?> ReadAsync(
        IFilePreviewArtifact artifact,
        FilePreviewKind kind,
        CancellationToken cancellationToken);
}

internal sealed class FilePreviewMetadataReader : IFilePreviewMetadataReader
{
    public async Task<FilePreviewMediaMetadata?> ReadAsync(
        IFilePreviewArtifact artifact,
        FilePreviewKind kind,
        CancellationToken cancellationToken)
    {
        if (kind != FilePreviewKind.Image || artifact.File is not { } file)
        {
            return null;
        }

        using var stream = await file.OpenReadAsync().AsTask(cancellationToken)
            .ConfigureAwait(true);
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(cancellationToken)
            .ConfigureAwait(true);
        if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0)
        {
            return null;
        }

        return new FilePreviewMediaMetadata(decoder.PixelWidth, decoder.PixelHeight);
    }
}
