using LanStash.App.Localization;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Downloads;
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

internal sealed partial class WindowsTransferPickerService : IPhotoImportTransferService, IDisposable, IAsyncDisposable
{
    internal static readonly string[] MediaFileTypeFilters =
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
    private readonly HashSet<Guid> _uploadActivityIds = [];
    private readonly Dictionary<UploadTargetKey, Guid> _batchReservations = [];
    private readonly Dictionary<Guid, CancellationTokenSource> _batchCancellations = [];
    private readonly Dictionary<UploadTargetKey, Guid> _folderBatchTargets = [];
    private readonly Dictionary<string, Guid> _downloadBatchReservations =
        new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, CancellationTokenSource> _downloadBatchCancellations = [];
    private readonly Dictionary<Guid, TaskCompletionSource> _batchCompletions = [];
    private Task _drainTask = Task.CompletedTask;
    private bool _disposed;
    internal bool HasRunningTransfers { get { lock (_sync) return _running.Count != 0 || _batchCompletions.Count != 0; } }

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
    public Task<string?> PickThemeImagePathAsync() => _disposed ? Task.FromResult<string?>(null) : _openPicker.PickSingleFilePathAsync([".jpg", ".jpeg", ".jpe", ".png", ".gif", ".bmp"]);
    public event Action<ForegroundUploadBatchFinished>? UploadBatchFinished;
    public event Action<FolderUploadBatchFinished>? FolderUploadBatchFinished;
    public event Action<ForegroundDownloadBatchFinished>? DownloadBatchFinished;
    public event Action<ForegroundSelectionDownloadFinished>? SelectionDownloadFinished;
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

    public async Task<Guid?> PickAndStartSelectedDownloadAsync(string profileId, IReadOnlyList<FileItem> items, Func<bool> sourceIsCurrent,
        bool preserveFolders = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentNullException.ThrowIfNull(items); ArgumentNullException.ThrowIfNull(sourceIsCurrent);
        var snapshot = items.ToArray();
        if (!FileDownloadSelection.IsValid(snapshot)) throw new ArgumentException("Invalid download selection.", nameof(items));
        if (!sourceIsCurrent()) return null;
        if (preserveFolders)
        {
            var folder = await _openPicker.PickSingleFolderPathAsync();
            if (folder is null || !sourceIsCurrent()) return null;
            var folderTransfer = PrepareDownload(profileId, folder, batchId: null);
            _ = RunStructuredDownloadAsync(folderTransfer, snapshot, folder);
            return folderTransfer.ActivityId;
        }
        var archive = FileDownloadSelection.UsesArchive(snapshot);
        var name = snapshot.Length == 1 ? snapshot[0].Name + (archive ? ".zip" : "") : LocalizationService.Current.Get("FileSelectionDownloadZipName");
        var targetPath = archive ? await _savePicker.PickArchiveSavePathAsync(name) : await _savePicker.PickSavePathAsync(name);
        if (targetPath is null || !sourceIsCurrent()) return null;
        var running = PrepareDownload(profileId, targetPath, batchId: null);
        _ = RunSelectedDownloadAsync(running, snapshot, targetPath, archive);
        return running.ActivityId;
    }

    private async Task RunSelectedDownloadAsync(RunningTransfer running, IReadOnlyList<FileItem> items, string targetPath, bool archive)
    {
        var result = archive
            ? await RunArchiveDownloadAsync(running, items, targetPath)
            : await RunDownloadAsync(running, new FileBrowserEntry(items[0]), targetPath, allowReplaceExisting: true);
        SelectionDownloadFinished?.Invoke(new(running.ProfileId, running.ActivityId, items.Count, result.Status));
    }

    public async Task<bool> PickAndStartVfsDownloadAsync(IFileVfsBrowserRepository repository,
        FileVfsDownloadSource source, Func<bool> sourceIsCurrent, CancellationToken cancellationToken)
    {
        if (!ReferenceEquals(repository, _repository) || source.Profile.ProfileId != repository.ProfileId || !source.IsValid)
            throw new ArgumentException("file.vfs.download-changed");
        if (!sourceIsCurrent()) return false;
        await repository.ValidateVfsDownloadAsync(source, cancellationToken);
        var targetPath = await _savePicker.PickSavePathAsync(source.File.Name);
        if (targetPath is null || !sourceIsCurrent() || cancellationToken.IsCancellationRequested) return false;
        var running = PrepareDownload(repository.ProfileId.ToString(), targetPath, batchId: null);
        _ = RunDownloadAsync(running, new FileBrowserEntry(source.File), targetPath, allowReplaceExisting: true,
            new FileVfsRangeReader(repository, source), token => repository.ValidateVfsDownloadAsync(source, token));
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
            _batchCompletions.Add(batchId, new(TaskCreationOptions.RunContinuationsAsynchronously));
        }

        _ = RunTrackedBatchAsync(batchId, () => RunDownloadBatchAsync(
            batchId,
            profileId,
            items,
            targetPaths,
            batchCancellation));
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
        string folderPath,
        bool overwrite = false,
        Func<bool>? targetIsCurrent = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        if (targetIsCurrent?.Invoke() == false) return new(FileUploadBatchValidationStatus.Empty, 0);
        var sourcePaths = await _openPicker.PickMultipleFilePathsAsync();
        if (sourcePaths is null || targetIsCurrent?.Invoke() == false) return new(FileUploadBatchValidationStatus.Empty, 0);
        var snapshot = sourcePaths.ToArray();
        return new ForegroundUploadBatchStart(StartUploadBatch(profileId, folderPath, snapshot, overwrite), snapshot.Length);
    }

    public FileUploadBatchValidationStatus StartUploadBatch(
        string profileId,
        string folderPath,
        IReadOnlyList<string> sourcePaths,
        bool overwrite = false)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        ArgumentNullException.ThrowIfNull(sourcePaths);

        var paths = sourcePaths.ToArray();
        var validation = BoundedFileUploadBatch.ValidatePaths(paths);
        if (validation != FileUploadBatchValidationStatus.Valid)
        {
            return validation;
        }

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
            _batchCompletions.Add(batchId, new(TaskCreationOptions.RunContinuationsAsynchronously));
        }

        _ = RunTrackedBatchAsync(batchId, () => RunUploadBatchAsync(
            batchId,
            profileId,
            folderPath,
            paths,
            targets,
            batchCancellation,
            overwrite));
        return FileUploadBatchValidationStatus.Valid;
    }

    public async Task<FolderUploadPlanResult?> PickFolderUploadPlanAsync(CancellationToken cancellationToken = default)
    {
        var sourcePath = await _openPicker.PickSingleFolderPathAsync();
        return sourcePath is null
            ? null
            : await PlanFolderUploadAsync(sourcePath, cancellationToken);
    }

    public Task<FolderUploadPlanResult> PlanFolderUploadAsync(string sourcePath, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        return Task.Run(() => BoundedFolderUploadPlan.Create(sourcePath, cancellationToken), cancellationToken);
    }

    public async Task<FolderUploadBatchStart> StartFolderUploadAsync(
        string profileId,
        string folderPath,
        FolderUploadPlan plan,
        CancellationToken cancellationToken = default,
        Func<bool>? targetIsCurrent = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        ArgumentNullException.ThrowIfNull(plan);
        cancellationToken.ThrowIfCancellationRequested();
        plan = plan with { Directories = plan.Directories.ToArray(), Files = plan.Files.ToArray() };
        if (!Guid.TryParse(profileId, out var parsedProfileId) ||
            _repository is not IFileMutationRepository mutationRepository ||
            mutationRepository.ProfileId != parsedProfileId ||
            !mutationRepository.FileMutationAvailability.CanCreateFolder)
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.Unsupported);
        }
        if (!await Task.Run(() => BoundedFolderUploadPlan.IsCurrent(plan, cancellationToken), cancellationToken))
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.SourceChanged);
        }
        cancellationToken.ThrowIfCancellationRequested();
        if (targetIsCurrent?.Invoke() == false || !mutationRepository.FileMutationAvailability.CanCreateFolder)
        {
            return new FolderUploadBatchStart(FolderUploadBatchStartStatus.Unsupported);
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
            cancellationToken.ThrowIfCancellationRequested();
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
            _batchCompletions.Add(batchId, new(TaskCreationOptions.RunContinuationsAsynchronously));
        }

        _ = RunTrackedBatchAsync(batchId, () => RunFolderUploadBatchAsync(
            batchId,
            parsedProfileId,
            profileId,
            folderPath,
            plan,
            mutationRepository,
            directoryTargets,
            fileTargets,
            batchCancellation));
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
        CancellationToken batchCancellationToken = default,
        bool overwrite = false,
        ForegroundTransferControl? control = null)
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

        control ??= new ForegroundTransferControl();
        FileUploadRequest request;
        try
        {
            request = new FileUploadRequest(
                new ForegroundTransferReadStream(source, control),
                length,
                folderPath,
                fileName,
                overwrite,
                requestedActivityId);
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
                request.OperationId,
                profileId,
                cancellation,
                IsMedia: requiresMediaExtension,
                UploadTarget: uploadTarget,
                IsBatch: batchId is not null) { Control = control };
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
            if (_batchCancellations.TryGetValue(activityId, out var batch) &&
                _coordinator.GetActivities(profileId).Any(item => item.Id == activityId)) matches = [.. matches, batch];
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

    public bool CanRefreshUpload(ForegroundTransferActivity activity)
    {
        lock (_sync) return !_disposed && (_uploadActivityIds.Contains(activity.Id) || activity.ItemResults.Any(item =>
                item.State == ForegroundTransferItemState.ResultNeedsReview && item.ActivityId is { } id && _uploadActivityIds.Contains(id))) &&
            activity.Source == ForegroundTransferSource.App && activity.Direction == ForegroundTransferDirection.Upload &&
            activity.State == ForegroundTransferState.ResultNeedsReview &&
            _coordinator.GetActivities(activity.ProfileId).Any(item => item.Id == activity.Id &&
                item.RemotePath == activity.RemotePath && item.DisplayName == activity.DisplayName && item.State == activity.State);
    }

    public async Task RefreshUploadAsync(ForegroundTransferActivity activity)
    {
        if (!CanRefreshUpload(activity)) return;
        if (activity.ItemResults.Count > 0)
        {
            var children = _coordinator.GetActivities(activity.ProfileId).Where(child =>
                activity.ItemResults.Any(item => item.ActivityId == child.Id) && CanRefreshUpload(child)).ToArray();
            foreach (var child in children) await RefreshUploadAsync(child);
            return;
        }
        try
        {
            var result = await _repository.ReviewFileUploadAsync(activity.RemotePath, activity.DisplayName, operationId: activity.Id);
            if (result is null) return;
            _coordinator.ApplyUploadReview(activity.ProfileId, activity.Id, result);
            if (result.Status == MutationResultStatus.ConfirmedSuccess)
                UploadFinished?.Invoke(new(activity.ProfileId, activity.RemotePath, result));
        }
        catch { /* 读取失败保留原未知事实，不转成可以重新上传的失败。 */ }
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
            _drainTask = Task.WhenAll(running.Select(item => item.Completion.Task)
                .Concat(_batchCompletions.Values.Select(item => item.Task)));
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

    public async ValueTask DisposeAsync()
    {
        Dispose();
        await _drainTask;
    }

    private async Task RunTrackedBatchAsync(Guid batchId, Func<Task> operation)
    {
        try { await operation(); }
        finally
        {
            lock (_sync)
            {
                if (_batchCompletions.Remove(batchId, out var completion)) completion.TrySetResult();
            }
        }
    }

    private async Task<FileDownloadBatchAttempt> RunDownloadAsync(
        RunningTransfer running,
        FileBrowserEntry entry,
        string targetPath,
        bool allowReplaceExisting,
        IFileRangeReader? reader = null,
        Func<CancellationToken, Task>? validateSource = null)
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
                    // 零字节文件不触发 range 读取，也必须先校验来源再创建本机目标。
                    if (validateSource is not null) await validateSource(cancellationToken);
                    var destination =
                        await WindowsTransactionalDownloadDestination.CreateAsync(
                            targetPath,
                            allowReplaceExisting);
                    await _downloadService.DownloadAsync(
                        reader ?? _repository,
                        entry.Path,
                        entry.Item.Size,
                        destination,
                        progress,
                        cancellationToken,
                        running.Control);
                },
                running.Cancellation.Token,
                running.Control);
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
            running.Completion.TrySetResult();
        }
    }

    private async Task RunFolderArchiveDownloadAsync(
        RunningTransfer running,
        FileBrowserEntry entry,
        string targetPath) => await RunArchiveDownloadAsync(running, new[] { entry.Item }, targetPath);

    private async Task<FileDownloadBatchAttempt> RunArchiveDownloadAsync(RunningTransfer running, IReadOnlyList<FileItem> items, string targetPath)
    {
        try
        {
            await _coordinator.RunAsync(
                new ForegroundDownloadRequest(
                    running.ProfileId,
                    FileDownloadSelection.SourceLocation(items),
                    Path.GetFileName(targetPath),
                    0,
                    running.ActivityId),
                async (progress, cancellationToken) =>
                {
                    var destination =
                        await WindowsTransactionalDownloadDestination.CreateAsync(
                            targetPath,
                            validateZipArchive: true);
                    await _archiveDownloadService.DownloadAsync(
                        _repository,
                        items.Select(item => item.Path).ToArray(),
                        destination,
                        cancellationToken,
                        progress,
                        running.Control);
                },
                running.Cancellation.Token,
                running.Control);
            return new(FileDownloadBatchAttemptStatus.Completed);
        }
        catch (OperationCanceledException)
        {
            return new(FileDownloadBatchAttemptStatus.Cancelled);
        }
        catch
        {
            // Activity 展示稳定失败状态；页面继续可重试选择其他目标。
            return new(FileDownloadBatchAttemptStatus.Failed);
        }
        finally
        {
            lock (_sync)
            {
                _running.Remove(running);
            }
            running.Cancellation.Dispose();
            running.Completion.TrySetResult();
        }
    }

    private async Task<FileUploadBatchAttempt> RunUploadAsync(
        RunningTransfer running,
        FileUploadRequest upload,
        Action<long>? aggregateProgress = null)
    {
        lock (_sync) _uploadActivityIds.Add(running.ActivityId);
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
                    aggregateProgress is null ? progress : new UploadProgress(value => { progress.Report(value); aggregateProgress(value); }),
                    cancellationToken),
                running.Cancellation.Token,
                running.Control);
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
            running.Completion.TrySetResult();
        }
    }

    private async Task RunUploadBatchAsync(
        Guid batchId,
        string profileId,
        string folderPath,
        IReadOnlyList<string> sourcePaths,
        IReadOnlyList<UploadTargetKey> targets,
        CancellationTokenSource batchCancellation,
        bool overwrite = false)
    {
        FileUploadBatchSummary summary;
        var shouldNotify = false;
        try
        {
            var items = sourcePaths.Select(path => new ForegroundTransferItemResult(Path.GetFileName(path), false, ForegroundTransferItemState.Waiting)).ToArray();
            var lengths = sourcePaths.Select(path => { try { return new FileInfo(path).Length; } catch { return 0L; } }).ToArray();
            summary = await RunUploadBatchActivityAsync(batchId, profileId, folderPath,
                LocalizationService.Current.Format("TransferUploadBatchTitle", items.Length), lengths.Sum(), items,
                async (control, track, report, token) => await BoundedFileUploadBatch.RunAsync(sourcePaths,
                    async (sourcePath, _) =>
                    {
                        var index = Array.IndexOf(sourcePaths.ToArray(), sourcePath);
                        return await track(index, async () =>
                        {
                            var prepared = PrepareUpload(profileId, folderPath, sourcePath, false, null,
                                batchId, token, overwrite, control);
                            items[index] = items[index] with { ActivityId = prepared.Running.ActivityId };
                            return await RunUploadAsync(prepared.Running, prepared.Request, value => report(index, value));
                        });
                    }, token), batchCancellation.Token);
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
        FileUploadBatchSummary summary;
        var shouldNotify = false;
        try
        {
            await Task.Yield();
            var items = plan.Directories.Select(directory => new ForegroundTransferItemResult(
                directory.RelativePath.Length == 0 ? plan.RootName : plan.RootName + "/" + directory.RelativePath, true, ForegroundTransferItemState.Waiting))
                .Concat(plan.Files.Select(file => new ForegroundTransferItemResult(plan.RootName + "/" + file.RelativePath, false, ForegroundTransferItemState.Waiting))).ToArray();
            summary = await RunUploadBatchActivityAsync(batchId, profileKey, folderPath, plan.RootName,
                plan.Files.Sum(file => file.Length), items, async (control, track, report, token) => await BoundedFolderUploadBatch.RunAsync(
                plan,
                async (directory, cancellationToken) => await track(Array.IndexOf(plan.Directories.ToArray(), directory), async () =>
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
                }),
                async (file, cancellationToken) => await track(plan.Directories.Count + Array.IndexOf(plan.Files.ToArray(), file), async () =>
                {
                    if (!BoundedFolderUploadPlan.IsCurrent(file, plan.RootPath))
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
                            cancellationToken, control: control);
                        var index = plan.Directories.Count + Array.IndexOf(plan.Files.ToArray(), file);
                        items[index] = items[index] with { ActivityId = prepared.Running.ActivityId };
                        return await RunUploadAsync(prepared.Running, prepared.Request, value => report(index, value));
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
                }),
                token), batchCancellation.Token);
        }
        finally
        {
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
        }

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
        string? LocalTargetPath = null)
    {
        public ForegroundTransferControl Control { get; init; } = new();
        public TaskCompletionSource Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

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
