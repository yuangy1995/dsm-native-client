using System.Net;
using System.Text;
using LanStash.App.Features.Chat;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.Domain;
using LanStash.Infrastructure;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal static partial class SmokeSnapshot
{
    private static async Task SaveDesktopLifecycleAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage original }) throw new InvalidOperationException("缺少合成工作区。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "restore";
        if (state.StartsWith("quit-", StringComparison.Ordinal)) { await SaveDesktopQuitAsync(root, state); return; }
        var directory = Path.Combine(Path.GetTempPath(), "LanStash-desktop-smoke-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new SmokeDesktopSessionStore();
        using var transport = new SmokeDesktopTransport { HoldDiscovery = state is "restore-late" or "restore-shutdown", HoldLogout = state is "logout-switch" or "logout-shutdown" };
        store.HoldRemoval = state == "logout-shutdown";
        var app = new AppViewModel(directory, store, transport);
        var frame = (Frame)original.FindName("ContentFrame");
        var profile = new NasProfile(Guid.NewGuid(), "Synthetic restored", "https://nas.invalid", 5001, "synthetic", true, true);
        Task? pending = null;
        SmokeUploadRepository? upload = null;
        SmokeCloudHeldRead? cloudRead = null;
        SmokeOfficeRepository? officeFirst = null, officeSecond = null;
        var completedEarly = false;
        try
        {
            if (state is "cloud-switch" or "cloud-shutdown")
            {
                var repository = System.Reflection.DispatchProxy.Create<IDsmRepository, SmokeCloudHeldRead>();
                cloudRead = (SmokeCloudHeldRead)repository;
                app.AddSmokeDesktopWorkspace(profile, repository, transport);
                app.ActivateTransferWorkspace(repository);
                app.StartSmokeCloud(profile.Id);
                await cloudRead.Entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                if (state == "cloud-switch")
                {
                    var other = await app.AddSmokeConnectedChatAsync("Synthetic other");
                    app.ActivateChatNotificationWorkspace(new(other.Session.Id, other.Profile.Id, "10", "101"));
                    if (cloudRead.Token.IsCancellationRequested || transport.Disposed)
                        throw new InvalidOperationException("切换 NAS 中断了原工作区的云盘读取。");
                    pending = app.StopSmokeCloudAsync(profile.Id);
                }
                else pending = app.ShutdownAsync();
                if (!cloudRead.Token.IsCancellationRequested || pending.IsCompleted || transport.Disposed)
                    throw new InvalidOperationException("云盘断开未取消并等待原读取，或过早释放网络。");
                cloudRead.Release.TrySetResult(new([], 0, 0));
                await pending;
                if (!transport.Disposed || app.IsConnectedWorkspace(repository))
                    throw new InvalidOperationException("迟到云盘读取复活了已断开的工作区。");
            }
            else if (state == "office-owners")
            {
                officeFirst = new("attach-held", "") { ProfileId = Guid.NewGuid() };
                officeSecond = new("attach-held", "") { ProfileId = Guid.NewGuid() };
                var firstRead = app.AttachSmokeOfficeAsync(officeFirst);
                var secondRead = app.AttachSmokeOfficeAsync(officeSecond);
                pending = Task.WhenAll(firstRead, secondRead);
                if (officeFirst.RecoveryToken.IsCancellationRequested || officeSecond.RecoveryToken.IsCancellationRequested)
                    throw new InvalidOperationException("读取另一 NAS 的文档恢复中断了原 NAS。");
                app.DisconnectSmokeOffice(officeFirst.ProfileId); await firstRead;
                if (!officeFirst.RecoveryToken.IsCancellationRequested || officeSecond.RecoveryToken.IsCancellationRequested)
                    throw new InvalidOperationException("断开一个 NAS 取消了另一 NAS 的文档读取。");
                officeSecond.RecoveryRelease.TrySetResult(); await secondRead;
            }
            else if (state.StartsWith("restore", StringComparison.Ordinal))
            {
                store.Session = new(profile.Id, "synthetic-session", null, null);
                app.Profiles.Add(profile);
                pending = app.RestoreAsync(profile);
                if (transport.HoldDiscovery)
                {
                    await transport.DiscoveryEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    if (state == "restore-shutdown") await app.ShutdownAsync();
                    else
                    {
                        var cached = await app.AddSmokeConnectedChatAsync("Synthetic cached");
                        if (!app.ActivateChatNotificationWorkspace(new(cached.Session.Id, cached.Profile.Id, "10", "101")))
                            throw new InvalidOperationException("通知没有切回原会话。");
                        profile = cached.Profile;
                    }
                    transport.DiscoveryRelease.TrySetResult();
                }
                await pending;
                if (state == "restore-shutdown")
                {
                    if (app.Repository is not null || !transport.Disposed) throw new InvalidOperationException("退出后迟到登录重新建立了工作区。");
                }
                else
                {
                    if (app.ActiveProfile?.Id != profile.Id || app.Repository is not IChatRepository { Availability.Status: ChatAvailabilityStatus.Available } ||
                        transport.FileRequests != 0 || store.Removed.Count != 0)
                        throw new InvalidOperationException("套件账号恢复被文件权限阻断，或迟到恢复覆盖了当前工作区。");
                    frame.Content = new ShellPage(app);
                }
            }
            else if (state is "logout-switch" or "logout-shutdown")
            {
                var first = new SmokeConnectedChatRepository();
                profile = profile with { Id = first.ProfileId };
                app.AddSmokeDesktopWorkspace(profile, first, transport);
                app.ActivateTransferWorkspace(first);
                store.Session = new(profile.Id, "synthetic-session", null, null);
                var second = await app.AddSmokeConnectedChatAsync("Synthetic remaining");
                pending = app.LogoutAsync();
                await transport.LogoutEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                if (app.IsConnectedWorkspace(first) || transport.Disposed) throw new InvalidOperationException("注销未立即隔离旧工作区，或过早释放网络。");
                if (!app.ActivateChatNotificationWorkspace(new(second.Session.Id, second.Profile.Id, "10", "101")))
                    throw new InvalidOperationException("注销中不能打开另一会话。");
                await app.RestoreAsync(profile);
                if (transport.Discoveries != 0) throw new InvalidOperationException("注销尚未完成便恢复同一会话。");
                transport.LogoutRelease.TrySetResult();
                if (state == "logout-shutdown")
                {
                    await store.RemovalEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    var shutdown = app.ShutdownAsync();
                    if (shutdown.IsCompleted) throw new InvalidOperationException("退出没有等待注销完成本机清理。");
                    store.RemovalRelease.TrySetResult(); await shutdown; await pending;
                    if (store.Removed.Count != 1 || app.Profiles.Single(item => item.Id == profile.Id).AutoLogin)
                        throw new InvalidOperationException("退出遗漏了保存会话清理或自动登录关闭。");
                    await WriteSnapshotAsync(root, markComplete: false);
                    completedEarly = true;
                    return;
                }
                await pending;
                if (!ReferenceEquals(app.Repository, second.Repository) || second.Session.IsDisposed || second.Transport.Disposed ||
                    !transport.Disposed || store.Removed.Count != 1 || store.Removed[0] != profile.Id || app.Profiles.Single(item => item.Id == profile.Id).AutoLogin)
                    throw new InvalidOperationException("注销迟到结果污染了其他工作区或保存的会话。");
                frame.Content = new ShellPage(app);
            }
            else
            {
                upload = new SmokeUploadRepository(state is "transfer-drain" or "folder-drain" ? "drain" : "pause");
                profile = profile with { Id = upload.ProfileId };
                app.AddSmokeDesktopWorkspace(profile, upload, transport);
                app.ActivateTransferWorkspace(upload);
                var first = app.GetWorkspaceTransfers(null);
                frame.Content = new ShellPage(app);
                var sourceDirectory = Path.Combine(directory, "source"); Directory.CreateDirectory(sourceDirectory);
                var source = Path.Combine(sourceDirectory, "first.txt"); await File.WriteAllBytesAsync(source, [1, 2, 3]);
                var source2 = Path.Combine(sourceDirectory, "second.txt"); await File.WriteAllBytesAsync(source2, [4, 5, 6]);
                if (state == "folder-drain")
                {
                    var plan = await first.Picker!.PlanFolderUploadAsync(sourceDirectory);
                    if (plan.Plan is null || (await first.Picker.StartFolderUploadAsync(profile.Id.ToString(), "/sample", plan.Plan)).Status != FolderUploadBatchStartStatus.Started)
                        throw new InvalidOperationException("合成目录上传没有启动。");
                }
                else if (first.Picker!.StartUploadBatch(profile.Id.ToString(), "/sample", [source, source2]) != FileUploadBatchValidationStatus.Valid)
                    throw new InvalidOperationException("合成上传没有启动。");
                await upload.Reading.Task.WaitAsync(TimeSpan.FromSeconds(5));
                if (!app.HasRunningTransfers) throw new InvalidOperationException("退出保护未识别正在运行的传输。");
                if (state == "transfer-switch")
                {
                    var second = await app.AddSmokeConnectedChatAsync("Synthetic remaining");
                    await app.SwitchProfileAsync(second.Profile); frame.Content = new ShellPage(app); await Task.Delay(100);
                    if (upload.Uploads != 1 || upload.LastContent?.CanRead != true || transport.Disposed) throw new InvalidOperationException("切换页面中断了原传输。");
                    if (!app.ActivateTransferWorkspace(upload)) throw new InvalidOperationException("传输通知不能回到原工作区。");
                    var restored = app.GetWorkspaceTransfers(null);
                    if (!ReferenceEquals(first.Coordinator, restored.Coordinator) || !ReferenceEquals(first.Picker, restored.Picker))
                        throw new InvalidOperationException("返回工作区重新创建了传输执行器。");
                    frame.Content = new ShellPage(app); await Task.Delay(100);
                    var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    first.Picker.UploadBatchFinished += _ => completed.TrySetResult();
                    upload.Release.TrySetResult(); await completed.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    if (upload.Uploads != 2 || first.Coordinator.GetActivities(profile.Id.ToString()).Count != 3 ||
                        first.Coordinator.GetActivities(profile.Id.ToString()).Any(item => item.State != ForegroundTransferState.Completed))
                        throw new InvalidOperationException("切换后的任务历史或逐项结果丢失。");
                    await ((ShellPage)frame.Content).ShowTransfersAsync();
                }
                else
                {
                    pending = app.ShutdownAsync();
                    await upload.CleanupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                    if (pending.IsCompleted || transport.Disposed || upload.LastContent?.CanRead != true)
                        throw new InvalidOperationException("退出没有等待传输保留内容。");
                    upload.CleanupRelease.TrySetResult(); await pending;
                    if (!transport.Disposed || upload.LastContent?.CanRead != false || upload.Uploads != 1 || app.IsConnectedWorkspace(upload) ||
                        app.ActivateTransferWorkspace(upload)) throw new InvalidOperationException("退出后仍有传输或通知能够复活旧工作区。");
                }
            }
            await Task.Delay(180); await WriteSnapshotAsync(root, markComplete: false);
        }
        finally
        {
            transport.DiscoveryRelease.TrySetResult(); transport.LogoutRelease.TrySetResult();
            store.RemovalRelease.TrySetResult();
            cloudRead?.Release.TrySetResult(new([], 0, 0));
            officeFirst?.RecoveryRelease.TrySetResult(); officeSecond?.RecoveryRelease.TrySetResult();
            upload?.Release.TrySetResult(); upload?.CleanupRelease.TrySetResult();
            if (pending is not null) await pending;
            frame.Content = null;
            await app.ShutdownAsync();
            // 仅清理本用例创建的随机目录，不能触及真实用户配置。
            foreach (var path in Directory.EnumerateFiles(directory, "*", SearchOption.AllDirectories)) File.Delete(path);
            foreach (var path in Directory.EnumerateDirectories(directory, "*", SearchOption.AllDirectories).OrderByDescending(path => path.Length)) Directory.Delete(path);
            Directory.Delete(directory);
            if (completedEarly) MarkSnapshotComplete();
        }
        MarkSnapshotComplete();
    }

    private static async Task SaveSavedRecordingsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "content";
        var directory = Path.Combine(Path.GetTempPath(), "LanStash-saved-voice-smoke-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".m4a"); var destination = Path.Combine(directory, "export.m4a");
        if (state != "empty") await File.WriteAllBytesAsync(path, [1, 2, 3]);
        var protectedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (state == "protected") protectedPaths.Add(path);
        var store = new SmokeSavedRecordingsStore(new(directory), state);
        var dialog = new ChatSavedRecordingsDialog(store, () => protectedPaths,
            _ => Task.FromResult<string?>(state == "export-error" ? path : destination)) { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme };
        var showing = dialog.ShowAsync();
        T Control<T>(string id) where T : DependencyObject => Descendants(dialog).OfType<T>().Single(item => AutomationProperties.GetAutomationId(item) == id);
        async Task Click(string id)
        {
            var button = Control<Button>(id);
            if (!button.IsEnabled) throw new InvalidOperationException("录音恢复按钮不可用。");
            ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(150);
        }
        try
        {
            await Task.Delay(160);
            if (state == "loading")
            {
                if (dialog.LoadingTask.IsCompleted || Control<Button>("ChatSavedRecordingsRefresh").IsEnabled) throw new InvalidOperationException("加载中可以重复读取。");
            }
            else
            {
                await dialog.LoadingTask;
                if (state is "empty" or "protected" && Control<TextBlock>("ChatSavedRecordingsEmpty").Visibility != Visibility.Visible)
                    throw new InvalidOperationException("录音空状态或正在使用的副本保护不正确。");
                if (state == "error" && !Control<InfoBar>("ChatSavedRecordingsStatus").IsOpen) throw new InvalidOperationException("读取错误缺少恢复提示。");
                if (state == "filtered")
                {
                    Control<TextBox>("ChatSavedRecordingsSearch").Text = "no matching synthetic date";
                    await Task.Delay(80); dialog.UpdateLayout();
                    if (Control<TextBlock>("ChatSavedRecordingsEmpty").Visibility != Visibility.Visible || Descendants(dialog).OfType<Button>().Any(item => AutomationProperties.GetAutomationId(item) == "ChatSavedRecordingsExport"))
                        throw new InvalidOperationException("筛选后为空仍展示录音操作。");
                }
                if (state is "export" or "export-error")
                {
                    await Click("ChatSavedRecordingsExport");
                    if (!File.Exists(path) || state == "export" && (!File.Exists(destination) || !File.ReadAllBytes(destination).SequenceEqual(new byte[] { 1, 2, 3 })) ||
                        state == "export-error" && Control<InfoBar>("ChatSavedRecordingsStatus").Severity != InfoBarSeverity.Error)
                        throw new InvalidOperationException("录音导出结果或失败保留副本不正确。");
                }
                if (state is "discard" or "discard-confirm" or "changed")
                {
                    await Click("ChatSavedRecordingsDiscard");
                    if (!File.Exists(path) || Control<StackPanel>("ChatSavedRecordingsDiscardConfirmation").Visibility != Visibility.Visible)
                        throw new InvalidOperationException("录音没有先确认便被丢弃。");
                    if (state != "discard-confirm")
                    {
                        if (state == "changed") await File.WriteAllBytesAsync(path, [4, 5, 6, 7]);
                        await Click("ChatSavedRecordingsDiscardConfirm");
                        if (state == "discard" && File.Exists(path) || state == "changed" && (!File.Exists(path) || Control<InfoBar>("ChatSavedRecordingsStatus").Severity != InfoBarSeverity.Error))
                            throw new InvalidOperationException("录音丢弃没有绑定原文件身份。");
                    }
                }
            }
            await WriteSnapshotAsync(dialog, markComplete: false);
        }
        finally
        {
            store.Release.TrySetResult(); await dialog.LoadingTask; dialog.Hide(); await showing;
            foreach (var file in Directory.GetFiles(directory)) File.Delete(file); Directory.Delete(directory);
        }
        MarkSnapshotComplete();
    }

    private static async Task SaveDesktopQuitAsync(FrameworkElement root, string state)
    {
        var window = (Application.Current as App)!.MainWindow!;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var app = (AppViewModel)typeof(MainWindow).GetField("_viewModel", flags)!.GetValue(window)!;
        var connected = await app.AddSmokeConnectedChatAsync("Synthetic voice workspace");
        app.ActivateChatNotificationWorkspace(new(connected.Session.Id, connected.Profile.Id, "10", "101")); await Task.Delay(200);
        var page = app.GetChatPage(connected.Repository);
        var browser = (ChatBrowserViewModel)page.DataContext;
        await browser.SelectConversationAsync(browser.Conversations.Single()); await Task.Delay(80);
        var directory = Path.Combine(Path.GetTempPath(), "LanStash-quit-voice-smoke-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".m4a");
        var voice = new ChatVoiceRecordingModel(connected.Repository, connected.Repository.Conversation, new SmokeVoiceCapture(path, false));
        ((Dictionary<string, ChatVoiceRecordingModel>)typeof(ChatPage).GetField("_voiceModels", flags)!.GetValue(page)!).Add("10", voice);
        await voice.StartAsync(); await voice.StopAsync();
        var composer = (ChatTextComposerViewModel)typeof(ChatPage).GetField("_composer", flags)!.GetValue(page)!;
        ((TextBox)page.FindName("ComposerInput")).Text = "Synthetic unsent text"; await Task.Delay(80);
        var exitArmed = false;
        ContentDialog? Dialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(window.Content.XamlRoot).SelectMany(popup => Descendants(popup.Child)).OfType<ContentDialog>().FirstOrDefault();
        try
        {
            typeof(MainWindow).GetMethod("RequestExit", flags)!.Invoke(window, null);
            for (var i = 0; i < 100 && Dialog()?.IsLoaded != true; i++) await Task.Delay(30);
            var dialog = Dialog() ?? throw new InvalidOperationException("退出没有提示未发送草稿与录音。");
            var l = Localization.LocalizationService.Current;
            if (dialog.Content is not string content || !content.Contains(l.Get("DesktopQuitDraftsDetail"), StringComparison.Ordinal) ||
                !content.Contains(l.Get("DesktopQuitVoiceDetail"), StringComparison.Ordinal)) throw new InvalidOperationException("退出提示未说明草稿与录音的处理方式。");
            await WriteSnapshotAsync(dialog, markComplete: false);
            if (state == "quit-keep-voice")
            {
                window.Closed += (_, _) =>
                {
                    if (!File.Exists(path) || !File.ReadAllBytes(path).SequenceEqual(new byte[] { 1, 2, 3 }) || !connected.Transport.Disposed)
                        throw new InvalidOperationException("退出没有保留录音或释放原工作区。");
                    File.Delete(path); Directory.Delete(directory); MarkSnapshotComplete();
                };
                exitArmed = true;
            }
            var button = Descendants(dialog).OfType<Button>().Single(item => item.Name == (exitArmed ? "PrimaryButton" : "CloseButton"));
            ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            if (exitArmed) return;
            for (var i = 0; i < 100 && (bool)typeof(MainWindow).GetField("_officeExitDialogOpen", flags)!.GetValue(window)!; i++) await Task.Delay(30);
            if (!File.Exists(path) || composer.DraftText != "Synthetic unsent text" || connected.Transport.Disposed)
                throw new InvalidOperationException("取消退出丢失了草稿或录音。");
        }
        finally
        {
            if (!exitArmed)
            {
                Dialog()?.Hide(); await app.ReleaseSmokeChatAsync(connected.Profile.Id);
                File.Delete(path); Directory.Delete(directory);
            }
        }
        MarkSnapshotComplete();
    }
}

internal sealed class SmokeSavedRecordingsStore(ChatSavedRecordings store, string state) : IChatSavedRecordings
{
    internal TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async Task<ChatSavedRecordingList> ListAsync(IReadOnlySet<string> protectedPaths, CancellationToken token = default)
    {
        if (state == "loading") await Release.Task;
        if (state == "error") throw new IOException("合成读取错误。");
        return await store.ListAsync(protectedPaths, token);
    }
    public Task ExportAsync(ChatSavedRecording expected, string destination, IReadOnlySet<string> protectedPaths, CancellationToken token = default) => store.ExportAsync(expected, destination, protectedPaths, token);
    public void Discard(ChatSavedRecording expected, IReadOnlySet<string> protectedPaths) => store.Discard(expected, protectedPaths);
}

public sealed partial class AppViewModel
{
    internal Task AttachSmokeOfficeAsync(IOfficeEditingRepository repository) => AttachOfficeRepositoryAsync(repository);
    internal void DisconnectSmokeOffice(Guid profileId) => DisconnectOffice(profileId);
    internal AppViewModel(string directory, SmokeDesktopSessionStore store, SmokeDesktopTransport transport) : this()
    {
        _cloudDrives = new(new(Path.Combine(directory, "cloud-mappings.json")));
        _sessionStore = store; _passwordStore = new SmokeDesktopPasswordStore(); _certificatePins = new SmokeDesktopCertificateStore();
        _profilesPath = Path.Combine(directory, "profiles.json");
        _connectionFactory = (_, _) => new(new HttpClient(transport));
        _crossNasStore = _photosUploadsStore = _photosManagementStore = _officeEditingStore = _downloadActionsStore = _nasManagementStore = new SmokeDesktopTaskStore();
    }

    internal void StartSmokeCloud(Guid id)
    {
        var mapping = new DesktopDriveMapping(Guid.NewGuid(), id, "Synthetic", DesktopDriveScope.Folder("/synthetic"),
            DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UnixEpoch);
        typeof(CloudDrive.DesktopCloudDriveService).GetField("_mappings", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!
            .SetValue(_cloudDrives, new List<DesktopDriveMapping> { mapping });
        StartDesktopDriveRecovery(_connectedWorkspaces[id]);
    }
    internal Task StopSmokeCloudAsync(Guid id) => ReleaseWorkspaceAsync(id);

    internal void AddSmokeDesktopWorkspace(NasProfile profile, IDsmRepository repository, SmokeDesktopTransport transport)
    {
        var http = new HttpClient(transport);
        _connectedWorkspaces.Add(profile.Id, new(profile, profile, new(profile.Id, "synthetic-session", null, null),
            repository, new DsmApiClient(http), http, DsmConnectionSource.DirectAddress, null));
        Profiles.Add(profile);
    }
}

internal sealed class SmokeDesktopSessionStore : ISecureSessionStore
{
    internal DsmSession? Session;
    internal List<Guid> Removed = [];
    internal bool HoldRemoval;
    internal TaskCompletionSource RemovalEntered = new(TaskCreationOptions.RunContinuationsAsynchronously), RemovalRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<DsmSession?> LoadAsync(Guid id, CancellationToken token = default) => Task.FromResult(Session?.ProfileId == id ? Session : null);
    public Task SaveAsync(DsmSession session, CancellationToken token = default) { Session = session; return Task.CompletedTask; }
    public async Task RemoveAsync(Guid id, CancellationToken token = default)
    { RemovalEntered.TrySetResult(); if (HoldRemoval) await RemovalRelease.Task; Removed.Add(id); if (Session?.ProfileId == id) Session = null; }
}

internal sealed class SmokeDesktopPasswordStore : ISecurePasswordStore
{
    public Task<string?> LoadAsync(Guid id, CancellationToken token = default) => Task.FromResult<string?>(null);
    public Task SaveAsync(Guid id, string password, CancellationToken token = default) => Task.CompletedTask;
    public Task RemoveAsync(Guid id, CancellationToken token = default) => Task.CompletedTask;
}

internal sealed class SmokeDesktopCertificateStore : ICertificatePinStore
{
    public Task<CertificateFingerprint?> LoadAsync(Guid id, CancellationToken token = default) => Task.FromResult<CertificateFingerprint?>(null);
    public Task SaveAsync(Guid id, CertificateFingerprint fingerprint, CancellationToken token = default) => Task.CompletedTask;
    public Task RemoveAsync(Guid id, CancellationToken token = default) => Task.CompletedTask;
}

internal sealed class SmokeDesktopTaskStore : IProtectedTaskStore
{
    public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() => Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(new Dictionary<Guid, byte[]>());
    public Task SaveAsync(Guid id, byte[] record) => Task.CompletedTask;
}

internal sealed class SmokeDesktopTransport : HttpMessageHandler
{
    internal bool HoldDiscovery, HoldLogout, Disposed;
    internal int FileRequests, Discoveries;
    internal TaskCompletionSource DiscoveryEntered = new(TaskCreationOptions.RunContinuationsAsynchronously), DiscoveryRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal TaskCompletionSource LogoutEntered = new(TaskCreationOptions.RunContinuationsAsynchronously), LogoutRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        var body = request.Content is null ? request.RequestUri!.Query : await request.Content.ReadAsStringAsync(token);
        string json;
        if (body.Contains("SYNO.API.Info", StringComparison.Ordinal))
        {
            Discoveries++; DiscoveryEntered.TrySetResult();
            if (HoldDiscovery) await DiscoveryRelease.Task; // 故意忽略取消，以复验迟到响应。
            json = """{"success":true,"data":{"SYNO.Chat.User":{"path":"entry.cgi","minVersion":1,"maxVersion":3,"requestFormat":"FORM"},"SYNO.Chat.Channel":{"path":"entry.cgi","minVersion":1,"maxVersion":5,"requestFormat":"FORM"},"SYNO.Chat.Post":{"path":"entry.cgi","minVersion":5,"maxVersion":5,"requestFormat":"FORM"}}}""";
        }
        else if (body.Contains("logout", StringComparison.Ordinal))
        {
            LogoutEntered.TrySetResult(); if (HoldLogout) await LogoutRelease.Task;
            json = """{"success":true}""";
        }
        else if (body.Contains("SYNO.FileStation", StringComparison.Ordinal))
        { FileRequests++; json = """{"success":false,"error":{"code":105}}"""; }
        else json = """{"success":true,"data":{"users":[],"channels":[],"posts":[]}}""";
        return new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    }
    protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
}

public class SmokeCloudHeldRead : System.Reflection.DispatchProxy
{
    internal CancellationToken Token;
    internal TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal TaskCompletionSource<FilePage> Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
    protected override object? Invoke(System.Reflection.MethodInfo? method, object?[]? args)
    {
        if (method!.Name == "get_AvailableModules") return Array.Empty<AppModule>();
        if (method.Name != nameof(IDsmRepository.ListFilesAsync)) throw new NotSupportedException(method.Name);
        Token = (CancellationToken)args![^1]!; Entered.TrySetResult();
        return Release.Task; // 故意忽略取消，复验清理等待和迟到注册门禁。
    }
}
