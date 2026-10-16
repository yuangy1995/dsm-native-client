using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.App.Views.Photos;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed partial class SmokePhotosRepository
{
    public bool SupportsSimilarManagement(SynologyPhotoSpace space) => State.StartsWith("sim-", StringComparison.Ordinal) && State != "sim-capability";
    internal int SimilarStatusCalls, SimilarCleanupCalls;
    private readonly Dictionary<long, SynologyPhotoSimilarGroup?> _similarGroups = new()
    { [11] = new(11, SynologyPhotoSpace.Personal, 1, [1, 2, 3]), [12] = new(12, SynologyPhotoSpace.Personal, 4, [4, 5, 6]) };
    private SynologyPhoto SimilarPhoto(long id, SynologyPhotoSpace space)
    {
        var date = new DateTimeOffset(2026, 9, 16, 0, 0, 0, TimeSpan.Zero);
        return new(new(ProfileId, space, id), $"Sample-{id:000}.jpg", 2048, date, date, 1, "photo") { Thumbnail = new(id, "synthetic") };
    }
    public async Task<SynologyPhotoSimilarDetail?> SimilarGroupAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        if (State is "sim-loading" or "sim-late") await PeopleRelease.Task;
        if (State == "sim-error") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (State == "sim-empty" || _similarGroups.GetValueOrDefault(id) is not { } original) return null;
        var group = original with { Space = space }; return new(group, group.PhotoIds.Select(id => SimilarPhoto(id, space) with { SimilarGroup = group }).ToArray());
    }
    public Task<SynologyPhotoSimilarStatus> SimilarStatusAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    { SimilarStatusCalls++; return State == "sim-status-failed"
        ? Task.FromException<SynologyPhotoSimilarStatus>(new SynologyPhotoException(SynologyPhotoFailure.Unavailable))
        : Task.FromResult(new SynologyPhotoSimilarStatus(State is "sim-status" or "sim-status-lifecycle" ? 5 : 0, State is "sim-status" or "sim-status-lifecycle" ? "running" : "future", State != "sim-status-waiting")); }
    public Task<IReadOnlyList<SynologyPhoto>> SimilarCleanupAsync(SynologyPhotoSimilarDetail detail, IReadOnlyList<long> keep, CancellationToken cancellationToken = default)
    { SimilarCleanupCalls++; return Task.FromResult<IReadOnlyList<SynologyPhoto>>(detail.Photos.Where(photo => !keep.Contains(photo.Id.ItemId)).ToArray()); }
    private SynologyPhotoRecognitionChange SaveSyntheticSimilar(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        var unknown = State == "sim-unknown"; var partial = State == "sim-partial"; var done = unknown ? 0 : partial ? 1 : edit.SimilarGroups.Count;
        var results = new List<SynologyPhotoSimilarResult>();
        foreach (var (detail, index) in edit.SimilarGroups.Select((detail, index) => (detail, index)))
        {
            var group = detail.Group; var completed = index < done; SynologyPhotoSimilarGroup? result = group;
            if (completed)
            {
                result = edit.Kind switch { SynologyPhotoRecognitionKind.SimilarTopPick => group with { TopPickId = edit.SimilarSelection[0] },
                    SynologyPhotoRecognitionKind.SimilarRemove => group with { PhotoIds = group.PhotoIds.Except(edit.SimilarSelection).ToArray() },
                    SynologyPhotoRecognitionKind.SimilarUndo => group, _ => null };
                if (result?.Count < 2) result = null; _similarGroups[group.Id] = result;
            }
            results.Add(new(Guid.NewGuid(), group.Id, completed ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result, !unknown));
        }
        var value = new SynologyPhotoRecognitionChange(id, edit.Kind, edit.Space, done == results.Count ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview,
            null, false, false, false, results.Count, results.Where(step => step.State == SynologyPhotoChangeState.Completed).Select(step => step.GroupId).ToArray(), [], [])
        { SimilarGroups = results, TargetIds = results.Select(step => step.GroupId).ToArray(), CanUndo = done == results.Count && edit.Kind is SynologyPhotoRecognitionKind.SimilarRemove or SynologyPhotoRecognitionKind.SimilarUngroup,
            UndoOperationId = edit.UndoOperationId };
        _recognitionChanges!.Add(value); return value;
    }
    public Task<SynologyPhotoRecognitionEdit> SimilarUndoAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        var original = SubmittedPeople!;
        return Task.FromResult(new SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind.SimilarUndo, []) { Space = original.Space, SimilarGroups = original.SimilarGroups.Reverse().ToArray(), UndoOperationId = operationId });
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoSimilarAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!; var l = Localization.LocalizationService.Current;
        if (state == "sim-shared") await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
        var verified = false;
        try
        {
            if (state == "sim-capability")
            { if (model.Categories.Contains(SynologyPhotoCategory.Similar)) throw new InvalidOperationException("缺失能力仍出现相似分类。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            await model.OpenCategoryAsync(SynologyPhotoCategory.Similar);
            if (state.StartsWith("sim-status", StringComparison.Ordinal))
            {
                var bar = (InfoBar)page.FindName("SimilarStatusBar"); await Wait(() => bar.IsOpen);
                var expected = state is "sim-status" or "sim-status-lifecycle" ? l.Format("PhotosSimilarProcessing", 5) : l.Get(state == "sim-status-failed" ? "PhotosSimilarStatusFailed" : "PhotosSimilarWaiting");
                if (bar.Message != expected) throw new InvalidOperationException("识别进度文案不匹配。");
                var grid = (GridView)page.FindName("LibraryGrid"); grid.UpdateLayout(); await Wait(() => grid.ContainerFromIndex(0) is GridViewItem { IsLoaded: true });
                await Wait(() => Nodes(grid).OfType<Image>().Any(image => image.Source is not null));
                if (state == "sim-status-lifecycle")
                {
                    var timer = (DispatcherTimer)typeof(SynologyPhotosPage).GetField("_similarTimer", flags)!.GetValue(page)!;
                    var reads = repo.SimilarStatusCalls; page.SetWindowVisible(false); if (timer.IsEnabled) throw new InvalidOperationException("隐藏窗口仍轮询。");
                    page.SetWindowVisible(true); await Wait(() => repo.SimilarStatusCalls > reads); if (!timer.IsEnabled) throw new InvalidOperationException("重新显示未恢复轮询。");
                    await model.SelectSectionAsync(SynologyPhotosSection.Timeline); if (timer.IsEnabled || bar.IsOpen) throw new InvalidOperationException("离开相似分类仍显示旧状态。");
                }
                await WriteSnapshotAsync(page, markComplete: false); verified = true; return;
            }
            var batch = state is "sim-batch" or "sim-partial" or "sim-loading" or "sim-error" or "sim-empty" or "sim-late";
            var history = state.StartsWith("sim-history", StringComparison.Ordinal);
            if (batch || history)
            {
                if (!history) { typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]); var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0; if (state is "sim-batch" or "sim-partial") grid.SelectedItems.Add(grid.Items[1]); }
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
                var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoRecognitionChangesMenu" : "SimilarGroupsMenu"); if (!menu.IsEnabled) throw new InvalidOperationException("相似组入口不可用。");
                ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            }
            else
            {
                await model.Preview.OpenAsync(model.Items[0]); var button = (AppBarButton)page.FindName("SimilarPhotoButton");
                if (!button.IsEnabled || button.Visibility != Visibility.Visible) throw new InvalidOperationException("组内入口不可用。");
                ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.AppBarButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            }
            await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(150); var dialog = Dialog()!;
            var editor = Nodes(dialog).OfType<SynologyPhotoSimilarEditor>().SingleOrDefault();
            if (state is "sim-loading" or "sim-error" or "sim-empty" or "sim-late")
            { if (dialog.IsPrimaryButtonEnabled || editor is not null) throw new InvalidOperationException("不可用组仍能提交。"); }
            else if (!history)
            {
                if (editor is null) throw new InvalidOperationException("相似组表单未显示。");
                var list = Nodes(editor).OfType<ListView>().Single(); var action = Nodes(editor).OfType<ComboBox>().Single();
                action.SelectedIndex = state is "sim-remove" or "sim-undo" ? 1 : state is "sim-ungroup" or "sim-unknown" or "sim-confirm-cancel" or "sim-shared" or "sim-conflict" ? 2 : state.StartsWith("sim-cleanup", StringComparison.Ordinal) ? 3 : 0;
                list.SelectedIndex = 1;
                if (state is "sim-filtered" or "sim-keyboard")
                {
                    var search = Nodes(editor).OfType<TextBox>().Single(box => Equals(box.Header, l.Get("PhotosSimilarFind"))); search.Text = "absent";
                    await Wait(() => list.Items.Count == 0); if (editor.Selected.Length != 1) throw new InvalidOperationException("过滤丢失组内选择。");
                    if (state == "sim-keyboard") { search.Text = ""; await Wait(() => list.Items.Count > 0 && list.SelectedItems.Count == 1); list.UpdateLayout(); await Wait(() => list.ContainerFromIndex(0) is ListViewItem { IsLoaded: true });
                        if (!((ListViewItem)list.ContainerFromIndex(0)).Focus(FocusState.Keyboard)) throw new InvalidOperationException("相似组无法键盘聚焦。"); }
                }
                if (state is "sim-safety" or "sim-cleanup" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("专项保护没有关闭写入口。");
                if (state == "sim-open")
                { Invoke(Button("PhotosSimilarOpen")); await Wait(() => Dialog() is null && model.Preview.Photo?.Id.ItemId == 2); if (repo.PeopleWrites != 0) throw new InvalidOperationException("打开照片触发写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                if (state == "sim-cancel")
                { Invoke(Button("PhotosClose")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消仍写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                if (state is "sim-cleanup-submit" or "sim-cleanup-cancel")
                {
                    Invoke(Button("PhotosShareContinue")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosDeleteFiles"))); await Task.Delay(150); dialog = Dialog()!;
                    if (repo.SimilarCleanupCalls != 1 || repo.FileWrites != 0) throw new InvalidOperationException("清理确认前写入或未检查原组。");
                    Invoke(Button(state == "sim-cleanup-submit" ? "PhotosDeleteFiles" : "PhotosCancel"));
                    if (state == "sim-cleanup-cancel") { await Wait(() => Dialog() is null); if (repo.FileWrites != 0) throw new InvalidOperationException("取消清理仍删除原件。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                    await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosFileChanges"))); await Task.Delay(150); dialog = Dialog()!;
                    if (repo.FileWrites != 1 || repo.SimilarCleanupCalls != 2 || !repo.SubmittedFiles!.Photos.Select(photo => photo.Id.ItemId).SequenceEqual(new long[] { 1, 3 })) throw new InvalidOperationException("清理没有使用保留选择的精确补集。");
                }
                if (state is "sim-top" or "sim-remove" or "sim-ungroup" or "sim-batch" or "sim-partial" or "sim-unknown" or "sim-confirm-cancel" or "sim-shared" or "sim-conflict" or "sim-undo")
                {
                    Invoke(Button("PhotosShareContinue"));
                    if (state == "sim-conflict") { await Task.Delay(200); if (!ReferenceEquals(dialog, Dialog()) || repo.PeopleWrites != 0) throw new InvalidOperationException("冲突没有保留表单。"); }
                    else
                    {
                        await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(120); dialog = Dialog()!;
                        if (repo.PeopleWrites != 0) throw new InvalidOperationException("确认前已经写入。");
                        if (state == "sim-confirm-cancel") { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消确认仍写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                        Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                        await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(180); dialog = Dialog()!;
                        if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.Space != model.SelectedSpace) throw new InvalidOperationException("相似组来源或写入次数错误。");
                        if (state == "sim-partial" && !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Format("PhotosSimilarPartial", 1, 2))) throw new InvalidOperationException("批次部分事实未显示。");
                        if (state == "sim-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (Button("PhotosShareContinue").IsEnabled || repo.PeopleContinues != 0) throw new InvalidOperationException("未知组可以重发。"); }
                        if (state == "sim-undo")
                        { Invoke(Button("PhotosSimilarUndo")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosSimilarUndo"))); await Task.Delay(120); Invoke(Button("PhotosSimilarUndo"));
                            await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(100); dialog = Dialog()!;
                            if (repo.PeopleWrites != 2 || repo.SubmittedPeople?.UndoOperationId is null) throw new InvalidOperationException("撤销没有绑定原操作。"); }
                    }
                }
            }
            if (state == "sim-late")
            { Invoke(Button("PhotosClose")); await Wait(() => Dialog() is null); repo.PeopleRelease.TrySetResult(); await Task.Delay(180); if (Dialog() is not null || repo.PeopleWrites != 0) throw new InvalidOperationException("关闭后迟到组重新弹窗或提交。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (state == "sim-history-cold" && (repo.PeopleReviews == 0 || repo.PeopleContinues != 0 || Button("PhotosShareContinue").IsEnabled)) throw new InvalidOperationException("相似组冷恢复不是只读。");
            if (state == "sim-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(120); if (repo.PeopleContinues != 1) throw new InvalidOperationException("未显式继续原批次。"); }
            await Task.Delay(150); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("相似组控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); verified = true;
        }
        finally
        {
            repo.PeopleRelease.TrySetResult();
            if (Dialog() is { } open)
            { var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); void Closed(ContentDialog sender, ContentDialogClosedEventArgs args) { sender.Closed -= Closed; closed.TrySetResult(); }
                open.Closed += Closed; open.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 120 && !ready(); attempt++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("相似组窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value) { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
