using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    internal bool CodecShown = true, CodecStarted;
    internal int MaintenanceWrites, CodecWrites, DismissWrites;
    public async Task<SynologyPhotoLibraryMaintenance> LibraryMaintenanceAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        if (State == "pref-maint-loading") await PreferenceRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-maint-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(ProfileId, 19, space, State == "pref-maint-busy" ? 12 : 0, State == "pref-maint-busy" ? 3 : 0, State != "pref-maint-capability");
    }
    public async Task<SynologyPhotoCodecPrompt> CodecPromptAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pref-codec-loading") await PreferenceRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-codec-error") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        return new(ProfileId, 19, State == "pref-codec-admin", CodecShown && State != "pref-codec-empty", State != "pref-codec-nohome", CodecStarted);
    }
    public async Task<SynologyPhotoSettingsChange> MaintainLibraryAsync(Guid operationId, SynologyPhotoLibraryMaintenance original, SynologyPhotoMaintenanceAction action,
        bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed || !original.CanStart(action)) throw new InvalidOperationException("维护缺少确认或空闲计数。"); MaintenanceWrites++;
        if (State == "pref-maint-close") await PreferenceRelease.Task;
        return PreferenceChange = new(operationId, null, State == "pref-maint-unknown" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, false)
        { Maintenance = new(original, action), MaintenanceAccepted = State != "pref-maint-unknown", MaintenanceResult = original, CompletedSteps = State == "pref-maint-unknown" ? 0 : 1 };
    }
    public Task<SynologyPhotoSettingsChange> RespondToCodecPromptAsync(Guid operationId, SynologyPhotoCodecPrompt original, bool generate, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!original.ShouldShow || generate && (!confirmed || !original.CanGenerate)) throw new InvalidOperationException("格式提示缺少原身份或确认。");
        if (generate) CodecWrites++; else DismissWrites++;
        var partial = generate && State == "pref-codec-partial"; var unknown = State == "pref-codec-unknown";
        if (generate && !unknown) CodecStarted = true; if (!partial && !unknown) CodecShown = false;
        return Task.FromResult(PreferenceChange = new(operationId, null, unknown ? SynologyPhotoChangeState.PendingReview : partial ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed, false)
        { Codec = new(original, generate), CodecGenerationAccepted = generate && !unknown, CompletedSteps = partial ? 1 : unknown ? 0 : generate ? 2 : 1 });
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoMaintenanceAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var codecMode = state.StartsWith("pref-codec", StringComparison.Ordinal);
        var repo = new SmokePhotosRepository();
        if (state == "pref-maint-cold") repo.PreferenceChange = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false)
        { Maintenance = new(new(repo.ProfileId, 19, SynologyPhotoSpace.Personal, 0, 0, true), SynologyPhotoMaintenanceAction.Reindex) };
        if (state == "pref-codec-cold") repo.CodecStarted = true;
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        if (state.StartsWith("pref-maint-shared", StringComparison.Ordinal)) await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        var month = model.SelectedMonth; var ids = model.Items.Select(value => value.Id).ToArray(); var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i = 0; i < 180 && !ready(); i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("图库维护界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node) { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        Button Button(string id) => Nodes(Dialog()!).OfType<Button>().Single(value => AutomationProperties.GetAutomationId(value) == id);
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        Button Primary() => Nodes(Dialog()!).OfType<Button>().Single(value => value.Name == "PrimaryButton");
        try
        {
            var menu = (MenuFlyoutItem)page.FindName(codecMode ? "PhotoCodecPromptMenu" : "PhotoMaintenanceMenu");
            if (state == "pref-maint-shared-entry")
            { if (menu.Visibility != Visibility.Collapsed) throw new InvalidOperationException("共享普通用户出现整库维护入口。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (state is "pref-maint-save" or "pref-codec-generate")
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)page.FindName("SelectPhotosMenu")).GetPattern(PatternInterface.Invoke)).Invoke();
                var grid = (GridView)page.FindName("LibraryGrid"); await Wait(() => grid.SelectionMode == ListViewSelectionMode.Multiple && grid.Items.Count > 2);
                grid.SelectedItems.Add(grid.Items[0]); grid.SelectedItems.Add(grid.Items[1]);
            }
            var moreButton = (Button)page.FindName("MoreButton"); moreButton.Flyout.ShowAt(moreButton); await Task.Delay(70);
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
            if (state is "pref-maint-loading" or "pref-maint-error" or "pref-codec-loading" or "pref-codec-error" or "pref-codec-empty")
            { await Task.Delay(160); if (Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("无有效状态时可启动维护。"); }
            else
            {
                await Wait(() => Nodes(Dialog()!).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == (codecMode ? "PhotoCodecLater" : "PhotoLibraryReindex")));
                if (state == "pref-maint-busy" && (Button("PhotoLibraryReindex").IsEnabled || Button("PhotoLibraryPreviews").IsEnabled)) throw new InvalidOperationException("忙碌时可重复启动。");
                if (state == "pref-maint-capability" && (Button("PhotoLibraryPreviews").IsEnabled || !Button("PhotoLibraryReindex").IsEnabled)) throw new InvalidOperationException("预览能力错误影响索引。");
                if (state == "pref-codec-nohome" && Button("PhotoCodecGenerate").IsEnabled) throw new InvalidOperationException("个人图库关闭仍可生成。");
                if (state == "pref-codec-cold" && Nodes(Dialog()!).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "PhotoCodecGenerate")) throw new InvalidOperationException("已接收生成仍显示再次生成。");
                if (state is "pref-codec-later" or "pref-codec-cold")
                { Click(Button("PhotoCodecLater")); await Wait(() => repo.DismissWrites == 1 && Nodes(Dialog()!).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosCodecEmpty"))); }
                if (state is "pref-maint-save" or "pref-maint-confirm" or "pref-maint-previews" or "pref-maint-shared" or "pref-maint-unknown" or "pref-maint-close" or "pref-codec-confirm" or "pref-codec-generate" or "pref-codec-admin" or "pref-codec-partial" or "pref-codec-unknown")
                {
                    Click(Button(codecMode ? "PhotoCodecGenerate" : state == "pref-maint-previews" ? "PhotoLibraryPreviews" : "PhotoLibraryReindex"));
                    await Wait(() => Dialog()!.IsPrimaryButtonEnabled); await Task.Delay(120);
                    if (repo.MaintenanceWrites + repo.CodecWrites + repo.DismissWrites != 0) throw new InvalidOperationException("最终确认前已写入。");
                    if (state is "pref-maint-confirm" or "pref-codec-confirm") { await WriteSnapshotAsync(Dialog()!, markComplete: false); verified = true; return; }
                    Click(Primary()); await Wait(() => repo.MaintenanceWrites + repo.CodecWrites == 1);
                    if (state == "pref-maint-close") { Dialog()!.Hide(); repo.PreferenceRelease.TrySetResult(); await Wait(() => repo.PreferenceChange?.State == SynologyPhotoChangeState.Completed); }
                    else if (state == "pref-codec-partial")
                    {
                        await Wait(() => Nodes(Dialog()!).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == "PhotoCodecLater" && value.IsEnabled));
                        if (Nodes(Dialog()!).OfType<TextBlock>().Count(value => value.Text == l.Get("PhotosCodecPartial")) != 1) throw new InvalidOperationException("部分完成提示重复或缺失。");
                        Click(Button("PhotoCodecLater")); await Wait(() => repo.DismissWrites == 1 && !repo.CodecShown); if (repo.CodecWrites != 1) throw new InvalidOperationException("补存提示重复生成。");
                    }
                    else if (state.EndsWith("-unknown", StringComparison.Ordinal))
                    { await Wait(() => !Dialog()!.IsPrimaryButtonEnabled); Click(Button("PhotoMaintenanceRefresh")); await Task.Delay(120); if (repo.MaintenanceWrites + repo.CodecWrites != 1) throw new InvalidOperationException("未知操作重发。"); }
                    else await Wait(() => repo.PreferenceChange?.State == SynologyPhotoChangeState.Completed && !Dialog()!.IsPrimaryButtonEnabled);
                }
            }
            if (model.SelectedMonth != month || !model.Items.Select(value => value.Id).SequenceEqual(ids)) throw new InvalidOperationException("维护改变原月份或内容窗口。");
            if (state is "pref-maint-save" or "pref-codec-generate" && ((GridView)page.FindName("LibraryGrid")).SelectedItems.Count != 2) throw new InvalidOperationException("维护丢失多选。");
            if (state is "pref-codec-later" or "pref-codec-cold" && repo.CodecWrites != 0) throw new InvalidOperationException("关闭提示启动了生成。");
            await Task.Delay(120); await WriteSnapshotAsync(Dialog() is { IsLoaded: true } dialog ? dialog : page, markComplete: false); verified = true;
        }
        finally
        {
            repo.PreferenceRelease.TrySetResult();
            if (Dialog() is { } dialog)
            {
                var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); }
                dialog.Closed += Closed; dialog.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
    }
}
