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
    public bool SupportsConceptManagement(SynologyPhotoSpace space) => State.StartsWith("concept-", StringComparison.Ordinal) && State != "concept-capability";
    private readonly List<SynologyPhotoConcept> _syntheticConcepts =
    [new(new(11, "Synthetic mountains", Count: 8) { Thumbnail = new(1, "synthetic") }, true, 7),
        new(new(12, "Synthetic flowers", Count: 8), true, 2), new(new(13, "Synthetic animals", Count: 3), false, 2)];
    public async Task<IReadOnlyList<SynologyPhotoConcept>> ConceptsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        if (State == "concept-loading") await PeopleRelease.Task;
        if (State == "concept-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return State == "concept-empty" ? [] : _syntheticConcepts.Select(value => value with { Concept = value.Concept with { Space = space } }).ToArray();
    }
    public async Task<SynologyPhotoConcept> ConceptAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default) => (await ConceptsAsync(space, cancellationToken)).Single(value => value.Concept.Id == id);
    private SynologyPhotoRecognitionChange SaveSyntheticConcept(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        var unknown = State == "concept-unknown"; var partial = State == "concept-partial"; var remove = edit.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos;
        var ids = remove ? edit.ConceptPhotos.Select(photo => photo.Id.ItemId).ToArray() : edit.Concepts.Select(value => value.Concept.Id).ToArray();
        var completed = unknown ? [] : ids.Take(partial ? 1 : 100).ToArray();
        if (!unknown) foreach (var original in edit.Concepts)
        {
            var index = _syntheticConcepts.FindIndex(value => value.Concept.Id == original.Concept.Id); var current = _syntheticConcepts[index];
            _syntheticConcepts[index] = edit.Kind switch
            {
                SynologyPhotoRecognitionKind.ShowConcepts => completed.Contains(original.Concept.Id) ? current with { Visible = edit.Visible } : current,
                SynologyPhotoRecognitionKind.SetConceptCover => current with { Concept = current.Concept with { Thumbnail = new(edit.ConceptPhotos[0].Id.ItemId, "new") } },
                _ => current with { Concept = current.Concept with { Count = current.Concept.Count - completed.Length } },
            };
        }
        var value = new SynologyPhotoRecognitionChange(id, edit.Kind, edit.Space, unknown || partial ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed,
            null, false, false, false, ids.Length, completed, [], []) { TargetIds = edit.Concepts.Select(value => value.Concept.Id).ToArray(), PhotoIds = edit.ConceptPhotos.Select(photo => photo.Id.ItemId).ToArray(),
                RemovedPhotoIds = remove ? completed : [] };
        _recognitionChanges!.Add(value); return value;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoConceptsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        if (state == "concept-shared") await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.Subjects);
        var cover = state.StartsWith("concept-cover", StringComparison.Ordinal);
        var remove = state.StartsWith("concept-remove", StringComparison.Ordinal) || state is "concept-threshold" or "concept-safety" or "concept-confirm-cancel" or "concept-unknown" or "concept-partial" or "concept-conflict" or "concept-shared";
        var history = state.StartsWith("concept-history-", StringComparison.Ordinal); var l = Localization.LocalizationService.Current;
        if (cover || remove)
        {
            await model.OpenCollectionAsync(model.Collections[0]); typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]);
            var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0; if (remove) grid.SelectedItems.Add(grid.Items[1]);
        }
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
        var verified = false;
        try
        {
            var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
            var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoRecognitionChangesMenu" : cover ? "SetPhotoConceptCoverMenu" : remove ? "RemovePhotoConceptItemsMenu" : "ShowPhotoConceptsMenu");
            if (state == "concept-capability")
            { if (menu.Visibility != Visibility.Collapsed) throw new InvalidOperationException("缺失主题能力仍显示入口。"); more.Flyout.Hide(); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("主题原生入口不可用。");
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(180); var dialog = Dialog()!;
            var editor = Nodes(dialog).OfType<SynologyPhotoConceptEditor>().SingleOrDefault();
            if (!history && state is not ("concept-loading" or "concept-error") && editor is null) throw new InvalidOperationException("主题表单未加载。");
            if (state is "concept-empty" or "concept-loading" or "concept-error" or "concept-safety" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不可用主题表单仍可提交。");
            if (editor is not null && !cover && !remove && state != "concept-empty")
            {
                var list = Nodes(editor).OfType<ListView>().Single(); var visible = Nodes(editor).OfType<ComboBox>().Single();
                if (!Equals(visible.Items[0], l.Get("PhotosConceptShow")) || !Equals(visible.Items[1], l.Get("PhotosConceptHide"))) throw new InvalidOperationException("主题显示选项文案错误。");
                visible.SelectedIndex = state == "concept-show" ? 0 : 1; list.SelectedItems.Add(list.Items[state == "concept-show" ? 2 : 0]);
                if (state == "concept-hide") list.SelectedItems.Add(list.Items[1]);
                if (state is "concept-filtered" or "concept-keyboard")
                {
                    var search = Nodes(editor).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosFindConcepts"))); search.Text = "absent"; await Wait(() => list.Items.Count == 0);
                    if (list.Items.Count != 0 || editor.Input()?.Concepts.Count != 1) throw new InvalidOperationException("搜索丢失主题选择。");
                    if (state == "concept-keyboard")
                    {
                        search.Text = ""; await Wait(() => list.Items.Count > 0 && list.SelectedItems.Count == 1); list.UpdateLayout();
                        await Wait(() => list.ContainerFromIndex(0) is ListViewItem { IsLoaded: true });
                        if (!((ListViewItem)list.ContainerFromIndex(0)).Focus(FocusState.Keyboard)) throw new InvalidOperationException("主题列表项无法取得键盘焦点。");
                    }
                }
            }
            if (state == "concept-cancel")
            { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消主题仍写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
            if (state == "concept-cover-save")
            {
                Invoke(Button("PhotosSaveChanges")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(100); dialog = Dialog()!;
                if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.ConceptPhotos.Single().Id.ItemId != 1) throw new InvalidOperationException("主题封面目标或提交次数错误。");
            }
            if (state is "concept-show" or "concept-hide" or "concept-remove-save" or "concept-threshold" or "concept-confirm-cancel" or "concept-unknown" or "concept-partial" or "concept-shared" or "concept-conflict")
            {
                Invoke(Button("PhotosShareContinue"));
                if (state == "concept-conflict")
                { await Task.Delay(160); if (!ReferenceEquals(dialog, Dialog()) || repo.PeopleWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosEditTargetChanged"))) throw new InvalidOperationException("主题冲突没有保留草稿。"); }
                else
                {
                    await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(120); dialog = Dialog()!;
                    if (repo.PeopleWrites != 0 || Nodes(dialog).OfType<SynologyPhotoConceptEditor>().Any()) throw new InvalidOperationException("确认前已经修改主题。");
                    if (remove && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosConceptBelowThreshold"))) throw new InvalidOperationException("缺少主题隐藏风险。");
                    if (state == "concept-confirm-cancel")
                    { Invoke(Button("PhotosCancel")); await Wait(() => Dialog() is null); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消确认仍写入。"); await WriteSnapshotAsync(page, markComplete: false); verified = true; return; }
                    if (state != "concept-threshold")
                    {
                        Invoke(Button(remove ? "PhotosRemoveConceptPhotos" : state == "concept-show" ? "PhotosConceptShow" : "PhotosConceptHide"));
                        await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(150); dialog = Dialog()!;
                        if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.Space != model.SelectedSpace) throw new InvalidOperationException("主题操作未绑定原来源或提交重复。");
                        if (state == "concept-partial" && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Format("PhotosConceptPartial", 1, 2))) throw new InvalidOperationException("主题部分结果未显示。");
                        if (state == "concept-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (Button("PhotosShareContinue").IsEnabled || repo.PeopleContinues != 0) throw new InvalidOperationException("未知主题可以重放。"); }
                    }
                }
            }
            if (state == "concept-history-cold" && (repo.PeopleReviews == 0 || repo.PeopleContinues != 0 || Button("PhotosShareContinue").IsEnabled)) throw new InvalidOperationException("主题冷恢复没有只读查询。");
            if (state == "concept-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(120); if (repo.PeopleContinues != 1) throw new InvalidOperationException("主题继续未绑定原任务。"); }
            await Task.Delay(200); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("主题控件超出窗口。"); }
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
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 120 && !ready(); attempt++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("主题窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value) { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
