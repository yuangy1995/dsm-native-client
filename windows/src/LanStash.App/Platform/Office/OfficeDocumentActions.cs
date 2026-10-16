using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Windows.Storage;
using Windows.System;

namespace LanStash.App.Platform.Office;

internal interface IOfficeDocumentLauncher
{
    Task<bool> OpenAsync(string path, bool chooseApplication);
    Task<bool> RevealAsync(string path);
}

internal sealed class OfficeDocumentLauncher : IOfficeDocumentLauncher
{
    public async Task<bool> OpenAsync(string path, bool chooseApplication) =>
        await Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(path),
            new LauncherOptions { DisplayApplicationPicker = chooseApplication });
    public async Task<bool> RevealAsync(string path)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        var options = new FolderLauncherOptions(); options.ItemsToSelect.Add(file);
        return await Launcher.LaunchFolderAsync(await file.GetParentAsync(), options);
    }
}

internal sealed class OfficeDocumentActions
{
    internal IWindowsTransferSavePicker Picker { get; init; } = new WindowsTransferSavePicker(() => (Microsoft.UI.Xaml.Application.Current as App)?.MainWindow);
    internal IOfficeDocumentLauncher Launcher { get; init; } = new OfficeDocumentLauncher();

    public async Task SaveReadOnlyCopyAsync(IFileRangeReader repository, FileItem item, string path, CancellationToken token)
    {
        using var lease = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(path)!);
        var destination = await WindowsTransactionalDownloadDestination.CreateAsync(path, validateTarget: lease.Validate);
        await new SafeFileDownloadService().DownloadAsync(repository, item.Path, item.Size, destination, cancellationToken: token);
    }
}
