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
    internal readonly TaskCompletionSource BackgroundRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int BackgroundWrites, BackgroundErrorReads;
    internal SynologyPhotoSettingsChange? BackgroundOperation;
    private List<SynologyPhotoBackgroundTask>? _backgroundRows;
    internal List<SynologyPhotoBackgroundTask> BackgroundRows => _backgroundRows ??= State == "pref-tasks-empty" ? [] :
        State == "pref-tasks-filtered" ? [BackgroundRow(91, SynologyPhotoBackgroundStatus.Processing)] :
        [BackgroundRow(91, SynologyPhotoBackgroundStatus.Processing), BackgroundRow(92, SynologyPhotoBackgroundStatus.Done),
            BackgroundRow(93, SynologyPhotoBackgroundStatus.Unknown) with { Operation = "future", TargetFolderId = null, TargetOwnerId = null },
            BackgroundRow(94, SynologyPhotoBackgroundStatus.Done) with { Completion = 10, Errors = 0 }];
    private SynologyPhotoBackgroundTask BackgroundRow(long id, SynologyPhotoBackgroundStatus status) =>
        new(ProfileId, 19, id, id == 92 ? "move" : "copy", status, 10, status == SynologyPhotoBackgroundStatus.Done ? 8 : 3, 1, 0, 0, 1788220800.123456 + id, 9, State == "pref-tasks-shared" ? 0 : 19);
    public async Task<IReadOnlyList<SynologyPhotoBackgroundTask>> BackgroundTasksAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pref-tasks-loading") await BackgroundRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-tasks-error") throw new IOException();
        return BackgroundRows.ToArray();
    }
    public async Task<IReadOnlyList<SynologyPhotoBackgroundError>> BackgroundTaskErrorsAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default)
    {
        BackgroundErrorReads++;
        if (State == "pref-tasks-errors-close") await BackgroundRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-tasks-errors-failed") throw new IOException();
        return [new(SynologyPhotoBackgroundErrorKind.Item, 1, SynologyPhotoBackgroundErrorReason.Quota, "Synthetic photo.jpg", "/Synthetic"),
            new(SynologyPhotoBackgroundErrorKind.Folder, 2, SynologyPhotoBackgroundErrorReason.TargetMissing),
            new(SynologyPhotoBackgroundErrorKind.Unknown, 3, SynologyPhotoBackgroundErrorReason.Unknown)];
    }
    public Task<IReadOnlyList<SynologyPhotoFolder>> BackgroundTaskLocationAsync(SynologyPhotoBackgroundTask task, CancellationToken cancellationToken = default)
    {
        if (State == "pref-tasks-location-failed") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return Task.FromResult<IReadOnlyList<SynologyPhotoFolder>>([new(task.TargetSpace!.Value, 1, 0, "/"), new(task.TargetSpace.Value, 9, 1, "/Synthetic destination")]);
    }
    public Task<IReadOnlyList<SynologyPhotoSettingsChange>> BackgroundChangesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoSettingsChange>>(BackgroundOperation is null ? [] : [BackgroundOperation]);
    public async Task<SynologyPhotoSettingsChange> ControlBackgroundTasksAsync(Guid operationId, SynologyPhotoBackgroundCommand command, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed || command.Targets.Count == 0) throw new InvalidOperationException("后台控制缺少确认。"); BackgroundWrites++;
        if (State == "pref-tasks-close") await BackgroundRelease.Task;
        var unknown = State == "pref-tasks-unknown"; var partial = State == "pref-tasks-partial";
        foreach (var original in command.Targets.Take(partial ? 1 : command.Targets.Count))
        {
            if (unknown) break;
            if (command.Action == SynologyPhotoBackgroundAction.Clear) BackgroundRows.RemoveAll(value => value.Id == original.Id);
            else { var index = BackgroundRows.FindIndex(value => value.Id == original.Id); BackgroundRows[index] = original with { Status = SynologyPhotoBackgroundStatus.Done }; }
        }
        return BackgroundOperation = new(operationId, null, unknown ? SynologyPhotoChangeState.PendingReview : partial ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed, false)
        { Background = command, CompletedSteps = unknown ? 0 : partial ? 1 : command.Targets.Count, TotalSteps = command.Targets.Count };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoBackgroundTasksAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        if (state == "pref-tasks-cold") repo.BackgroundOperation = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false)
        { Background = new(SynologyPhotoBackgroundAction.Stop, [repo.BackgroundRows.Single(value => value.Id == 91)]), TotalSteps = 1 };
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        var month = model.SelectedMonth; var ids = model.Items.Select(value => value.Id).ToArray(); var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i = 0; i < 180 && !ready(); i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("后台任务界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node) { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        T Control<T>(string id) where T : DependencyObject => Nodes(Dialog()!).OfType<T>().Single(value => AutomationProperties.GetAutomationId(value) == id);
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        Button Primary() => Nodes(Dialog()!).OfType<Button>().Single(value => value.Name == "PrimaryButton");
        bool HasButton(string id) => Dialog() is { } dialog && Nodes(dialog).OfType<Button>().Any(value => AutomationProperties.GetAutomationId(value) == id);
        try
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
            var menu = (MenuFlyoutItem)page.FindName("PhotoBackgroundTasksMenu"); if (menu.Visibility != Visibility.Visible || !menu.IsEnabled) throw new InvalidOperationException("后台任务入口不可用。");
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
            if (state is "pref-tasks-loading" or "pref-tasks-error" or "pref-tasks-empty")
            { await Task.Delay(170); if (Dialog()!.IsPrimaryButtonEnabled || repo.BackgroundWrites != 0) throw new InvalidOperationException("无任务时出现提交。"); }
            else
            {
                await Wait(() => HasButton("PhotoTaskDetails91"));
                if (state == "pref-tasks-filtered")
                {
                    Control<ComboBox>("PhotoTaskFilter").SelectedIndex = 2; await Wait(() => HasButton("PhotoTaskShowAll"));
                    if (Control<Button>("PhotoTaskClearSelected").IsEnabled) throw new InvalidOperationException("空筛选可以清理。");
                }
                else if (state is "pref-tasks-clear" or "pref-tasks-clear-confirm" or "pref-tasks-partial")
                {
                    Control<CheckBox>("PhotoTaskSelect92").IsChecked = true; Control<CheckBox>("PhotoTaskSelect94").IsChecked = true;
                    Click(Control<Button>("PhotoTaskClearSelected")); await Wait(() => Dialog()!.IsPrimaryButtonEnabled);
                    if (repo.BackgroundWrites != 0) throw new InvalidOperationException("清理确认前写入。");
                    if (state != "pref-tasks-clear-confirm")
                    {
                        Click(Primary()); await Wait(() => repo.BackgroundOperation is not null && Control<Button>("PhotoTaskRefresh").IsEnabled);
                        if (repo.BackgroundRows.Any(value => value.Id == 92) || repo.BackgroundWrites != 1 || !repo.BackgroundRows.Any(value => value.Id == 91)) throw new InvalidOperationException("清理目标错误。");
                        if (state == "pref-tasks-partial" && (!repo.BackgroundRows.Any(value => value.Id == 94) || repo.BackgroundOperation!.CompletedSteps != 1)) throw new InvalidOperationException("部分清理丢失剩余目标。");
                    }
                }
                else if (state is not ("pref-tasks" or "pref-tasks-nohome"))
                {
                    Click(Control<Button>(state == "pref-tasks-readonly" ? "PhotoTaskDetails93" : "PhotoTaskDetails91")); await Wait(() => Control<Button>("PhotoTaskBack").Visibility == Visibility.Visible);
                    if (state == "pref-tasks-readonly" && (HasButton("PhotoTaskStop") || HasButton("PhotoTaskClear"))) throw new InvalidOperationException("未知任务存在写入口。");
                    if (state is "pref-tasks-errors" or "pref-tasks-errors-failed" or "pref-tasks-errors-close")
                    {
                        Click(Control<Button>("PhotoTaskErrors")); await Wait(() => repo.BackgroundErrorReads == 1);
                        if (state == "pref-tasks-errors-close") { Dialog()!.Hide(); repo.BackgroundRelease.TrySetResult(); await Task.Delay(150); }
                        else { await Wait(() => Control<Button>("PhotoTaskRefresh").IsEnabled); if (state == "pref-tasks-errors" && !Nodes(Dialog()!).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosTaskErrorQuota"))) throw new InvalidOperationException("缺少失败原因。"); }
                    }
                    if (state is "pref-tasks-location" or "pref-tasks-shared" or "pref-tasks-location-failed")
                    {
                        Click(Control<Button>("PhotoTaskOpenLocation"));
                        if (state == "pref-tasks-location-failed") await Wait(() => Control<Button>("PhotoTaskRefresh").IsEnabled);
                        else { await Wait(() => model.Section == SynologyPhotosSection.Folders && Dialog() is null); if (model.FolderHistory.Last().Id != 9 || model.SelectedSpace != (state == "pref-tasks-shared" ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal)) throw new InvalidOperationException("未导航到原任务来源和目录。"); }
                    }
                    if (state == "pref-tasks-cold" && Control<Button>("PhotoTaskStop").IsEnabled) throw new InvalidOperationException("冷恢复期间可以重复停止。");
                    if (state is "pref-tasks-stop" or "pref-tasks-stop-confirm" or "pref-tasks-unknown" or "pref-tasks-close")
                    {
                        Click(Control<Button>("PhotoTaskStop")); await Wait(() => Dialog()!.IsPrimaryButtonEnabled);
                        if (repo.BackgroundWrites != 0) throw new InvalidOperationException("停止确认前写入。");
                        if (state != "pref-tasks-stop-confirm")
                        {
                            Click(Primary()); await Wait(() => repo.BackgroundWrites == 1);
                            if (state == "pref-tasks-close") { Dialog()!.Hide(); repo.BackgroundRelease.TrySetResult(); await Wait(() => repo.BackgroundOperation is not null); }
                            else { await Wait(() => Control<Button>("PhotoTaskRefresh").IsEnabled); if (state == "pref-tasks-unknown") { Click(Control<Button>("PhotoTaskRefresh")); await Task.Delay(100); if (Control<Button>("PhotoTaskStop").IsEnabled) throw new InvalidOperationException("未知控制允许重发。"); } }
                            if (repo.BackgroundWrites != 1) throw new InvalidOperationException("后台控制重复提交。");
                        }
                    }
                }
            }
            if (state is not ("pref-tasks-location" or "pref-tasks-shared") && (model.SelectedMonth != month || !model.Items.Select(value => value.Id).SequenceEqual(ids))) throw new InvalidOperationException("任务中心改变原图库位置。");
            await Task.Delay(120); await WriteSnapshotAsync(Dialog() is { IsLoaded: true } dialog ? dialog : page, markComplete: false); verified = true;
        }
        finally
        {
            repo.BackgroundRelease.TrySetResult();
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
