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
    Recoverable,
    Refreshing,
    SourceDeletionReady,
    ConfirmingSourceDeletion,
    DeletingSources,
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
    private bool _disposed, _restoring;
    private Guid _operationId = Guid.NewGuid();
    private string? _targetIdentity;
    private CrossNasCopyMoveOutcome? _outcome;
    private IReadOnlyList<CrossNasTransferSummary> _history = [];

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
    public CrossNasCopyMoveOutcome? Outcome { get => _outcome; private set => SetProperty(ref _outcome, value); }
    public IReadOnlyList<CrossNasTransferSummary> History { get => _history; private set => SetProperty(ref _history, value); }
    public bool CanRefresh => Outcome is { RecoveryStorageUnavailable: false } && State is CrossNasCopyMoveState.Recoverable or CrossNasCopyMoveState.SourceDeletionReady or CrossNasCopyMoveState.Completed;
    public bool CanContinue => State == CrossNasCopyMoveState.Recoverable && Outcome?.CanContinue == true;
    public bool CanDeleteSources => State == CrossNasCopyMoveState.SourceDeletionReady && Outcome?.CanDeleteSources == true;

    public void RequestSourceDeletionConfirmation()
    {
        ThrowIfDisposed();
        if (CanDeleteSources) State = CrossNasCopyMoveState.ConfirmingSourceDeletion;
    }
    public void CancelSourceDeletionConfirmation()
    {
        ThrowIfDisposed();
        if (State == CrossNasCopyMoveState.ConfirmingSourceDeletion && Outcome is { } outcome) ApplyOutcome(outcome);
    }
    public async Task ConfirmSourceDeletionAsync()
    {
        ThrowIfDisposed();
        if (State != CrossNasCopyMoveState.ConfirmingSourceDeletion || Outcome?.CanDeleteSources != true) return;
        var generation = BeginRequest(out var cancellation);
        State = CrossNasCopyMoveState.DeletingSources;
        try
        {
            var outcome = await _sourceRepository.DeleteCrossNasSourcesAsync(_operationId, confirmed: true, cancellation.Token).ConfigureAwait(false);
            if (!IsCurrent(generation)) return;
            if (outcome is null) { State = CrossNasCopyMoveState.TargetUnavailable; return; }
            ApplyOutcome(outcome);
        }
        catch when (IsCurrent(generation)) { State = CrossNasCopyMoveState.Recoverable; }
        finally { EndRequest(cancellation); }
    }

    public async Task LoadHistoryAsync(bool includeCompleted = false)
    {
        var generation = BeginRequest(out var cancellation);
        try
        {
            var history = await _sourceRepository.GetCrossNasTransfersAsync(cancellation.Token).ConfigureAwait(false);
            if (IsCurrent(generation)) History = history.Where(item => item.SourceProfileId == _sourceProfileId && item.SourcePath == Source.Path &&
                (includeCompleted || item.Outcome.RequiresReadOnlyRecovery || item.Outcome.Result.Status != MutationResultStatus.ConfirmedSuccess || item.Outcome.CanDeleteSources ||
                    item.Outcome.SourceDeletion is { Result.Status: not MutationResultStatus.ConfirmedSuccess })).ToArray();
        }
        catch when (IsCurrent(generation)) { State = CrossNasCopyMoveState.Failure; }
        finally { EndRequest(cancellation); }
    }

    public async Task RestoreAsync(CrossNasTransferSummary summary)
    {
        ThrowIfDisposed();
        if (!History.Contains(summary) || State != CrossNasCopyMoveState.ChoosingTarget) return;
        _restoring = true;
        var target = TargetProfiles.FirstOrDefault(item => item.Id == summary.TargetProfileId);
        if (target is null) { State = CrossNasCopyMoveState.TargetUnavailable; return; }
        await SelectTargetAndLoadAsync(target).ConfigureAwait(false);
        if (_disposed || State != CrossNasCopyMoveState.ChoosingDestination) return;
        DestinationPath = summary.DestinationFolderPath;
        _operationId = summary.Id;
        ApplyOutcome(summary.Outcome);
        await RefreshAsync().ConfigureAwait(false);
    }

    public async Task RefreshAsync() => await RecoverAsync(continueRemaining: false).ConfigureAwait(false);
    public async Task ContinueAsync() => await RecoverAsync(continueRemaining: true).ConfigureAwait(false);
    private async Task RecoverAsync(bool continueRemaining)
    {
        ThrowIfDisposed();
        if (continueRemaining ? !CanContinue : !CanRefresh) return;
        var generation = BeginRequest(out var cancellation);
        State = continueRemaining ? CrossNasCopyMoveState.Transferring : CrossNasCopyMoveState.Refreshing;
        try
        {
            var progress = new Progress<long>(value => { if (IsCurrent(generation)) TransferredBytes = value; });
            var outcome = continueRemaining
                ? await _sourceRepository.ContinueCrossNasTransferAsync(_operationId, progress, cancellation.Token).ConfigureAwait(false)
                : await _sourceRepository.ReviewCrossNasTransferAsync(_operationId, cancellation.Token).ConfigureAwait(false);
            if (!IsCurrent(generation)) return;
            if (outcome is null) { State = CrossNasCopyMoveState.TargetUnavailable; return; }
            ApplyOutcome(outcome);
        }
        catch when (IsCurrent(generation)) { State = CrossNasCopyMoveState.Recoverable; }
        finally { EndRequest(cancellation); }
    }

    private void ApplyOutcome(CrossNasCopyMoveOutcome outcome)
    {
        Outcome = outcome;
        if (outcome.OperationId != Guid.Empty) _operationId = outcome.OperationId;
        ResultMessage = outcome.Result.DiagnosticTag;
        State = outcome.Result.Status switch
        {
            _ when outcome.RecoveryStorageUnavailable || outcome.RequiresReadOnlyRecovery || outcome.CanContinue || outcome.IsRunning => CrossNasCopyMoveState.Recoverable,
            _ when outcome.SourceDeletion?.Result.Status == MutationResultStatus.ConfirmedSuccess => CrossNasCopyMoveState.Completed,
            _ when outcome.CanDeleteSources => CrossNasCopyMoveState.SourceDeletionReady,
            _ when outcome.SourceDeletion is not null => CrossNasCopyMoveState.Recoverable,
            MutationResultStatus.ConfirmedSuccess => CrossNasCopyMoveState.Completed,
            MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess => CrossNasCopyMoveState.Recoverable,
            MutationResultStatus.CancelledBeforeSubmission when outcome.CanContinue => CrossNasCopyMoveState.Recoverable,
            MutationResultStatus.CancelledBeforeSubmission => CrossNasCopyMoveState.ChoosingDestination,
            MutationResultStatus.Unsupported when IsTargetUnavailable(outcome.Result.DiagnosticTag) => CrossNasCopyMoveState.TargetUnavailable,
            MutationResultStatus.Unsupported => CrossNasCopyMoveState.Unsupported,
            _ => CrossNasCopyMoveState.Failure,
        };
        if (State == CrossNasCopyMoveState.Unsupported) ResultMessage = null;
    }

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
                RaisePropertyChanged(nameof(CanRefresh));
                RaisePropertyChanged(nameof(CanContinue));
                RaisePropertyChanged(nameof(CanDeleteSources));
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
        !_restoring && State == CrossNasCopyMoveState.ChoosingDestination &&
        DestinationCanWrite &&
        DestinationPath.Length > 0 &&
        IsDestination(DestinationPath);

    public bool IsTransferring =>
        State is CrossNasCopyMoveState.Transferring or CrossNasCopyMoveState.Refreshing or CrossNasCopyMoveState.DeletingSources;

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
            var restored = await _targetFolderSourceFactory(
                target.Id, cancellation.Token).ConfigureAwait(false);
            if (!IsCurrent(generation) || cancellation.IsCancellationRequested)
            {
                (restored as IDisposable)?.Dispose();
                return;
            }
            _targetFolderSource = restored;
            _targetFolderLease = restored as IDisposable;
            cancellation.Token.ThrowIfCancellationRequested();
            if (!IsCurrent(generation)) return;
            if (_targetFolderSource is null ||
                _targetFolderSource.ProfileId != target.Id)
            {
                ReleaseTargetFolderSource();
                State = CrossNasCopyMoveState.TargetUnavailable;
                return;
            }
            _targetIdentity = _sourceRepository.GetCrossNasTargetIdentity(target.Id);
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
            State is not (CrossNasCopyMoveState.ChoosingDestination or CrossNasCopyMoveState.LoadingFolders))
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
                .Where(f => f.CanWrite)
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
        TotalBytes = Source.IsDirectory || Source.Size > long.MaxValue / 2 ? 0 : Source.Size * 2;

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
                    : CrossNasCopyMoveOperation.Move,
                _operationId) { TargetIdentity = _targetIdentity, SourceModifiedAt = Source.ModifiedAt };

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

            ApplyOutcome(outcome);
        }
        catch (OperationCanceledException) when (IsCurrent(generation))
        {
            ResultMessage = "file.cross-nas.result-unavailable";
            State = CrossNasCopyMoveState.Recoverable;
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
        if (!IsTransferring) Interlocked.Increment(ref _generation);
        _request?.Cancel();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Interlocked.Increment(ref _generation);
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

    private static bool IsDestination(string path) =>
        FileMutationViewModel.IsMutablePath(path);

    private static bool IsFolderPath(string path) =>
        path.Length == 0 || IsDestination(path);

    private void ThrowIfDisposed() =>
        ObjectDisposedException.ThrowIf(_disposed, this);
}
