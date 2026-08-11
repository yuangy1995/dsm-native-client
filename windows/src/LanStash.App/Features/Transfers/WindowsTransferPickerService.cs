using LanStash.App.Localization;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Mutations;
using LanStash.App.Features.Photos.Import;
using LanStash.Domain;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.Windows.Storage.Pickers;
using Windows.Storage;
using WinRT.Interop;

namespace LanStash.App.Features.Transfers;

internal interface IWindowsTransferSavePicker
{
    Task<string?> PickSavePathAsync(string suggestedName);

    Task<string?> PickArchiveSavePathAsync(string suggestedName) =>
        PickSavePathAsync(suggestedName);
}

internal interface IWindowsTransferOpenPicker
{
    Task<string?> PickSingleFilePathAsync(IReadOnlyList<string>? fileTypeFilters = null);
    Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(
        IReadOnlyList<string>? fileTypeFilters = null);
    Task<string?> PickSingleFolderPathAsync();
}

internal sealed class WindowsTransferSavePicker(Func<Window?> windowProvider)
    : IWindowsTransferSavePicker
{
    public async Task<string?> PickSavePathAsync(string suggestedName)
        => await PickSavePathAsync(suggestedName, "TransferOriginalFileType");

    public async Task<string?> PickArchiveSavePathAsync(string suggestedName)
        => await PickSavePathAsync(suggestedName, "TransferArchiveFileType");

    private async Task<string?> PickSavePathAsync(
        string suggestedName,
        string fileTypeResourceKey)
    {
        var window = windowProvider();
        if (window is null)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var extension = Path.GetExtension(suggestedName);
        var picker = new FileSavePicker(windowId)
        {
            SuggestedFileName = suggestedName,
        };
        if (!string.IsNullOrWhiteSpace(extension))
        {
            picker.DefaultFileExtension = extension;
            picker.FileTypeChoices.Add(
                LocalizationService.Current.Get(fileTypeResourceKey),
                [extension]);
        }
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }
}

internal sealed class WindowsTransferOpenPicker(Func<Window?> windowProvider)
    : IWindowsTransferOpenPicker
{
    public async Task<string?> PickSingleFilePathAsync(
        IReadOnlyList<string>? fileTypeFilters = null)
    {
        var window = windowProvider();
        if (window is null)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var picker = new FileOpenPicker(windowId);
        if (fileTypeFilters is not null)
        {
            foreach (var filter in fileTypeFilters)
            {
                picker.FileTypeFilter.Add(filter);
            }
        }
        var result = await picker.PickSingleFileAsync();
        return result?.Path;
    }

    public async Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(
        IReadOnlyList<string>? fileTypeFilters = null)
    {
        var window = windowProvider();
        if (window is null)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var picker = new FileOpenPicker(windowId);
        if (fileTypeFilters is not null)
        {
            foreach (var filter in fileTypeFilters)
            {
                picker.FileTypeFilter.Add(filter);
            }
        }
        var results = await picker.PickMultipleFilesAsync();
        return results?.Select(result => result.Path).ToArray();
    }

    public async Task<string?> PickSingleFolderPathAsync()
    {
        var window = windowProvider();
        if (window is null)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var picker = new FolderPicker(windowId);
        var result = await picker.PickSingleFolderAsync();
        return result?.Path;
    }
}

internal sealed class WindowsTransferPickerService : IPhotoImportTransferService, IDisposable
{
    private static readonly string[] MediaFileTypeFilters =
    [
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff",
        ".heic", ".heif", ".webp", ".mp4", ".mov", ".m4v", ".avi",
        ".mkv", ".webm",
    ];
    private static readonly HashSet<string> MediaFileExtensions =
        new(MediaFileTypeFilters, StringComparer.OrdinalIgnoreCase);
    private readonly object _sync = new();
    private readonly IDsmRepository _repository;
    private readonly SafeFileDownloadService _downloadService;
    private readonly SafeFolderArchiveDownloadService _archiveDownloadService;
    private readonly ForegroundTransferCoordinator _coordinator;
    private readonly IWindowsTransferSavePicker _savePicker;
    private readonly IWindowsTransferOpenPicker _openPicker;
    private readonly List<RunningTransfer> _running = [];
    private readonly Dictionary<UploadTargetKey, Guid> _batchReservations = [];
    private readonly Dictionary<Guid, CancellationTokenSource> _batchCancellations = [];
    private readonly Dictionary<UploadTargetKey, Guid> _folderBatchTargets = [];
    private readonly Dictionary<string, Guid> _downloadBatchReservations =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, CancellationTokenSource> _downloadBatchCancellations = [];
    private bool _disposed;

    public WindowsTransferPickerService(
        IDsmRepository repository,
        ForegroundTransferCoordinator coordinator,
        IWindowsTransferSavePicker savePicker,
        IWindowsTransferOpenPicker openPicker)
    {
        _repository = repository;
        _coordinator = coordinator;
        _savePicker = savePicker;
        _openPicker = openPicker;
        _downloadService = new SafeFileDownloadService();
        _archiveDownloadService = new SafeFolderArchiveDownloadService();
    }

    public event Action<ForegroundUploadFinished>? UploadFinished;
    public event Action<ForegroundUploadBatchFinished>? UploadBatchFinished;
    public event Action<FolderUploadBatchFinished>? FolderUploadBatchFinished;
    public event Action<ForegroundDownloadBatchFinished>? DownloadBatchFinished;
    public event Action<PhotoMediaUploadFinished>? MediaUploadFinished;
    public event Action<PhotoMediaUploadInterrupted>? MediaUploadInterrupted;

    public async Task<bool> PickAndStartDownloadAsync(
        string profileId,
        FileBrowserEntry entry)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentNullException.ThrowIfNull(entry);
        string? targetPath;
        try
        {
            targetPath = entry.IsDirectory
                ? await _savePicker.PickArchiveSavePathAsync($"{entry.Name}.zip")
                : await _savePicker.PickSavePathAsync(entry.Name);
        }
        catch
        {
            throw;
        }
        if (targetPath is null)
        {
            return false;
        }

        var running = PrepareDownload(profileId, targetPath, batchId: null);
        if (entry.IsDirectory)
        {
            _ = RunFolderArchiveDownloadAsync(running, entry, targetPath);
        }
        else
        {
            _ = RunDownloadAsync(running, entry, targetPath, allowReplaceExisting: true);
        }
        return true;
    }

    public async Task<ForegroundDownloadBatchStart> PickAndStartDownloadBatchAsync(
        string profileId,
        IReadOnlyList<FileDownloadBatchItem> items)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentNullException.ThrowIfNull(items);
        var validation = BoundedFileDownloadBatch.Validate(items);
        if (validation != FileDownloadBatchValidationStatus.Valid)
        {
            return new ForegroundDownloadBatchStart(validation);
        }

        var targetFolderPath = await _openPicker.PickSingleFolderPathAsync();
        if (targetFolderPath is null)
        {
            return new ForegroundDownloadBatchStart(FileDownloadBatchValidationStatus.Empty);
        }
        var targetFolder = await StorageFolder.GetFolderFromPathAsync(targetFolderPath);
        foreach (var item in items)
        {
            if (await targetFolder.TryGetItemAsync(item.Name) is not null)
            {
                return new ForegroundDownloadBatchStart(
                    FileDownloadBatchValidationStatus.TargetExists);
            }
        }

        var targetPaths = items
            .Select(item => Path.Combine(targetFolderPath, item.Name))
            .ToArray();
        var batchId = Guid.NewGuid();
        CancellationTokenSource batchCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (targetPaths.Any(target =>
                    _downloadBatchReservations.ContainsKey(target) ||
                    _running.Any(running => string.Equals(
                        running.LocalTargetPath,
                        target,
                        StringComparison.OrdinalIgnoreCase))))
            {
                return new ForegroundDownloadBatchStart(
                    FileDownloadBatchValidationStatus.TargetBusy);
            }
            foreach (var target in targetPaths)
            {
                _downloadBatchReservations.Add(target, batchId);
            }
            batchCancellation = new CancellationTokenSource();
            _downloadBatchCancellations.Add(batchId, batchCancellation);
        }

        _ = RunDownloadBatchAsync(
            batchId,
            profileId,
            items,
            targetPaths,
            batchCancellation);
        return new ForegroundDownloadBatchStart(
            FileDownloadBatchValidationStatus.Valid,
            batchId);
    }

    public async Task<bool> PickAndStartUploadAsync(
        string profileId,
        string folderPath) =>
        await PickAndStartUploadCoreAsync(
            profileId,
            folderPath,
            fileTypeFilters: null,
            requiresMediaExtension: false) is not null;

    public async Task<ForegroundUploadBatchStart> PickAndStartUploadBatchAsync(
        string profileId,
        string folderPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        var sourcePaths = await _openPicker.PickMultipleFilePathsAsync();
        return sourcePaths is null
            ? new ForegroundUploadBatchStart(FileUploadBatchValidationStatus.Empty, 0)
            : new ForegroundUploadBatchStart(
                StartUploadBatch(profileId, folderPath, sourcePaths),
                sourcePaths.Count);
    }

    public FileUploadBatchValidationStatus StartUploadBatch(
        string profileId,
        string folderPath,
        IReadOnlyList<string> sourcePaths)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        ArgumentNullException.ThrowIfNull(sourcePaths);

        var validation = BoundedFileUploadBatch.ValidatePaths(sourcePaths);
        if (validation != FileUploadBatchValidationStatus.Valid)
        {
            return validation;
        }

        var paths = sourcePaths.ToArray();
        var targets = paths
            .Select(path => CreateUploadTargetKey(profileId, folderPath, Path.GetFileName(path)))
            .ToArray();
        var batchId = Guid.NewGuid();
        CancellationTokenSource batchCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (targets.Any(target =>
                    _batchReservations.ContainsKey(target) ||
                    _running.Any(item => item.UploadTarget == target)))
            {
                return FileUploadBatchValidationStatus.TargetBusy;
            }
            foreach (var target in targets)
            {
                _batchReservations.Add(target, batchId);
            }
            batchCancellation = new CancellationTokenSource();
            _batchCancellations.Add(batchId, batchCancellation);
        }

        _ = RunUploadBatchAsync(
            batchId,
            profileId,
            folderPath,
            paths,
            targets,
            batchCancellation);
        return FileUploadBatchValidationStatus.Valid;
    }

    public async Task<FolderUploadPlanResult?> PickFolderUploadPlanAsync()
    {
        var sourcePath = await _openPicker.PickSingleFolderPathAsync();
        return sourcePath is null
            ? null
            : await Task.Run(() => BoundedFolderUploadPlan.Create(sourcePath));
    }

    public Task<FolderUploadPlanResult> PlanFolderUploadAsync(string sourcePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        return Task.Run(() => BoundedFolderUploadPlan.Create(sourcePath));
    }

    public FolderUploadBatchStart StartFolderUpload(
        string profileId,
        string folderPath,
        FolderUploadPlan plan)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        ArgumentNullException.ThrowIfNull(plan);
        if (!Guid.TryParse(profileId, out var parsedProfileId) ||
            _repository is not IFileMutationRepository mutationRepository ||
            mutationRepository.ProfileId != parsedProfileId ||
            !mutationRepository.FileMutationAvailability.CanCreateFolder)
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.Unsupported);
        }
        if (!BoundedFolderUploadPlan.IsCurrent(plan))
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.SourceChanged);
        }
        if (plan.Directories.Any(directory =>
                FileMutationReviewBlocker.Current.Find(
                    parsedProfileId,
                    FileMutationOperation.CreateFolder,
                    RemoteParentForDirectory(
                        folderPath,
                        plan.RootName,
                        directory.RelativePath)) is not null))
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.NeedsReview);
        }

        var batchId = Guid.NewGuid();
        var directoryTargets = plan.Directories
            .Select(directory => CreateUploadTargetKey(
                profileId,
                RemoteParentForDirectory(
                    folderPath,
                    plan.RootName,
                    directory.RelativePath),
                directory.Name))
            .ToArray();
        var fileTargets = plan.Files
            .Select(file => CreateUploadTargetKey(
                profileId,
                RemoteFolderForFile(folderPath, plan.RootName, file.RelativePath),
                file.Name))
            .ToArray();
        CancellationTokenSource batchCancellation;
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (directoryTargets.Any(target =>
                    _folderBatchTargets.ContainsKey(target) ||
                    _batchReservations.ContainsKey(target) ||
                    _running.Any(item => item.UploadTarget == target)) ||
                fileTargets.Any(target =>
                    _folderBatchTargets.ContainsKey(target) ||
                    _batchReservations.ContainsKey(target) ||
                    _running.Any(item => item.UploadTarget == target)))
            {
                return new FolderUploadBatchStart(FolderUploadBatchStartStatus.Busy);
            }
            foreach (var target in directoryTargets)
            {
                _folderBatchTargets.Add(target, batchId);
            }
            foreach (var target in fileTargets)
            {
                _batchReservations.Add(target, batchId);
            }
            batchCancellation = new CancellationTokenSource();
            _batchCancellations.Add(batchId, batchCancellation);
        }

        _ = RunFolderUploadBatchAsync(
            batchId,
            parsedProfileId,
            profileId,
            folderPath,
            plan,
            mutationRepository,
            directoryTargets,
            fileTargets,
            batchCancellation);
        return new FolderUploadBatchStart(FolderUploadBatchStartStatus.Started, batchId);
    }

    public async Task<bool> StartUploadAsync(
        string profileId,
        string folderPath,
        string sourcePath) =>
        await StartUploadFromPathCoreAsync(
            profileId,
            folderPath,
            sourcePath,
            requiresMediaExtension: false) is not null;

    public Task<PhotoMediaUploadStart?> PickAndStartMediaUploadAsync(
        string profileId,
        string folderPath,
        Guid activityId)
    {
        if (activityId == Guid.Empty)
        {
            throw new ArgumentOutOfRangeException(nameof(activityId));
        }
        return PickAndStartUploadCoreAsync(
            profileId,
            folderPath,
            MediaFileTypeFilters,
            requiresMediaExtension: true,
            activityId);
    }

    public Task<PhotoMediaUploadStart?> StartMediaUploadAsync(
        string profileId,
        string folderPath,
        string sourcePath,
        Guid activityId)
    {
        if (activityId == Guid.Empty)
        {
            throw new ArgumentOutOfRangeException(nameof(activityId));
        }
        return StartUploadFromPathCoreAsync(
            profileId,
            folderPath,
            sourcePath,
            requiresMediaExtension: true,
            activityId);
    }

    internal static bool IsSupportedMediaPath(string? sourcePath) =>
        !string.IsNullOrWhiteSpace(sourcePath) &&
        MediaFileExtensions.Contains(Path.GetExtension(sourcePath));

    private async Task<PhotoMediaUploadStart?> PickAndStartUploadCoreAsync(
        string profileId,
        string folderPath,
        IReadOnlyList<string>? fileTypeFilters,
        bool requiresMediaExtension,
        Guid? requestedActivityId = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);

        var sourcePath = await _openPicker.PickSingleFilePathAsync(fileTypeFilters);
        if (sourcePath is null)
        {
            return null;
        }
        return await StartUploadFromPathCoreAsync(
            profileId,
            folderPath,
            sourcePath,
            requiresMediaExtension,
            requestedActivityId);
    }

    private Task<PhotoMediaUploadStart?> StartUploadFromPathCoreAsync(
        string profileId,
        string folderPath,
        string sourcePath,
        bool requiresMediaExtension,
        Guid? requestedActivityId = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        if (requiresMediaExtension && !IsSupportedMediaPath(sourcePath))
        {
            throw new InvalidDataException("upload.unsupported_media_type");
        }

        var prepared = PrepareUpload(
            profileId,
            folderPath,
            sourcePath,
            requiresMediaExtension,
            requestedActivityId,
            batchId: null);
        _ = RunUploadAsync(prepared.Running, prepared.Request);
        return Task.FromResult<PhotoMediaUploadStart?>(
            new PhotoMediaUploadStart(prepared.Running.ActivityId));
    }

    private PreparedUpload PrepareUpload(
        string profileId,
        string folderPath,
        string sourcePath,
        bool requiresMediaExtension,
        Guid? requestedActivityId,
        Guid? batchId,
        CancellationToken batchCancellationToken = default)
    {
        var source = new FileStream(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);

        var fileName = Path.GetFileName(sourcePath);
        long length;
        try
        {
            if (string.IsNullOrWhiteSpace(fileName))
            {
                throw new InvalidDataException("upload.invalid_file_name");
            }
            length = source.Length;
        }
        catch
        {
            source.Dispose();
            throw;
        }

        FileUploadRequest request;
        try
        {
            request = new FileUploadRequest(
                source,
                length,
                folderPath,
                fileName,
                overwrite: false);
        }
        catch
        {
            source.Dispose();
            throw;
        }

        var uploadTarget = CreateUploadTargetKey(profileId, folderPath, fileName);
        CancellationTokenSource cancellation;
        RunningTransfer running;
        lock (_sync)
        {
            if (_disposed)
            {
                source.Dispose();
                throw new ObjectDisposedException(nameof(WindowsTransferPickerService));
            }
            if (_running.Any(item => item.UploadTarget == uploadTarget) ||
                (_folderBatchTargets.TryGetValue(uploadTarget, out var folderOwner) &&
                    folderOwner != batchId) ||
                (_batchReservations.TryGetValue(uploadTarget, out var reservationOwner) &&
                    reservationOwner != batchId))
            {
                source.Dispose();
                throw new InvalidOperationException("upload.target_busy");
            }
            cancellation = CancellationTokenSource.CreateLinkedTokenSource(
                batchCancellationToken);
            running = new RunningTransfer(
                requestedActivityId ?? Guid.NewGuid(),
                profileId,
                cancellation,
                IsMedia: requiresMediaExtension,
                UploadTarget: uploadTarget,
                IsBatch: batchId is not null);
            _running.Add(running);
        }
        return new PreparedUpload(running, request);
    }

    public void Cancel(string profileId, Guid activityId)
    {
        CancellationTokenSource[] matches;
        lock (_sync)
        {
            matches = _running
                .Where(item =>
                    string.Equals(item.ProfileId, profileId, StringComparison.Ordinal) &&
                    item.ActivityId == activityId)
                .Select(item => item.Cancellation)
                .ToArray();
        }

        foreach (var cancellation in matches)
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // 完成回收与用户点击取消可能相邻发生，此时任务已经结束。
            }
        }
    }

    public void Dispose()
    {
        RunningTransfer[] running;
        CancellationTokenSource[] batchCancellations;
        CancellationTokenSource[] downloadBatchCancellations;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            running = _running.ToArray();
            _running.Clear();
            _batchReservations.Clear();
            _folderBatchTargets.Clear();
            _downloadBatchReservations.Clear();
            batchCancellations = _batchCancellations.Values.ToArray();
            _batchCancellations.Clear();
            downloadBatchCancellations = _downloadBatchCancellations.Values.ToArray();
            _downloadBatchCancellations.Clear();
        }

        foreach (var transfer in running)
        {
            try
            {
                transfer.Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }
        foreach (var cancellation in batchCancellations)
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }
        foreach (var cancellation in downloadBatchCancellations)
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
            }
        }
    }

    private async Task<FileDownloadBatchAttempt> RunDownloadAsync(
        RunningTransfer running,
        FileBrowserEntry entry,
        string targetPath,
        bool allowReplaceExisting)
    {
        try
        {
            await _coordinator.RunAsync(
                new ForegroundDownloadRequest(
                    running.ProfileId,
                    entry.Path,
                    entry.Name,
                    entry.Item.Size,
                    running.ActivityId),
                async (progress, cancellationToken) =>
                {
                    var destination =
                        await WindowsTransactionalDownloadDestination.CreateAsync(
                            targetPath,
                            allowReplaceExisting);
                    await _downloadService.DownloadAsync(
                        _repository,
                        entry.Path,
                        entry.Item.Size,
                        destination,
                        progress,
                        cancellationToken);
                },
                running.Cancellation.Token);
            return new FileDownloadBatchAttempt(
                FileDownloadBatchAttemptStatus.Completed,
                StopBatch: running.Cancellation.IsCancellationRequested);
        }
        catch (OperationCanceledException)
        {
            return new FileDownloadBatchAttempt(FileDownloadBatchAttemptStatus.Cancelled);
        }
        catch
        {
            // 前台活动页展示稳定、可操作的本地化错误，不在此泄露内部异常。
            return new FileDownloadBatchAttempt(
                FileDownloadBatchAttemptStatus.Failed,
                StopBatch: running.Cancellation.IsCancellationRequested);
        }
        finally
        {
            lock (_sync)
            {
                _running.Remove(running);
            }
            running.Cancellation.Dispose();
        }
    }

    private async Task RunFolderArchiveDownloadAsync(
        RunningTransfer running,
        FileBrowserEntry entry,
        string targetPath)
    {
        try
        {
            await _coordinator.RunAsync(
                new ForegroundDownloadRequest(
                    running.ProfileId,
                    entry.Path,
                    Path.GetFileName(targetPath),
                    0,
                    running.ActivityId),
                async (_, cancellationToken) =>
                {
                    var destination =
                        await WindowsTransactionalDownloadDestination.CreateAsync(
                            targetPath,
                            validateZipArchive: true);
                    await _archiveDownloadService.DownloadAsync(
                        _repository,
                        entry.Path,
                        destination,
                        cancellationToken);
                },
                running.Cancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // Activity 展示稳定失败状态；页面继续可重试选择其他目标。
        }
        finally
        {
            lock (_sync)
            {
                _running.Remove(running);
            }
            running.Cancellation.Dispose();
        }
    }

    private async Task<FileUploadBatchAttempt> RunUploadAsync(
        RunningTransfer running,
        FileUploadRequest upload)
    {
        try
        {
            var result = await _coordinator.RunUploadAsync(
                new ForegroundUploadRequest(
                    running.ProfileId,
                    upload.FolderPath,
                    upload.FileName,
                    upload.Length,
                    running.ActivityId),
                (progress, cancellationToken) => _repository.UploadFileAsync(
                    upload,
                    progress,
                    cancellationToken),
                running.Cancellation.Token);
            if (!running.IsBatch)
            {
                UploadFinished?.Invoke(new ForegroundUploadFinished(
                    running.ProfileId,
                    upload.FolderPath,
                    result));
            }
            if (running.IsMedia)
            {
                MediaUploadFinished?.Invoke(new PhotoMediaUploadFinished(
                    running.ActivityId,
                    running.ProfileId,
                    upload.FolderPath,
                    result));
            }
            return new FileUploadBatchAttempt(result.Status switch
            {
                MutationResultStatus.ConfirmedSuccess => FileUploadBatchAttemptStatus.Confirmed,
                MutationResultStatus.SubmittedButUnverified or
                    MutationResultStatus.PartialSuccess => FileUploadBatchAttemptStatus.NeedsReview,
                MutationResultStatus.CancellationRequestedAfterSubmission =>
                    FileUploadBatchAttemptStatus.NeedsReview,
                MutationResultStatus.CancelledBeforeSubmission => FileUploadBatchAttemptStatus.Cancelled,
                _ => FileUploadBatchAttemptStatus.Failed,
            }, result.Status == MutationResultStatus.CancellationRequestedAfterSubmission);
        }
        catch (OperationCanceledException)
        {
            NotifyMediaUploadInterrupted(running, upload, isCancelled: true);
            return new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Cancelled);
        }
        catch
        {
            NotifyMediaUploadInterrupted(running, upload, isCancelled: false);
            // Activity 使用稳定的本地化状态；源路径和内部异常不会进入界面。
            return new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed);
        }
        finally
        {
            upload.Content.Dispose();
            lock (_sync)
            {
                _running.Remove(running);
            }
            running.Cancellation.Dispose();
        }
    }

    private async Task RunUploadBatchAsync(
        Guid batchId,
        string profileId,
        string folderPath,
        IReadOnlyList<string> sourcePaths,
        IReadOnlyList<UploadTargetKey> targets,
        CancellationTokenSource batchCancellation)
    {
        FileUploadBatchSummary summary;
        var shouldNotify = false;
        try
        {
            summary = await BoundedFileUploadBatch.RunAsync(
                sourcePaths,
                async (sourcePath, _) =>
                {
                    var prepared = PrepareUpload(
                        profileId,
                        folderPath,
                        sourcePath,
                        requiresMediaExtension: false,
                        requestedActivityId: null,
                        batchId,
                        batchCancellation.Token);
                    return await RunUploadAsync(prepared.Running, prepared.Request);
                },
                batchCancellation.Token);
        }
        finally
        {
            lock (_sync)
            {
                foreach (var target in targets)
                {
                    if (_batchReservations.TryGetValue(target, out var owner) && owner == batchId)
                    {
                        _batchReservations.Remove(target);
                    }
                }
                _batchCancellations.Remove(batchId);
                shouldNotify = !_disposed;
            }
            batchCancellation.Dispose();
        }

        if (!shouldNotify)
        {
            return;
        }

        UploadBatchFinished?.Invoke(new ForegroundUploadBatchFinished(
            profileId,
            folderPath,
            summary));
    }

    public void CancelFolderUpload(Guid batchId)
    {
        CancellationTokenSource? cancellation;
        lock (_sync)
        {
            _batchCancellations.TryGetValue(batchId, out cancellation);
        }
        try
        {
            cancellation?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    public void CancelDownloadBatch(Guid batchId)
    {
        CancellationTokenSource? cancellation;
        lock (_sync)
        {
            _downloadBatchCancellations.TryGetValue(batchId, out cancellation);
        }
        try
        {
            cancellation?.Cancel();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private RunningTransfer PrepareDownload(
        string profileId,
        string targetPath,
        Guid? batchId,
        CancellationToken batchCancellationToken = default)
    {
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(
            batchCancellationToken);
        var running = new RunningTransfer(
            Guid.NewGuid(),
            profileId,
            cancellation,
            LocalTargetPath: targetPath);
        lock (_sync)
        {
            if (_disposed)
            {
                cancellation.Dispose();
                throw new ObjectDisposedException(nameof(WindowsTransferPickerService));
            }
            if (_running.Any(item => string.Equals(
                    item.LocalTargetPath,
                    targetPath,
                    StringComparison.OrdinalIgnoreCase)) ||
                (_downloadBatchReservations.TryGetValue(targetPath, out var owner) &&
                    owner != batchId))
            {
                cancellation.Dispose();
                throw new InvalidOperationException("download.target_busy");
            }
            _running.Add(running);
        }
        return running;
    }

    private async Task RunDownloadBatchAsync(
        Guid batchId,
        string profileId,
        IReadOnlyList<FileDownloadBatchItem> items,
        IReadOnlyList<string> targetPaths,
        CancellationTokenSource batchCancellation)
    {
        await Task.Yield();
        var entries = items
            .Select(item => new FileBrowserEntry(new FileItem(
                item.RemotePath,
                item.Name,
                IsDirectory: false,
                Size: item.Length,
                ModifiedAt: null,
                Owner: null,
                CanWrite: false,
                CanDelete: false)))
            .ToArray();
        var index = 0;
        FileDownloadBatchSummary? summary = null;
        var shouldNotify = false;
        try
        {
            summary = await BoundedFileDownloadBatch.RunAsync(
                items,
                async (_, cancellationToken) =>
                {
                    var current = index++;
                    try
                    {
                        var running = PrepareDownload(
                            profileId,
                            targetPaths[current],
                            batchId,
                            cancellationToken);
                        return await RunDownloadAsync(
                            running,
                            entries[current],
                            targetPaths[current],
                            allowReplaceExisting: false);
                    }
                    catch (OperationCanceledException)
                    {
                        return new FileDownloadBatchAttempt(
                            FileDownloadBatchAttemptStatus.Cancelled,
                            StopBatch: true);
                    }
                    catch
                    {
                        return new FileDownloadBatchAttempt(
                            FileDownloadBatchAttemptStatus.Failed);
                    }
                },
                batchCancellation.Token);
        }
        finally
        {
            lock (_sync)
            {
                foreach (var target in targetPaths)
                {
                    if (_downloadBatchReservations.TryGetValue(target, out var owner) &&
                        owner == batchId)
                    {
                        _downloadBatchReservations.Remove(target);
                    }
                }
                _downloadBatchCancellations.Remove(batchId);
                shouldNotify = !_disposed;
            }
            batchCancellation.Dispose();
        }
        if (shouldNotify && summary is not null)
        {
            DownloadBatchFinished?.Invoke(new ForegroundDownloadBatchFinished(
                batchId,
                profileId,
                summary));
        }
    }

    private async Task RunFolderUploadBatchAsync(
        Guid batchId,
        Guid profileId,
        string profileKey,
        string folderPath,
        FolderUploadPlan plan,
        IFileMutationRepository mutationRepository,
        IReadOnlyList<UploadTargetKey> directoryTargets,
        IReadOnlyList<UploadTargetKey> fileTargets,
        CancellationTokenSource batchCancellation)
    {
        await Task.Yield();
        var token = batchCancellation.Token;
        var summary = await BoundedFolderUploadBatch.RunAsync(
            plan,
            async (directory, cancellationToken) =>
            {
                FileUploadBatchAttempt attempt;
                var parentPath = RemoteParentForDirectory(
                    folderPath,
                    plan.RootName,
                    directory.RelativePath);
                var proposedPath = $"{parentPath}/{directory.Name}";
                try
                {
                    if (FileMutationReviewBlocker.Current.Find(
                            profileId,
                            FileMutationOperation.CreateFolder,
                            parentPath) is not null)
                    {
                        attempt = new FileUploadBatchAttempt(
                            FileUploadBatchAttemptStatus.NeedsReview,
                            StopBatch: true);
                    }
                    else
                    {
                        var outcome = await mutationRepository.CreateFolderAsync(
                            new CreateFolderRequest(
                                profileId,
                                parentPath,
                                directory.Name),
                            cancellationToken);
                        attempt = ToFolderUploadAttempt(
                            outcome,
                            proposedPath,
                            directory.Name);
                    }
                }
                catch (OperationCanceledException)
                {
                    attempt = new FileUploadBatchAttempt(
                        FileUploadBatchAttemptStatus.NeedsReview,
                        StopBatch: true);
                }
                catch
                {
                    attempt = new FileUploadBatchAttempt(
                        FileUploadBatchAttemptStatus.NeedsReview,
                        StopBatch: true);
                }
                if (attempt.Status == FileUploadBatchAttemptStatus.NeedsReview)
                {
                    FileMutationReviewBlocker.Current.Block(new FileMutationReviewBlock(
                        profileId,
                        FileMutationOperation.CreateFolder,
                        parentPath,
                        proposedPath));
                }
                return attempt;
            },
            async (file, cancellationToken) =>
            {
                if (!BoundedFolderUploadPlan.IsCurrent(file))
                {
                    return new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed);
                }
                try
                {
                    var prepared = PrepareUpload(
                        profileKey,
                        RemoteFolderForFile(folderPath, plan.RootName, file.RelativePath),
                        file.SourcePath,
                        requiresMediaExtension: false,
                        requestedActivityId: null,
                        batchId,
                        cancellationToken);
                    return await RunUploadAsync(prepared.Running, prepared.Request);
                }
                catch (OperationCanceledException)
                {
                    return new FileUploadBatchAttempt(
                        FileUploadBatchAttemptStatus.Cancelled,
                        StopBatch: true);
                }
                catch
                {
                    return new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed);
                }
            },
            token);
        var shouldNotify = false;
        lock (_sync)
        {
            foreach (var target in directoryTargets)
            {
                if (_folderBatchTargets.TryGetValue(target, out var owner) && owner == batchId)
                {
                    _folderBatchTargets.Remove(target);
                }
            }
            foreach (var target in fileTargets)
            {
                if (_batchReservations.TryGetValue(target, out var owner) && owner == batchId)
                {
                    _batchReservations.Remove(target);
                }
            }
            _batchCancellations.Remove(batchId);
            shouldNotify = !_disposed;
        }
        batchCancellation.Dispose();

        if (shouldNotify)
        {
            FolderUploadBatchFinished?.Invoke(new FolderUploadBatchFinished(
                batchId,
                profileKey,
                folderPath,
                plan.Directories.Count,
                plan.Files.Count,
                summary));
        }
    }

    private static FileUploadBatchAttempt ToFolderUploadAttempt(
        FileMutationOutcome outcome,
        string proposedPath,
        string name) =>
        outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.ConfirmedItem is { IsDirectory: true } item &&
            string.Equals(item.Path, proposedPath, StringComparison.Ordinal) &&
            string.Equals(item.Name, name, StringComparison.Ordinal)
            ? new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Confirmed)
            : outcome.Result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess or
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess =>
                new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.NeedsReview, StopBatch: true),
            MutationResultStatus.CancelledBeforeSubmission =>
                new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Cancelled, StopBatch: true),
            _ => new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed, StopBatch: true),
        };

    private static string RemoteParentForDirectory(
        string folderPath,
        string rootName,
        string relativePath)
    {
        var separator = relativePath.LastIndexOf('/');
        return separator < 0
            ? relativePath.Length == 0 ? folderPath : $"{folderPath}/{rootName}"
            : $"{folderPath}/{rootName}/{relativePath[..separator]}";
    }

    private static string RemoteFolderForFile(
        string folderPath,
        string rootName,
        string relativePath)
    {
        var separator = relativePath.LastIndexOf('/');
        return separator < 0
            ? $"{folderPath}/{rootName}"
            : $"{folderPath}/{rootName}/{relativePath[..separator]}";
    }

    private void NotifyMediaUploadInterrupted(
        RunningTransfer running,
        FileUploadRequest upload,
        bool isCancelled)
    {
        if (running.IsMedia)
        {
            MediaUploadInterrupted?.Invoke(new PhotoMediaUploadInterrupted(
                running.ActivityId,
                running.ProfileId,
                upload.FolderPath,
                isCancelled));
        }
    }

    private sealed record RunningTransfer(
        Guid ActivityId,
        string ProfileId,
        CancellationTokenSource Cancellation,
        bool IsMedia = false,
        UploadTargetKey? UploadTarget = null,
        bool IsBatch = false,
        string? LocalTargetPath = null);

    private sealed record PreparedUpload(
        RunningTransfer Running,
        FileUploadRequest Request);

    private static UploadTargetKey CreateUploadTargetKey(
        string profileId,
        string folderPath,
        string fileName) =>
        new(profileId, folderPath, fileName.ToUpperInvariant());

    private sealed record UploadTargetKey(
        string ProfileId,
        string FolderPath,
        string FileName);
}
