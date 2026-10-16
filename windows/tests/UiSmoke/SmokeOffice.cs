using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Office;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Transfers;
using LanStash.App.Platform.Office;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace LanStash.App.ViewModels;

internal sealed class SmokeOfficeRepository(string state, string localPath) : IOfficeEditingRepository, IFilePreviewRepository, IFileBrowserDataSource
{
    public Guid ProfileId { get; init; } = SmokeActivityProbe.Profile;
    public string OfficeOwnerId => new('A', 64);
    public OfficeEditingAvailability OfficeAvailability => new(true, state != "readonly", state != "storage-error");
    public byte[] Bytes = Encoding.UTF8.GetBytes("Synthetic office document");
    public FileItem Item => new("/sample/Quarterly plan.docx", "Quarterly plan.docx", false,
        state == "preview-large" ? FilePreviewClassifier.DocumentPreviewByteLimit + 1 : state == "preview-empty" ? 0 : Bytes.Length,
        DateTimeOffset.UnixEpoch, null, true, false);
    public readonly List<OfficeEditingSessionInfo> Records = [];
    public int Saves, Reviews, Resumes, Stops, Creates;
    public readonly TaskCompletionSource RangeRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public FileMD5Availability MD5Availability => new(false);
    internal static OfficeContentFingerprint Fingerprint(byte[] bytes) => new(bytes.Length, Convert.ToHexString(MD5.HashData(bytes)), Convert.ToHexString(SHA256.HashData(bytes)));
    public bool HasOfficeSessionWithin(string path) => Records.Any(record => record.State != OfficeEditingState.Stopped);
    internal TaskCompletionSource RecoveryRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal CancellationToken RecoveryToken;
    public async Task<IReadOnlyList<OfficeEditingSessionInfo>> GetOfficeSessionsAsync(CancellationToken token = default)
    { if (state == "storage-error") throw new IOException("合成恢复不可用"); RecoveryToken = token; if (state == "attach-held") await RecoveryRelease.Task.WaitAsync(token); return Records.ToArray(); }
    public Task<OfficeRemoteSnapshot> ReadOfficeRemoteAsync(string path, CancellationToken token = default) => Task.FromResult(new OfficeRemoteSnapshot(new(Item, "file", null), Fingerprint(Bytes).Md5));
    public async Task<OfficeEditingSessionInfo> CreateOfficeSessionAsync(Guid id, string path, OfficeRemoteSnapshot baseline, OfficeContentFingerprint fingerprint, CancellationToken token = default)
    { Creates++; var info = new OfficeEditingSessionInfo(id, ProfileId, OfficeOwnerId, path, baseline, fingerprint, OfficeEditingState.Ready); Records.Add(info); await Task.CompletedTask; return info; }
    public async Task<OfficeEditingSessionInfo> SaveOfficeSessionAsync(Guid id, Stream content, OfficeContentFingerprint fingerprint, CancellationToken token = default)
    {
        Saves++; using var memory = new MemoryStream(); await content.CopyToAsync(memory, token); Bytes = memory.ToArray();
        return Update(id, current => current with { Fingerprint = fingerprint, Baseline = new(new(Item, "file", null), fingerprint.Md5), State = OfficeEditingState.Saved, SavedAt = DateTimeOffset.UtcNow });
    }
    public Task<OfficeEditingSessionInfo> ReviewOfficeSessionAsync(Guid id, CancellationToken token = default)
    { Reviews++; return Task.FromResult(Update(id, current => state == "review" ? current with { State = OfficeEditingState.Saved, SavedAt = DateTimeOffset.UtcNow } : current)); }
    public Task<OfficeEditingSessionInfo> ResumeOfficeSessionAsync(Guid id, CancellationToken token = default)
    { Resumes++; return Task.FromResult(Update(id, current => current with { State = OfficeEditingState.Ready })); }
    public Task<OfficeEditingSessionInfo> StopOfficeSessionAsync(Guid id, CancellationToken token = default)
    { Stops++; return Task.FromResult(Update(id, current => current with { State = current.State == OfficeEditingState.ResultUnavailable ? current.State : OfficeEditingState.Stopped, StopRequested = true })); }
    private OfficeEditingSessionInfo Update(Guid id, Func<OfficeEditingSessionInfo, OfficeEditingSessionInfo> update)
    { var index = Records.FindIndex(record => record.Id == id); return Records[index] = update(Records[index]); }
    public async Task SeedAsync()
    {
        if (state is "sessions-empty" or "storage-error" || state.StartsWith("preview", StringComparison.Ordinal) || state is "readonly" or "open-copy" or "choose-app" or "open-failed" or "auto-confirm" or "edit-run") return;
        var phase = state switch { "unknown" or "review" => OfficeEditingState.ResultUnavailable, "conflict" => OfficeEditingState.Conflict,
            "stopped" => OfficeEditingState.Stopped, "saved" => OfficeEditingState.Saved, _ => OfficeEditingState.Ready };
        Records.Add(new(Guid.NewGuid(), ProfileId, OfficeOwnerId, localPath, await ReadOfficeRemoteAsync(Item.Path), Fingerprint(Bytes), phase,
            phase == OfficeEditingState.Stopped, state == "saved" ? DateTimeOffset.UnixEpoch.AddDays(1) : null));
        if (state == "cold") Records.Add(Records[0] with { Id = Guid.NewGuid(), State = OfficeEditingState.Stopped, StopRequested = true });
    }
    public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token) => Task.FromResult(new FilePage([Item], 1, 0));
    public FileTextEditAvailability GetTextEditAvailability() => new(false, false, []);
    public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => Task.FromResult(text);
    public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => Task.FromResult(Fingerprint(Bytes).Md5);
    public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => Task.FromResult(Bytes[(int)offset..(int)(offset + length)]);
    public async Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length, string? version = null, long? total = null, CancellationToken token = default)
    {
        if (state == "preview-loading") await RangeRelease.Task.WaitAsync(token);
        var bytes = Bytes[(int)offset..(int)(offset + length)];
        return new(206, offset, length, offset, length, Bytes.Length, bytes.Length, bytes, "\"synthetic-office-v1\"", true);
    }
}

internal sealed class SmokeOfficeFiles(SmokeOfficeRepository repository) : IOfficeLocalFiles
{
    internal byte[] Bytes = repository.Bytes.ToArray();
    internal long Revision;
    public Task<OfficeContentFingerprint> DownloadAsync(IOfficeEditingRepository repo, OfficeRemoteSnapshot baseline, string destination, CancellationToken token) => Task.FromResult(SmokeOfficeRepository.Fingerprint(Bytes));
    public IOfficeLocalCopy Open(string path) => new Copy(this);
    public Task ExportAsync(IOfficeLocalCopy copy, string destination, CancellationToken token) => File.WriteAllBytesAsync(destination, Bytes, token);
    private sealed class Copy(SmokeOfficeFiles owner) : IOfficeLocalCopy
    {
        public OfficeLocalStamp ReadStamp() => new(1, 1, 1, owner.Bytes.Length, owner.Revision, owner.Revision);
        public Task<OfficeUploadSnapshot> FreezeAsync(CancellationToken token) => Task.FromResult(new OfficeUploadSnapshot(new MemoryStream(owner.Bytes.ToArray()), SmokeOfficeRepository.Fingerprint(owner.Bytes), ReadStamp()));
        public void Dispose() { }
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveOfficeAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "preview-missing";
        if (state.StartsWith("quit-", StringComparison.Ordinal)) { await SaveOfficeQuitAsync(root, state); return; }
        var folder = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "LanStash-office-ui-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, "Quarterly plan.docx"); var repo = new SmokeOfficeRepository(state, path); await repo.SeedAsync();
        var files = new SmokeOfficeFiles(repo); using var coordinator = new OfficeEditingCoordinator(files, (_, _, _, _) => Task.CompletedTask);
        if (state != "storage-error") await coordinator.AttachAsync(repo);
        var launcher = new SmokeOfficeLauncher { Result = state != "open-failed" };
        var savePicker = new SmokeOfficeSavePicker { Path = state == "save-as" ? Path.Combine(folder, "export.docx") : path };
        var actions = new OfficeDocumentActions { Launcher = launcher, Picker = savePicker };
        using var browser = new FileBrowserViewModel(repo); using var transfers = new ForegroundTransferCoordinator(); transfers.ActivateProfile(repo.ProfileId.ToString());
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), transfers, new WindowsTransferSavePicker(() => null), new SmokeFileUploadPicker([]));
        using var page = new FilesPage(browser, repo, repo.ProfileId.ToString(), picker, officeCoordinator: coordinator);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(FilesPage).GetField("_officeActions", flags)!.SetValue(page, actions);
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        var pane = (FilePreviewPane)page.FindName("PreviewPane");
        var preview = (FilePreviewViewModel)typeof(FilesPage).GetField("_previewViewModel", flags)!.GetValue(page)!;
        var verified = false; Task? opening = null;
        IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        ContentDialog? Dialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).SelectMany(popup => Nodes(popup.Child)).OfType<ContentDialog>().FirstOrDefault();
        T Control<T>(string id) where T : DependencyObject => Nodes(Dialog()!).OfType<T>().Single(control => AutomationProperties.GetAutomationId(control) == id);
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        async Task Wait(Func<bool> predicate)
        { for (var i = 0; i < 160 && !predicate(); i++) await Task.Delay(30); if (!predicate()) throw new InvalidOperationException("Office 原生场景未达到预期状态。"); }
        void Request(bool auto, bool choose) => typeof(FilePreviewPane).GetMethod("RequestOfficeAction", flags)!.Invoke(pane, [auto, choose]);
        try
        {
            await Wait(() => browser.Items.Count == 1);
            ((GridView)page.FindName("FileGrid")).SelectedItem = browser.Items[0];
            if (state.StartsWith("preview", StringComparison.Ordinal) || state is "readonly" or "open-copy" or "choose-app" or "open-failed" or "auto-confirm" or "edit-run" or "close-preserve")
            {
                opening = (Task)typeof(FilesPage).GetMethod("OpenPreviewAsync", flags)!.Invoke(page, [browser.Items[0]])!;
                if (state != "preview-loading") await opening;
                await Wait(() => pane.Visibility == Visibility.Visible);
                await Task.Delay(120);
                if (state == "preview-loading")
                {
                    if (preview.Snapshot.Phase != FilePreviewPhase.Preparing || ((FrameworkElement)pane.FindName("PreparingState")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("文档准备状态没有显示。");
                }
                else if (state is "preview-empty" or "preview-large")
                {
                    if (preview.Snapshot.Phase != FilePreviewPhase.DetailsOnly || preview.Snapshot.UnavailableReason !=
                        (state == "preview-empty" ? FilePreviewUnavailableReason.Empty : FilePreviewUnavailableReason.TooLarge))
                        throw new InvalidOperationException("文档限制状态错误。");
                }
                else
                {
                    if (preview.Snapshot.Phase != FilePreviewPhase.Ready || ((FrameworkElement)pane.FindName("OfficePreviewPanel")).Visibility != Visibility.Visible)
                        throw new InvalidOperationException("文档没有进入原生预览呈现阶段。");
                    var expected = Localization.LocalizationService.Current.Get(state == "preview-failed" ? "OfficePreviewFailedTitle" : "OfficePreviewMissingTitle");
                    if (state != "preview-ready" && ((TextBlock)pane.FindName("OfficePreviewFallbackTitle")).Text != expected)
                        throw new InvalidOperationException("文档预览降级原因不正确。");
                }
                if (state == "readonly" && ((SplitButton)pane.FindName("OfficeAutoEditButton")).IsEnabled) throw new InvalidOperationException("普通保护未生效。");
                if (state is "open-copy" or "open-failed") Request(false, false);
                if (state == "choose-app")
                {
                    var split = (SplitButton)pane.FindName("OfficeOpenCopyButton"); split.Flyout.ShowAt(split); await Task.Delay(80);
                    ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)((MenuFlyout)split.Flyout).Items[0]).GetPattern(PatternInterface.Invoke)).Invoke();
                }
                if (state is "auto-confirm" or "edit-run")
                {
                    Request(true, false); await Wait(() => Dialog()?.IsLoaded == true);
                    if (repo.Creates != 0 || repo.Saves != 0) throw new InvalidOperationException("确认前开始自动保存。");
                    if (state == "edit-run")
                    {
                        Click(Nodes(Dialog()!).OfType<Button>().Single(button => button.Name == "PrimaryButton"));
                        await Wait(() => launcher.Opens == 1 && Dialog() is null);
                        var session = coordinator.Sessions.Single(); files.Bytes = Encoding.UTF8.GetBytes("Synthetic changed document"); files.Revision++;
                        await coordinator.PollAsync(session, DateTimeOffset.UnixEpoch); await coordinator.PollAsync(session, DateTimeOffset.UnixEpoch.AddSeconds(2));
                        if (repo.Saves != 1 || session.Phase != OfficeEditingPhase.Saved) throw new InvalidOperationException("本机编辑没有完成保存。");
                        await Wait(() => ((FrameworkElement)pane.FindName("OfficeSessionStatusButton")).Visibility == Visibility.Visible &&
                            ((TextBlock)pane.FindName("OfficeSessionStatusText")).Text.StartsWith(Localization.LocalizationService.Current.Get("OfficeSaved"), StringComparison.Ordinal));
                        typeof(FilesPage).GetMethod("ShowOfficeSessionsAsync", flags)!.Invoke(page, null); await Wait(() => Dialog()?.IsLoaded == true);
                    }
                }
                if (state is "open-copy" or "choose-app" or "open-failed")
                {
                    await Wait(() => launcher.Opens == 1);
                    if (state == "open-failed") await Wait(() => Dialog()?.IsLoaded == true);
                    else await Wait(() => Dialog() is null && !(bool)typeof(FilesPage).GetField("_officeBusy", flags)!.GetValue(page)!);
                    if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(repo.Bytes) || repo.Saves != 0 || launcher.Choose != (state == "choose-app"))
                        throw new InvalidOperationException("打开副本路径或应用选择错误。");
                }
                if (state == "preview-ready") VerifyOfficeFrameInterop();
                if (state == "close-preserve")
                {
                    var session = coordinator.Sessions.Single(); session.Watching = true; session.Phase = OfficeEditingPhase.Watching;
                    await WriteSnapshotAsync(page, markComplete: false);
                    await (Task<bool>)typeof(FilesPage).GetMethod("ClosePreviewAsync", flags)!.Invoke(page, null)!;
                    if (!session.Watching || coordinator.Sessions.Count != 1) throw new InvalidOperationException("关闭预览结束了编辑会话。");
                    verified = true; return;
                }
            }
            else
            {
                var showing = (Task)typeof(FilesPage).GetMethod("ShowOfficeSessionsAsync", flags)!.Invoke(page, null)!;
                await Wait(() => Dialog()?.IsLoaded == true);
                if (state is not ("sessions-empty" or "storage-error"))
                {
                    var session = coordinator.SessionFor(repo, repo.Item.Path, includeStopped: true)!;
                    if (state == "watching") { session.Watching = true; session.Phase = OfficeEditingPhase.Watching; }
                    if (state == "saved") session.Phase = OfficeEditingPhase.Saved;
                    if (state == "saving") { session.Phase = OfficeEditingPhase.Saving; session.Busy = true; }
                    typeof(OfficeEditingDialog).GetMethod("Refresh", flags)!.Invoke(Dialog(), null);
                    if (state == "resume") { Click(Control<Button>("OfficeContinue")); await Wait(() => repo.Resumes == 1 && session.Watching); }
                    if (state == "review")
                    { Click(Control<Button>("OfficeRefresh")); await Wait(() => repo.Reviews == 1 && session.Phase == OfficeEditingPhase.Saved); if (repo.Saves != 0 || session.Watching) throw new InvalidOperationException("刷新重复保存或自动恢复。"); }
                    if (state is "end" or "end-confirm")
                    {
                        Click(Control<Button>("OfficeEnd")); await Wait(() => Control<StackPanel>("OfficeEndConfirmation").Visibility == Visibility.Visible);
                        if (repo.Stops != 0) throw new InvalidOperationException("未确认就结束编辑。");
                        if (state == "end") { Click(Control<Button>("OfficeEndConfirm")); await Wait(() => repo.Stops == 1 && session.Phase == OfficeEditingPhase.Stopped); }
                    }
                    if (state == "save-as")
                    { Click(Control<Button>("OfficeSaveAs")); await Wait(() => File.Exists(savePicker.Path)); if (!File.ReadAllBytes(savePicker.Path).SequenceEqual(files.Bytes)) throw new InvalidOperationException("另存副本内容错误。"); }
                    if (state == "cold" && (session.Watching || repo.Saves != 0 || !Control<Button>("OfficeContinue").IsEnabled ||
                        !ReferenceEquals(Control<ListView>("OfficeSessionList").SelectedItem, session))) throw new InvalidOperationException("冷恢复自动保存或旧记录遮住当前文档。");
                    if (state == "unknown" && Control<Button>("OfficeContinue").Visibility == Visibility.Visible) throw new InvalidOperationException("未知保存可以重发。");
                    if (state == "saving" && Control<Button>("OfficeEnd").IsEnabled) throw new InvalidOperationException("在途保存允许丢弃状态。");
                }
                _ = showing;
            }
            await Task.Delay(120);
            if (Dialog() is OfficeEditingDialog { Content: ScrollViewer scroll } officeDialog)
            {
                officeDialog.UpdateLayout();
                if (scroll.ViewportWidth <= 0 || scroll.ExtentWidth > scroll.ViewportWidth + 0.5)
                    throw new InvalidOperationException("本机文档窗口内容超出可见宽度。");
            }
            await WriteSnapshotAsync(Dialog() is { IsLoaded: true } dialog ? dialog : page, markComplete: false); verified = true;
        }
        finally
        {
            repo.RangeRelease.TrySetResult();
            if (Dialog() is { } dialog)
            {
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                dialog.Closed += (_, _) => closed.TrySetResult(); dialog.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            if (opening is not null) await opening;
            await pane.CloseAsync(); await preview.CloseAsync(); page.Dispose();
            if (!folder.StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成目录边界错误。");
            Directory.Delete(folder, recursive: true);
            if (verified) MarkSnapshotComplete();
        }
    }

    private static void VerifyOfficeFrameInterop()
    {
        var frameType = typeof(WindowsOfficePreviewHost).GetNestedType("PreviewFrame", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic)!;
        var instance = Activator.CreateInstance(frameType, System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance,
            null, [(nint)1, (Action<int>)(_ => { })], null)!;
        var unknown = Marshal.GetIUnknownForObject(instance);
        try
        {
            foreach (var value in new[] { "fec87aaf-35f9-447a-adb7-20234491401a", "00000114-0000-0000-C000-000000000046" })
            {
                var iid = Guid.Parse(value); var result = Marshal.QueryInterface(unknown, in iid, out var pointer);
                if (result != 0 || pointer == 0) throw new InvalidOperationException("系统预览宿主不能提供键盘接口。");
                Marshal.Release(pointer);
            }
        }
        finally { Marshal.Release(unknown); }
    }

    private static async Task SaveOfficeQuitAsync(FrameworkElement root, string state)
    {
        var window = (Application.Current as App)?.MainWindow ?? throw new InvalidOperationException("缺少主窗口。");
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (AppViewModel)typeof(MainWindow).GetField("_viewModel", flags)!.GetValue(window)!;
        var folder = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "LanStash-office-quit-ui-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(folder); var path = Path.Combine(folder, "document.docx");
        var bytes = Encoding.UTF8.GetBytes("Synthetic local copy kept on exit"); await File.WriteAllBytesAsync(path, bytes);
        var repo = new SmokeOfficeRepository(state, path); await repo.SeedAsync(); await model.OfficeEdits.AttachAsync(repo);
        var session = model.OfficeEdits.Sessions.Single(); session.Busy = state == "quit-busy";
        var finished = false; var exitArmed = false;
        IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        ContentDialog? Dialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(root.XamlRoot).SelectMany(popup => Nodes(popup.Child)).OfType<ContentDialog>().FirstOrDefault();
        try
        {
            typeof(MainWindow).GetMethod("RequestExit", flags)!.Invoke(window, null);
            for (var i = 0; i < 160 && Dialog()?.IsLoaded != true; i++) await Task.Delay(30);
            var dialog = Dialog() ?? throw new InvalidOperationException("退出文档保护未显示。");
            if (state == "quit-busy" && !string.IsNullOrEmpty(dialog.PrimaryButtonText)) throw new InvalidOperationException("在途保存开放立即退出。");
            await WriteSnapshotAsync(dialog, markComplete: false);
            var button = Nodes(dialog).OfType<Button>().Single(value => value.Name == (state == "quit-keep-copies" ? "PrimaryButton" : "CloseButton"));
            if (state == "quit-keep-copies")
            {
                // Closed 在实际 Shutdown 后检查副本，随后清理纯合成文件并标记成功。
                window.Closed += (_, _) =>
                {
                    if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(bytes) || session.Watching)
                        throw new InvalidOperationException("退出没有保留文档副本。");
                    Cleanup(); finished = true; MarkSnapshotComplete();
                };
                exitArmed = true;
                ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                return;
            }
            ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            for (var i = 0; i < 160 && (bool)typeof(MainWindow).GetField("_officeExitDialogOpen", flags)!.GetValue(window)!; i++) await Task.Delay(30);
            if ((bool)typeof(MainWindow).GetField("_isExplicitExit", flags)!.GetValue(window)! || !File.ReadAllBytes(path).SequenceEqual(bytes))
                throw new InvalidOperationException("取消退出没有保留窗口和副本。");
            finished = true;
        }
        finally
        {
            if (state != "quit-keep-copies" || !exitArmed)
            {
                session.Busy = false; Dialog()?.Hide(); Cleanup(); if (finished) MarkSnapshotComplete();
            }
        }
        void Cleanup()
        {
            if (!folder.StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("退出合成目录边界错误。");
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
    }

    private sealed class SmokeOfficeSavePicker : IWindowsTransferSavePicker
    {
        public required string Path { get; init; }
        public Task<string?> PickSavePathAsync(string suggestedName) => Task.FromResult<string?>(Path);
    }
    private sealed class SmokeOfficeLauncher : IOfficeDocumentLauncher
    {
        public int Opens;
        public bool Choose, Result = true;
        public Task<bool> OpenAsync(string path, bool chooseApplication) { Opens++; Choose = chooseApplication; return Task.FromResult(Result); }
        public Task<bool> RevealAsync(string path) => Task.FromResult(true);
    }
}
