using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    public bool SupportsOriginalSizeJpeg => State.StartsWith("export-", StringComparison.Ordinal);
    internal readonly List<(SynologyPhoto Photo, SynologyPhotoDownloadFormat Format)> ExportedPhotos = [];
    internal SynologyPhotoArchiveTarget? ExportedArchive;
    internal TaskCompletionSource? ExportGate;
    public async Task<SynologyPhotoDownloadResult> DownloadAsync(SynologyPhoto photo, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        ExportedPhotos.Add((photo, format));
        if (ExportGate is { } gate) await gate.Task;
        cancellationToken.ThrowIfCancellationRequested();
        if (State == "export-error" || State == "export-partial" && photo.Id.ItemId == 2) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var actual = State == "export-preserved" && photo.Id.ItemId == 2 ? SynologyPhotoDownloadFormat.Original : format;
        byte[] bytes;
        if (actual == SynologyPhotoDownloadFormat.Original) bytes = new byte[photo.SizeBytes];
        else
        {
            using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, 2, 2, 96, 96, Enumerable.Repeat((byte)120, 16).ToArray());
            await encoder.FlushAsync(); stream.Seek(0); using var reader = new DataReader(stream); await reader.LoadAsync((uint)stream.Size); bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes);
        }
        await File.WriteAllBytesAsync(destination, bytes, cancellationToken); progress?.Report(bytes.LongLength); return new(actual, bytes.LongLength);
    }
    public async Task<long> DownloadArchiveAsync(SynologyPhotoArchiveTarget target, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        ExportedArchive = target;
        if (ExportGate is { } gate) await gate.Task;
        cancellationToken.ThrowIfCancellationRequested();
        var bytes = new byte[22]; bytes[0] = 0x50; bytes[1] = 0x4b; bytes[2] = 5; bytes[3] = 6;
        await File.WriteAllBytesAsync(destination, bytes, cancellationToken); return bytes.LongLength;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoExportAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "";
        var directory = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "LanStash-SyntheticExport-" + Guid.NewGuid().ToString("N")));
        var repository = new SmokePhotosRepository(); var picker = new PhotoExportPicker(directory.FullName) { Cancel = state == "export-picker-cancel" };
        using var page = new SynologyPhotosPage(repository, picker, picker); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var workspace = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        bool Busy() => (bool)typeof(SynologyPhotosPage).GetField("_isSaving", flags)!.GetValue(page)! ||
            (bool)typeof(SynologyPhotosPage).GetField("_exportStarting", flags)!.GetValue(page)!;
        var library = (GridView)page.FindName("LibraryGrid");
        async Task WaitFor(Func<bool> condition)
        { for (var index = 0; index < 180 && !condition(); index++) await Task.Delay(25); if (!condition()) throw new InvalidOperationException("导出状态未按预期改变。"); }
        async Task Menu(string name, string? parent = null)
        {
            if (name.StartsWith("Preview", StringComparison.Ordinal))
            {
                var save = (AppBarButton)page.FindName("SaveButton");
                if (save.IsInOverflow) { ((CommandBar)page.FindName("PreviewCommandBar")).IsOpen = true; await Task.Delay(60); }
                ((IInvokeProvider)new AppBarButtonAutomationPeer(save).GetPattern(PatternInterface.Invoke)).Invoke();
            }
            else ((Button)page.FindName("MoreButton")).Flyout.ShowAt((FrameworkElement)page.FindName("MoreButton"));
            await Task.Delay(60);
            if (parent is not null)
            {
                var sub = (MenuFlyoutSubItem)page.FindName(parent);
                if (!sub.IsEnabled) throw new InvalidOperationException("导出菜单未启用。");
                ((IExpandCollapseProvider)FrameworkElementAutomationPeer.CreatePeerForElement(sub)!.GetPattern(PatternInterface.ExpandCollapse)).Expand(); await Task.Delay(60);
            }
            var item = (MenuFlyoutItem)page.FindName(name);
            if (!item.IsEnabled || item.Visibility != Visibility.Visible) throw new InvalidOperationException("导出动作不可用。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(item).GetPattern(PatternInterface.Invoke)).Invoke();
            if (state == "export-duplicate" && name.StartsWith("Preview", StringComparison.Ordinal))
            {
                typeof(SynologyPhotosPage).GetMethod("Save_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
                typeof(SynologyPhotosPage).GetMethod("StartSlideshow_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
                if (repository.ExportedPhotos.Count > 1 || workspace.Slideshow.IsPresented) throw new InvalidOperationException("菜单退场期间重复启动了导出或幻灯片。");
            }
        }
        try
        {
            await workspace.LoadIfNeededAsync();
            if (state == "export-filtered") await workspace.SearchAsync("absent");
            if (state is "export-empty" or "export-filtered")
            {
                if (workspace.Items.Count != 0 || ((MenuFlyoutSubItem)page.FindName("ExportSelectionMenu")).IsEnabled)
                    throw new InvalidOperationException("空内容仍可导出所选照片。");
                await WriteSnapshotAsync(page); return;
            }
            if (state == "export-album") { await workspace.SelectSectionAsync(SynologyPhotosSection.Albums); await workspace.OpenCollectionAsync(workspace.Collections.Single()); }
            if (state is "export-folder" or "export-mixed") await workspace.SelectSectionAsync(SynologyPhotosSection.Folders);
            var items = workspace.Items.ToArray(); var month = workspace.SelectedMonth;
            var batch = state is "export-batch" or "export-preserved" or "export-partial" or "export-collision" or "export-similar" or "export-mixed";
            if (batch)
            {
                await Menu("SelectPhotosMenu");
                foreach (var cell in library.Items.OfType<SynologyPhotoCell>().Where(cell => cell.Photo is not null).Take(state == "export-similar" ? 1 : 2).ToArray()) library.SelectedItems.Add(cell);
                if (state == "export-mixed") library.SelectedItems.Add(library.Items.OfType<SynologyPhotoCell>().First(cell => cell.Collection is not null));
            }
            else if (state is not ("export-album" or "export-folder"))
            {
                if (state == "export-decode-error") repository.SlideDecodeFails = true;
                await workspace.Preview.OpenAsync(items[0]);
                if ((bool)typeof(SynologyPhotosPage).GetField("_imageDecodePending", flags)!.GetValue(page)! && ((AppBarButton)page.FindName("SaveButton")).IsEnabled)
                    throw new InvalidOperationException("图片仍在解码时已启用保存菜单。");
                await WaitFor(() => (state == "export-decode-error" ? ((InfoBar)page.FindName("PreviewErrorBar")).IsOpen : ((Image)page.FindName("PreviewImage")).Source is not null) && ((AppBarButton)page.FindName("SaveButton")).IsEnabled);
            }
            if (state is "export-loading" or "export-cancel" or "export-late" or "export-duplicate") repository.ExportGate = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var original = Path.Combine(directory.FullName, items[0].Filename);
            if (state is "export-collision" or "export-cancel") await File.WriteAllTextAsync(original, "existing");
            if (state is "export-album" or "export-folder" or "export-mixed") await Menu("ExportArchiveOriginalMenu", "ExportArchiveMenu");
            else if (batch) await Menu(state == "export-preserved" ? "ExportJpegMenu" : "ExportOriginalMenu", "ExportSelectionMenu");
            else await Menu(state == "export-full-jpeg" ? "PreviewExportFullJpegMenu" : state == "export-jpeg" ? "PreviewExportJpegMenu" : "PreviewExportOriginalMenu");
            if (state is "export-loading" or "export-cancel" or "export-late" or "export-duplicate")
            {
                await WaitFor(() => repository.ExportedPhotos.Count == 1);
                if (!Busy() || ((AppBarButton)page.FindName("SaveButton")).IsEnabled) throw new InvalidOperationException("保存期间未阻止重复动作。");
                if (state == "export-duplicate")
                {
                    typeof(SynologyPhotosPage).GetMethod("Save_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
                    if (repository.ExportedPhotos.Count != 1) throw new InvalidOperationException("重复点击重复导出。");
                    repository.ExportGate!.TrySetResult();
                }
                else if (state == "export-cancel")
                {
                    var cancel = (Button)page.FindName("PreviewCancelSaveButton");
                    ((IInvokeProvider)new ButtonAutomationPeer(cancel).GetPattern(PatternInterface.Invoke)).Invoke(); repository.ExportGate!.TrySetResult();
                }
                else if (state == "export-late") { await workspace.SelectSectionAsync(SynologyPhotosSection.Albums); repository.ExportGate!.TrySetResult(); }
                else { await WriteSnapshotAsync(page, markComplete: false); page.SetWindowVisible(false); repository.ExportGate!.TrySetResult(); await WaitFor(() => !Busy()); MarkSnapshotComplete(); return; }
            }
            await WaitFor(() => !Busy()); await Task.Delay(80);
            var files = Directory.GetFiles(directory.FullName); var status = (InfoBar)page.FindName("SaveBar");
            if (state == "export-picker-cancel" && (repository.ExportedPhotos.Count != 0 || files.Length != 0)) throw new InvalidOperationException("取消选择后仍下载。");
            else if (state == "export-error" && (!status.IsOpen || status.Severity != InfoBarSeverity.Error || files.Length != 0)) throw new InvalidOperationException("权限错误被保存成功覆盖。");
            else if (state == "export-cancel" && (files.Length != 1 || await File.ReadAllTextAsync(original) != "existing")) throw new InvalidOperationException("取消保存改变已有文件。");
            else if (state == "export-late" && files.Length != 0) throw new InvalidOperationException("迟到下载仍被提升。");
            else if (state == "export-partial" && (files.Length != 1 || repository.ExportedPhotos.Count != 2 || status.Severity != InfoBarSeverity.Error)) throw new InvalidOperationException("批量部分失败事实丢失。");
            else if (state == "export-collision" && (files.Length != 3 || await File.ReadAllTextAsync(original) != "existing" || !files.Any(value => value.EndsWith("(1).jpg", StringComparison.Ordinal)))) throw new InvalidOperationException("同名文件没有另存。");
            else if (state == "export-preserved" && (!files.Any(value => value.EndsWith(".mp4", StringComparison.Ordinal)) || !files.Any(value => value.EndsWith(".jpg", StringComparison.Ordinal)))) throw new InvalidOperationException("实际格式与文件后缀不匹配。");
            else if (state == "export-similar" && (files.Length != 3 || repository.ExportedPhotos.Count != 3)) throw new InvalidOperationException("相似组未保存完整成员。");
            else if (state == "export-album" && repository.ExportedArchive is not SynologyPhotoArchiveTarget.Album { Value.Id: 41 }) throw new InvalidOperationException("整相册下载使用错误目标。");
            else if (state == "export-folder" && repository.ExportedArchive is not SynologyPhotoArchiveTarget.Folder { Value.Id: 1 }) throw new InvalidOperationException("整目录下载使用错误目标。");
            else if (state == "export-mixed" && repository.ExportedArchive is not SynologyPhotoArchiveTarget.Selection { Photos.Count: 2, Folders.Count: 1 }) throw new InvalidOperationException("混选丢失项目。");
            else if (state is "export-original" or "export-jpeg" or "export-full-jpeg" or "export-duplicate" && files.Length != 1) throw new InvalidOperationException("单项导出未产生文件。");
            if (state == "export-full-jpeg" && (repository.ExportedPhotos.Single().Format != SynologyPhotoDownloadFormat.OriginalSizeJpeg || !files.Single().EndsWith(".jpg", StringComparison.Ordinal))) throw new InvalidOperationException("原尺寸 JPEG 格式错误。");
            if (state == "export-decode-error" && (files.Length != 1 || !((InfoBar)page.FindName("PreviewErrorBar")).IsOpen)) throw new InvalidOperationException("预览失败阻止保存或丢失错误恢复入口。");
            if (state != "export-late" && (workspace.SelectedMonth != month || !workspace.Items.Select(value => value.Id).SequenceEqual(items.Select(value => value.Id)))) throw new InvalidOperationException("导出改变图库位置。");
            await WriteSnapshotAsync(page);
        }
        finally { repository.ExportGate?.TrySetResult(); directory.Delete(true); }
    }
    private sealed class PhotoExportPicker(string directory) : IWindowsTransferSavePicker, IWindowsTransferOpenPicker
    {
        internal bool Cancel;
        public Task<string?> PickSavePathAsync(string name) => Task.FromResult<string?>(Cancel ? null : Path.Combine(directory, name));
        public Task<string?> PickSingleFolderPathAsync() => Task.FromResult<string?>(Cancel ? null : directory);
        public Task<string?> PickSingleFilePathAsync(IReadOnlyList<string>? filters = null) => Task.FromResult<string?>(null);
        public Task<IReadOnlyList<string>?> PickMultipleFilePathsAsync(IReadOnlyList<string>? filters = null) => Task.FromResult<IReadOnlyList<string>?>(null);
    }
}
