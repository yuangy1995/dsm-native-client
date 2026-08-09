using LanStash.App.Localization;
using LanStash.App.Features.Files;
using LanStash.Domain;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Features.Transfers;

internal interface IWindowsTransferSavePicker
{
    Task<string?> PickSavePathAsync(string suggestedName);
}

internal interface IWindowsTransferOpenPicker
{
    Task<string?> PickSingleFilePathAsync();
}

internal sealed class WindowsTransferSavePicker(Func<Window?> windowProvider)
    : IWindowsTransferSavePicker
{
    public async Task<string?> PickSavePathAsync(string suggestedName)
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
                LocalizationService.Current.Get("TransferOriginalFileType"),
                [extension]);
        }
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }
}

internal sealed class WindowsTransferOpenPicker(Func<Window?> windowProvider)
    : IWindowsTransferOpenPicker
{
    public async Task<string?> PickSingleFilePathAsync()
    {
        var window = windowProvider();
        if (window is null)
        {
            return null;
        }

        var windowId = Win32Interop.GetWindowIdFromWindow(
            WindowNative.GetWindowHandle(window));
        var picker = new FileOpenPicker(windowId);
        var result = await picker.PickSingleFileAsync();
        return result?.Path;
    }
}

internal sealed class WindowsTransferPickerService : IDisposable
{
    private readonly object _sync = new();
    private readonly IDsmRepository _repository;
    private readonly SafeFileDownloadService _downloadService;
    private readonly ForegroundTransferCoordinator _coordinator;
    private readonly IWindowsTransferSavePicker _savePicker;
    private readonly IWindowsTransferOpenPicker _openPicker;
    private readonly List<RunningTransfer> _running = [];
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
    }

    public event Action<ForegroundUploadFinished>? UploadFinished;

    public async Task<bool> PickAndStartDownloadAsync(
        string profileId,
        FileBrowserEntry entry)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.IsDirectory)
        {
            return false;
        }

        string? targetPath;
        try
        {
            targetPath = await _savePicker.PickSavePathAsync(entry.Name);
        }
        catch
        {
            throw;
        }
        if (targetPath is null)
        {
            return false;
        }

        var cancellation = new CancellationTokenSource();
        var running = new RunningTransfer(Guid.NewGuid(), profileId, cancellation);
        lock (_sync)
        {
            if (_disposed)
            {
                cancellation.Dispose();
                throw new ObjectDisposedException(nameof(WindowsTransferPickerService));
            }
            _running.Add(running);
        }

        _ = RunDownloadAsync(running, entry, targetPath);
        return true;
    }

    public async Task<bool> PickAndStartUploadAsync(
        string profileId,
        string folderPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);

        var sourcePath = await _openPicker.PickSingleFilePathAsync();
        if (sourcePath is null)
        {
            return false;
        }

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

        var cancellation = new CancellationTokenSource();
        var running = new RunningTransfer(Guid.NewGuid(), profileId, cancellation);
        lock (_sync)
        {
            if (_disposed)
            {
                source.Dispose();
                cancellation.Dispose();
                throw new ObjectDisposedException(nameof(WindowsTransferPickerService));
            }
            _running.Add(running);
        }

        _ = RunUploadAsync(running, request);
        return true;
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
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            running = _running.ToArray();
            _running.Clear();
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
    }

    private async Task RunDownloadAsync(
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
                    entry.Name,
                    entry.Item.Size,
                    running.ActivityId),
                async (progress, cancellationToken) =>
                {
                    var destination =
                        await WindowsTransactionalDownloadDestination.CreateAsync(targetPath);
                    await _downloadService.DownloadAsync(
                        _repository,
                        entry.Path,
                        entry.Item.Size,
                        destination,
                        progress,
                        cancellationToken);
                },
                running.Cancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // 前台活动页展示稳定、可操作的本地化错误，不在此泄露内部异常。
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

    private async Task RunUploadAsync(
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
            UploadFinished?.Invoke(new ForegroundUploadFinished(
                running.ProfileId,
                upload.FolderPath,
                result));
        }
        catch (OperationCanceledException)
        {
        }
        catch
        {
            // Activity 使用稳定的本地化状态；源路径和内部异常不会进入界面。
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

    private sealed record RunningTransfer(
        Guid ActivityId,
        string ProfileId,
        CancellationTokenSource Cancellation);
}
