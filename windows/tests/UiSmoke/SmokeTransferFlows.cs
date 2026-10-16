using LanStash.App.Features.Files;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeTransferRepository(string state) : IDsmRepository
{
    public FileItem Folder = Item("/sample/folder", true);
    public FileItem Large = Item("/sample/large.bin") with { Size = SafeFileDownloadService.ChunkSize + 3L };
    public int RangeCalls;
    public TaskCompletionSource Reading { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public IReadOnlyList<AppModule> AvailableModules => [];
    private FileItem[] Children => state == "folder-empty" ? [] :
        [Item("/sample/folder/empty", true), Item("/sample/folder/first.txt"), Item(state == "bad-name" ? "/sample/folder/bad:name" : "/sample/folder/second.txt")];
    public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default)
    {
        var item = path == Folder.Path ? Folder : path == Large.Path ? Large : Children.Single(c => c.Path == path);
        return Task.FromResult<FileEntryMetadata?>(new(item, null, null));
    }
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken = default)
    {
        if (state == "read-error") throw new IOException("合成目录读取失败");
        var children = path == Folder.Path ? Children : [];
        return Task.FromResult(new FilePage(children.Skip(offset).Take(limit).ToArray(), children.Length, offset));
    }
    public async Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length,
        string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default)
    {
        RangeCalls++;
        if (remotePath == Large.Path && offset == 0) { Reading.TrySetResult(); await Release.Task.WaitAsync(cancellationToken); }
        if (state == "partial" && remotePath.EndsWith("second.txt", StringComparison.Ordinal)) throw new IOException("合成第二项下载失败");
        return new(206, offset, length, offset, length, expectedTotalLength ?? length, length, new byte[checked((int)length)], "\"synthetic-version\"", true);
    }
    public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    private static FileItem Item(string path, bool directory = false) => new(path, path[(path.LastIndexOf('/') + 1)..], directory, directory ? 0 : 3, null, null, false, false);
}

internal sealed class SmokeTransferPicker(string folder) : IWindowsTransferSavePicker, IWindowsTransferOpenPicker
{
    public Task<string?> PickSavePathAsync(string suggestedName) => Task.FromResult<string?>(Path.Combine(folder, suggestedName));
    public Task<string?> PickSingleFolderPathAsync() => Task.FromResult<string?>(folder);
    public Task<string?> PickSingleFilePathAsync(IReadOnlyList<string>? fileTypeFilters = null) => Task.FromResult<string?>(null);
    public Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(IReadOnlyList<string>? fileTypeFilters = null) => Task.FromResult<IReadOnlyList<string>?>(null);
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveTransferFlowsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "structure";
        var repository = new SmokeTransferRepository(state);
        var directory = Path.Combine(Path.GetTempPath(), "LanStash-transfer-smoke-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        using var coordinator = new ForegroundTransferCoordinator(); var profile = SmokeActivityProbe.Profile.ToString(); coordinator.ActivateProfile(profile);
        var filePicker = new SmokeTransferPicker(directory);
        using var transfers = new WindowsTransferPickerService(repository, coordinator, filePicker, filePicker);
        var downloads = System.Reflection.DispatchProxy.Create<IDownloadStationRepository, SmokeActivityProbe>(); ((SmokeActivityProbe)downloads).Hold = false;
        await using var page = new TransferActivityPage(coordinator, transfers, profile, downloads, new SmokeFileTaskRepository("missing"));
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        ContentDialog? dialog = null;
        try
        {
            if (state == "structure")
            {
                await WriteProbeAsync(Path.Combine(directory, "unlocked.bin"), "unlocked");
                File.Delete(Path.Combine(directory, "unlocked.bin"));
                using var lease = ForegroundDownloadDirectoryLease.Acquire(directory);
                var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(directory);
                var child = await folder.CreateFolderAsync("lease-check", Windows.Storage.CreationCollisionOption.FailIfExists);
                using (var childLease = ForegroundDownloadDirectoryLease.Acquire(child.Path))
                {
                    await WriteProbeAsync(Path.Combine(child.Path, "test.bin"), "identity-guarded", childLease.Validate);
                }
                await child.DeleteAsync(Windows.Storage.StorageDeleteOption.PermanentDelete);
            }
            if (state is "choice" or "choice-zip")
            {
                using var browser = new FileBrowserViewModel(new SmokeTextSource());
                using var files = new FilesPage(browser, new SmokeTextEditor("edit"), profile, transfers);
                ((Frame)shell.FindName("ContentFrame")).Content = files; await Task.Delay(120);
                var choice = (Task<bool?>)typeof(FilesPage).GetMethod("ChooseFolderDownloadModeAsync", flags)!.Invoke(files, [])!;
                await Task.Delay(200);
                dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(files.XamlRoot).SelectMany(p => Nodes(p.Child)).OfType<ContentDialog>().Distinct().Single();
                Nodes(dialog).OfType<ComboBox>().Single().SelectedIndex = state == "choice-zip" ? 1 : 0;
                await WriteSnapshotAsync(dialog, markComplete: false);
                Invoke(Nodes(dialog).OfType<Button>().Single(b => b.Name == "PrimaryButton"));
                if (await choice != (state != "choice-zip")) throw new InvalidOperationException("下载方式未保存用户选择。");
                dialog = null; MarkSnapshotComplete(); return;
            }
            if (state == "collision")
            {
                Directory.CreateDirectory(Path.Combine(directory, "folder"));
                await File.WriteAllTextAsync(Path.Combine(directory, "folder", "kept.txt"), "synthetic original");
            }
            if (state != "empty")
            {
                var single = state is "pause" or "resume" or "cancel";
                var finished = new TaskCompletionSource<ForegroundSelectionDownloadFinished>(TaskCreationOptions.RunContinuationsAsynchronously);
                transfers.SelectionDownloadFinished += result => finished.TrySetResult(result);
                var id = await transfers.PickAndStartSelectedDownloadAsync(profile, single ? [repository.Large] : [repository.Folder], () => true, !single);
                if (id is null) throw new InvalidOperationException("合成下载未创建任务。");
                if (single)
                {
                    await repository.Reading.Task.WaitAsync(TimeSpan.FromSeconds(3));
                    Render(); await Task.Delay(100); page.UpdateLayout();
                    var pause = FindButton("TransferActivityPause"); Invoke(pause);
                    repository.Release.SetResult(); await Task.Delay(120);
                    if (coordinator.GetActivities(profile).Single().State != ForegroundTransferState.Paused || repository.RangeCalls != 1 || File.Exists(Path.Combine(directory, "large.bin")))
                        throw new InvalidOperationException("暂停未保留下载事务。");
                    for (var attempt = 0; attempt < 40 && coordinator.GetActivities(profile).Single().BytesTransferred == 0; attempt++) await Task.Delay(50);
                    Render(); await Task.Delay(70);
                    if (coordinator.GetActivities(profile).Single().BytesTransferred != SafeFileDownloadService.ChunkSize)
                        throw new InvalidOperationException("暂停期间未保留已读取的进度。");
                    if (state == "pause") { await WriteSnapshotAsync(root, markComplete: false); Invoke(FindButton("TransferActivityResume")); }
                    else if (state == "cancel")
                        Invoke(Nodes(page).OfType<Button>().Single(b => b.Tag is ForegroundTransferActivity && Equals(b.Content, LocalizationService.Current.Get("TransferActivityCancel.Content"))));
                    else Invoke(FindButton("TransferActivityResume"));
                }
                var result = await finished.Task.WaitAsync(TimeSpan.FromSeconds(8));
                var activity = coordinator.GetActivities(profile).Single(a => a.Id == id);
                if (state is "structure" or "folder-empty" && (result.Status != FileDownloadBatchAttemptStatus.Completed ||
                    !Directory.Exists(Path.Combine(directory, "folder")))) throw new InvalidOperationException("保留结构下载未完成：" + activity.FailureMessage + "; " + string.Join(",", activity.ItemResults.Select(i => i.State)));
                if (state == "structure" && (activity.ItemResults.Count != 4 || new FileInfo(Path.Combine(directory, "folder", "first.txt")).Length != 3 || !Directory.Exists(Path.Combine(directory, "folder", "empty"))))
                    throw new InvalidOperationException("目录、空目录或文件内容丢失。");
                if (state == "partial" && (activity.ItemResults.Count(i => i.State == ForegroundTransferItemState.Completed) != 3 ||
                    activity.ItemResults.Count(i => i.State == ForegroundTransferItemState.Failed) != 1 || File.Exists(Path.Combine(directory, "folder", "second.txt"))))
                    throw new InvalidOperationException("失败覆盖了已成功项目或发布了部分文件。");
                if (state == "collision" && (repository.RangeCalls != 0 || await File.ReadAllTextAsync(Path.Combine(directory, "folder", "kept.txt")) != "synthetic original"))
                    throw new InvalidOperationException("同名目标被覆盖。");
                if (state is "bad-name" or "read-error" && Directory.EnumerateFileSystemEntries(directory).Any()) throw new InvalidOperationException("未完整规划就创建了输出。");
                if (state is "pause" or "resume" && (repository.RangeCalls != 2 || new FileInfo(Path.Combine(directory, "large.bin")).Length != repository.Large.Size))
                    throw new InvalidOperationException("继续下载没有保留原偏移。");
                if (state == "cancel" && (result.Status != FileDownloadBatchAttemptStatus.Cancelled || Directory.EnumerateFileSystemEntries(directory).Any()))
                    throw new InvalidOperationException("取消没有清理未完成副本。");
                Render(); await Task.Delay(100); page.UpdateLayout();
                if (state is "structure" or "partial" or "folder-empty" or "collision" or "bad-name" or "read-error")
                {
                    Invoke(Nodes(page).OfType<Button>().Single(b => b.Tag is ForegroundTransferActivity && Equals(b.Content, LocalizationService.Current.Get("FileTaskDetails.Content"))));
                    await Task.Delay(200); dialog = (ContentDialog)typeof(TransferActivityPage).GetField("_detailsDialog", flags)!.GetValue(page)!;
                }
            }
            if (state != "pause") await WriteSnapshotAsync(dialog ?? root, markComplete: false);
            dialog?.Hide(); dialog = null; MarkSnapshotComplete();
        }
        finally
        {
            dialog?.Hide(); repository.Release.TrySetResult(); transfers.Dispose(); await page.SetWindowVisibleAsync(false);
            // 只清理本场景创建、位于系统临时目录内的独立合成输出。
            if (!Path.GetFullPath(directory).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成清理边界错误。");
            Directory.Delete(directory, recursive: true);
        }
        void Render() => typeof(TransferActivityPage).GetMethod("RenderActivities", flags)!.Invoke(page, []);
        static async Task WriteProbeAsync(string target, string phase, Action? validate = null)
        {
            try
            {
                await using var destination = await WindowsTransactionalDownloadDestination.CreateAsync(target, allowReplaceExisting: false, validateTarget: validate);
                await destination.WriteAsync(new byte[] { 1, 2, 3 }); await destination.CommitAsync();
            }
            catch (Exception error) { throw new InvalidOperationException("合成事务保存失败：" + phase, error); }
        }
        Button FindButton(string key) => Nodes(page).OfType<Button>().Single(b => b.Visibility == Visibility.Visible && Equals(b.Content, LocalizationService.Current.Get(key)));
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        static IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
    }
}
