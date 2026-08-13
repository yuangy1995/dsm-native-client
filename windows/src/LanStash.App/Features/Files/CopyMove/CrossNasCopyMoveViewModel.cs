using LanStash.App.Features.Files.Mutations;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.CopyMove;

public enum CrossNasCopyMoveState
{
    ChoosingTarget,
    ChoosingDestination,
    LoadingFolders,
    Transferring,
    Completed,
    Unsupported,
    TargetUnavailable,
    Failure,
}

public sealed class CrossNasCopyMoveViewModel : ObservableObject, IDisposable
{
    private readonly IFileCopyMoveRepository _sourceRepository;
    private readonly Guid _sourceProfileId;
    private readonly IReadOnlyList<NasProfile> _targetProfiles;
    private readonly Func<Guid, CancellationToken, Task<IFileCopyMoveFolderSource?>> _targetFolderSourceFactory;
    private CancellationTokenSource? _request;
    private CrossNasCopyMoveState _state;
    private NasProfile? _selectedTarget;
    private IFileCopyMoveFolderSource? _targetFolderSource;
    private IDisposable? _targetFolderLease;
    private IReadOnlyList<FileCopyMoveFolder> _folderItems = [];
    private string _destinationPath = string.Empty;
    private bool _destinationCanWrite;
    private long _transferredBytes;
    private long _totalBytes;
    private string? _resultMessage;
    private long _generation;
    private bool _disposed;

    public CrossNasCopyMoveViewModel(
        IFileCopyMoveRepository sourceRepository,
        Guid sourceProfileId,
        FileItem source,
        FileCopyMoveOperation operation,
        IReadOnlyList<NasProfile> targetProfiles,
        Func<Guid, CancellationToken, Task<IFileCopyMoveFolderSource?>> targetFolderSourceFactory)
    {
        ArgumentNullException.ThrowIfNull(sourceRepository);
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(targetProfiles);
        ArgumentNullException.ThrowIfNull(targetFolderSourceFactory);
        if (operation is not FileCopyMoveOperation.Copy and not FileCopyMoveOperation.Move)
            throw new ArgumentException("file.cross-nas.invalid-operation", nameof(operation));
        if (!IsOrdinaryItem(source))
            throw new ArgumentException("file.cross-nas.invalid-source", nameof(source));

        _sourceRepository = sourceRepository;
        _sourceProfileId = sourceProfileId;
        _targetProfiles = targetProfiles;
        _targetFolderSourceFactory = targetFolderSourceFactory;
        Source = source;
        Operation = operation;

        var available = sourceRepository.CrossNasAvailability;
        var capable = operation == FileCopyMoveOperation.Copy
            ? available.CanCrossCopy
            : available.CanCrossMove;
        _state = capable && targetProfiles.Count > 0
            ? CrossNasCopyMoveState.ChoosingTarget
            : CrossNasCopyMoveState.Unsupported;
    }

    public FileItem Source { get; }
    public FileCopyMoveOperation Operation { get; }

    public IReadOnlyList<NasProfile> TargetProfiles => _targetProfiles;

    public NasProfile? SelectedTarget
    {
        get => _selectedTarget;
        set
        {
            if (SetProperty(ref _selectedTarget, value))
            {
                RaisePropertyChanged(nameof(CanBrowseFolders));
            }
        }
    }

    public IReadOnlyList<FileCopyMoveFolder> Folders
    {
        get => _folderItems;
        private set => SetProperty(ref _folderItems, value);
    }

    public string DestinationPath
    {
        get => _destinationPath;
        private set
        {
            if (SetProperty(ref _destinationPath, value))
            {
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }

    public bool DestinationCanWrite
    {
        get => _destinationCanWrite;
        private set
        {
            if (SetProperty(ref _destinationCanWrite, value))
            {
                RaisePropertyChanged(nameof(CanSubmit));
            }
        }
    }

    public CrossNasCopyMoveState State
    {
        get => _state;
        private set
        {
            if (SetProperty(ref _state, value))
            {
                RaisePropertyChanged(nameof(CanBrowseFolders));
                RaisePropertyChanged(nameof(CanSubmit));
                RaisePropertyChanged(nameof(IsTransferring));
            }
        }
    }

    public long TransferredBytes
    {
        get => _transferredBytes;
        private set => SetProperty(ref _transferredBytes, value);
    }

    public long TotalBytes
    {
        get => _totalBytes;
        private set => SetProperty(ref _totalBytes, value);
    }

    public string? ResultMessage
    {
        get => _resultMessage;
        private set => SetProperty(ref _resultMessage, value);
    }

    public bool CanBrowseFolders =>
        State == CrossNasCopyMoveState.ChoosingTarget &&
        SelectedTarget is not null;

    public bool CanSubmit =>
        State == CrossNasCopyMoveState.ChoosingDestination &&
        DestinationCanWrite &&
        DestinationPath.Length > 0 &&
        IsDestination(DestinationPath);

    public bool IsTransferring =>
        State == CrossNasCopyMoveState.Transferring;

    public async Task SelectTargetAndLoadAsync(NasProfile target)
    {
        ThrowIfDisposed();
        if (State != CrossNasCopyMoveState.ChoosingTarget) return;
        SelectedTarget = target;

        var generation = BeginRequest(out var cancellation);
        State = CrossNasCopyMoveState.LoadingFolders;
        try
        {
            ReleaseTargetFolderSource();
            _targetFolderSource = await _targetFolderSourceFactory(
                target.Id, cancellation.Token).ConfigureAwait(false);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrent(generation)) return;
            if (_targetFolderSource is null ||
                _targetFolderSource.ProfileId != target.Id)
            {
                ReleaseTargetFolderSource();
                State = CrossNasCopyMoveState.TargetUnavailable;
                return;
            }
            _targetFolderLease = _targetFolderSource as IDisposable;
            await LoadFoldersCoreAsync(
                string.Empty,
                destinationCanWrite: true,
                generation,
                cancellation).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!IsCurrent(generation)) { }
        catch when (IsCurrent(generation))
        {
            ReleaseTargetFolderSource();
            State = CrossNasCopyMoveState.TargetUnavailable;
        }
        finally
        {
            EndRequest(cancellation);
        }
    }

    public async Task LoadFoldersAsync(string path, bool destinationCanWrite = false)
    {
        ThrowIfDisposed();
        if (_targetFolderSource is null ||
            State is CrossNasCopyMoveState.Transferring or CrossNasCopyMoveState.Completed)
            return;
        if (!IsFolderPath(path))
        {
            State = CrossNasCopyMoveState.Unsupported;
            return;
        }

        var generation = BeginRequest(out var cancellation);
        try
        {
            await LoadFoldersCoreAsync(
                path,
                destinationCanWrite,
                generation,
                cancellation).ConfigureAwait(false);
        }
        finally { EndRequest(cancellation); }
    }

    private async Task LoadFoldersCoreAsync(
        string path,
        bool destinationCanWrite,
        long generation,
        CancellationTokenSource cancellation)
    {
        State = CrossNasCopyMoveState.LoadingFolders;
        try
        {
            var targetFolderSource = _targetFolderSource
                ?? throw new InvalidOperationException("file.cross-nas.target-not-ready");
            var folders = await targetFolderSource.LoadFoldersAsync(
                path, cancellation.Token).ConfigureAwait(false);
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrent(generation)) return;
            if (folders.Any(f => !IsDestination(f.Path)))
                throw new InvalidDataException("file.cross-nas.invalid-folder-result");

            DestinationPath = path;
            DestinationCanWrite = path.Length > 0 && destinationCanWrite;
            Folders = folders
                .Where(f => f.CanWrite && IsSafeDestination(f.Path))
                .ToArray();
            State = CrossNasCopyMoveState.ChoosingDestination;
        }
        catch (OperationCanceledException) when (!IsCurrent(generation)) { }
        catch when (IsCurrent(generation)) { State = CrossNasCopyMoveState.Failure; }
    }

    public async Task SubmitAsync()
    {
        ThrowIfDisposed();
        if (!CanSubmit || SelectedTarget is null) return;

        var generation = BeginRequest(out var cancellation);
        State = CrossNasCopyMoveState.Transferring;
        TransferredBytes = 0;

        // 文件按下载和上传两段累计，文件夹由最终树核对完成确认。
        TotalBytes = Source.IsDirectory ? 0 : Source.Size * 2;

        try
        {
            var request = new CrossNasCopyMoveRequest(
                _sourceProfileId,
                SelectedTarget.Id,
                Source.Path,
                Source.Name,
                Source.IsDirectory,
                Source.Size,
                DestinationPath,
                Overwrite: false,
                Operation == FileCopyMoveOperation.Copy
                    ? CrossNasCopyMoveOperation.Copy
                    : CrossNasCopyMoveOperation.Move);

            var progress = new Progress<long>(reported =>
            {
                if (IsCurrent(generation))
                {
                    TransferredBytes = reported;
                }
            });

            var outcome = await _sourceRepository.CrossNasCopyMoveAsync(
                request, progress, cancellation.Token).ConfigureAwait(false);

            if (!IsCurrent(generation)) return;

            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                ResultMessage = null;
                State = CrossNasCopyMoveState.Completed;
            }
            else if (outcome.Result.Status == MutationResultStatus.CancelledBeforeSubmission)
            {
                ResultMessage = null;
                State = CrossNasCopyMoveState.ChoosingDestination;
            }
            else if (outcome.Result.Status == MutationResultStatus.Unsupported)
            {
                if (IsTargetUnavailable(outcome.Result.DiagnosticTag))
                {
                    ResultMessage = outcome.Result.DiagnosticTag;
                    State = CrossNasCopyMoveState.TargetUnavailable;
                }
                else
                {
                    ResultMessage = null;
                    State = CrossNasCopyMoveState.Unsupported;
                }
            }
            else
            {
                ResultMessage = outcome.Result.DiagnosticTag ?? "file.cross-nas.failed";
                State = CrossNasCopyMoveState.Failure;
            }
        }
        catch (OperationCanceledException) when (IsCurrent(generation))
        {
            State = CrossNasCopyMoveState.ChoosingDestination;
        }
        catch when (IsCurrent(generation))
        {
            ResultMessage = "file.cross-nas.failed";
            State = CrossNasCopyMoveState.Failure;
        }
        finally { EndRequest(cancellation); }
    }

    public void Cancel()
    {
        Interlocked.Increment(ref _generation);
        _request?.Cancel();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Cancel();
        _request?.Dispose();
        _request = null;
        ReleaseTargetFolderSource();
    }

    private long BeginRequest(out CancellationTokenSource cancellation)
    {
        _request?.Cancel();
        _request?.Dispose();
        cancellation = new CancellationTokenSource();
        _request = cancellation;
        return Interlocked.Increment(ref _generation);
    }

    private void EndRequest(CancellationTokenSource value)
    {
        value.Dispose();
        if (ReferenceEquals(_request, value)) _request = null;
    }

    private bool IsCurrent(long generation) =>
        !_disposed && generation == _generation;

    private void ReleaseTargetFolderSource()
    {
        _targetFolderSource = null;
        _targetFolderLease?.Dispose();
        _targetFolderLease = null;
    }

    private static bool IsTargetUnavailable(string? diagnosticTag) =>
        diagnosticTag is
            "file.cross-nas.target-not-found" or
            "file.cross-nas.target-no-capability" or
            "file.cross-nas.no-second-session" or
            "file.cross-nas.no-resolver";

    private static bool IsOrdinaryItem(FileItem item) =>
        FileMutationViewModel.IsMutablePath(item.Path);

    private bool IsSafeDestination(string path) =>
        !Source.IsDirectory ||
        (path != Source.Path && !path.StartsWith(Source.Path + "/", StringComparison.Ordinal));

    private static bool IsDestination(string path) =>
        FileMutationViewModel.IsMutablePath(path);

    private static bool IsFolderPath(string path) =>
        path.Length == 0 || IsDestination(path);

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);
}
