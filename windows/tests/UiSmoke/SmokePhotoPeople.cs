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
    public bool SupportsRecognitionManagement => State.StartsWith("sim-", StringComparison.Ordinal) || State.StartsWith("ppl-", StringComparison.Ordinal) || State.StartsWith("face-", StringComparison.Ordinal) || State.StartsWith("manual-", StringComparison.Ordinal) || State.StartsWith("concept-", StringComparison.Ordinal);
    public SynologyPhotoRecognitionSafety RecognitionSafety => new(State != "ppl-safety", State is not ("face-safety" or "manual-safety"), State != "concept-safety", State != "sim-safety");
    internal readonly TaskCompletionSource PeopleRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int PeopleWrites, PeopleReviews, PeopleContinues, PeopleCancels;
    internal SynologyPhotoRecognitionEdit? SubmittedPeople;
    private List<SynologyPhotoRecognitionChange>? _recognitionChanges;
    private readonly List<SynologyPhotoPerson> _syntheticPeople =
    [new(new(11, "Synthetic Alice", Count: 8) { Thumbnail = new(11, "synthetic") { Type = SynologyPhotoThumbnailType.Person, NativeSize = true } }, true),
        new(new(12, "Synthetic Bob", Count: 6), true), new(new(13, "", Count: 2), false)];
    public async Task<IReadOnlyList<SynologyPhotoPerson>> PeopleAsync(SynologyPhotoSpace space, bool includeHidden, CancellationToken cancellationToken = default)
    {
        if (State == "ppl-loading") await PeopleRelease.Task;
        if (State is "ppl-error" or "ppl-history-input-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return State == "ppl-empty" ? [] : _syntheticPeople.Where(person => includeHidden || person.Visible == true)
            .Select(person => person with { Person = person.Person with { Space = space } }).ToArray();
    }
    public Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category, int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>((category == SynologyPhotoCategory.Subjects ? _syntheticConcepts.Where(value => value.AppearsInList).Select(value => value.Concept) : _syntheticPeople.Where(person => person.Visible == true).Select(person => person.Person))
            .Skip(offset).Take(limit).Select(value => value with { Space = space }).ToArray());
    public Task<byte[]> CategoryImageAsync(SynologyPhotoCategory category, SynologyPhotoCollection item, CancellationToken cancellationToken = default) =>
        ThumbnailAsync(new(new(ProfileId, item.Space, 1), "synthetic.png", 1, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, 1, "photo"), cancellationToken: cancellationToken);
    public Task PrepareRecognitionAsync(SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default) =>
        State is "manual-conflict" or "concept-conflict" or "sim-conflict" ? Task.FromException(new SynologyPhotoException(SynologyPhotoFailure.TargetChanged)) : Task.CompletedTask;
    public async Task<SynologyPhotoRecognitionChange> EditRecognitionAsync(Guid operationId, SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default)
    {
        await RecognitionChangesAsync(); PeopleWrites++; SubmittedPeople = edit;
        if (State.StartsWith("sim-", StringComparison.Ordinal)) return SaveSyntheticSimilar(operationId, edit);
        if (State.StartsWith("concept-", StringComparison.Ordinal)) return SaveSyntheticConcept(operationId, edit);
        if (State.StartsWith("manual-", StringComparison.Ordinal)) return SaveSyntheticManual(operationId, edit);
        if (State.StartsWith("face-", StringComparison.Ordinal)) return SaveSyntheticFaces(operationId, edit);
        var unknown = State == "ppl-rename-unknown"; var partial = State == "ppl-partial"; var ids = edit.People.Select(person => person.Person.Id).ToArray();
        var updated = edit.People.Take(partial ? 1 : 100).Select(person => edit.Kind == SynologyPhotoRecognitionKind.ShowPeople ? person with { Visible = edit.Visible } : person with { Person = person.Person with { Name = edit.Name! } }).ToArray();
        if (!unknown) foreach (var person in updated) { var index = _syntheticPeople.FindIndex(value => value.Person.Id == person.Person.Id); if (index >= 0) _syntheticPeople[index] = person; }
        var removed = edit.Kind == SynologyPhotoRecognitionKind.MergePeople ? ids.Skip(1).ToArray() : [];
        foreach (var id in removed) _syntheticPeople.RemoveAll(person => person.Person.Id == id);
        var change = new SynologyPhotoRecognitionChange(operationId, edit.Kind, edit.Space, unknown || partial ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed,
            null, false, false, false, ids.Length, unknown ? [] : partial ? ids.Take(1).ToArray() : ids, unknown ? [] : updated, removed) { TargetIds = ids };
        _recognitionChanges!.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoRecognitionChange>> RecognitionChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_recognitionChanges is null)
        {
            _recognitionChanges = [];
            if (State.StartsWith("sim-history-", StringComparison.Ordinal))
            {
                var pending = State == "sim-history-cold"; var id = Guid.Parse("94949494-9494-9494-9494-949494949494"); var status = pending ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Ready;
                _recognitionChanges.Add(new(id, SynologyPhotoRecognitionKind.SimilarUngroup, SynologyPhotoSpace.Personal, status, null, false, !pending, false, 1, [], [], [])
                { TargetIds = [11], SimilarGroups = [new(Guid.NewGuid(), 11, status, null, pending)] });
            }
            if (State.StartsWith("concept-history-", StringComparison.Ordinal))
                _recognitionChanges.Add(new(Guid.Parse("96969696-9696-9696-9696-969696969696"), SynologyPhotoRecognitionKind.ShowConcepts, SynologyPhotoSpace.Personal,
                    State == "concept-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false, State == "concept-history-resume", false, 1, [], [], []) { TargetIds = [11] });
            if (State.StartsWith("manual-history-", StringComparison.Ordinal))
                _recognitionChanges.Add(new(Guid.Parse("96969696-9696-9696-9696-969696969696"), SynologyPhotoRecognitionKind.ManualFaces,
                    SynologyPhotoSpace.Personal, State == "manual-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed,
                    null, false, false, State == "manual-history-input", 2, [], [], []) { PhotoIds = [1] });
            if (State.StartsWith("face-history-", StringComparison.Ordinal))
                _recognitionChanges.Add(new(Guid.Parse("97979797-9797-9797-9797-979797979797"), State == "face-history-resume" ? SynologyPhotoRecognitionKind.RemovePersonFaces : SynologyPhotoRecognitionKind.ReassignPersonFaces,
                    SynologyPhotoSpace.Personal, State == "face-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false,
                    State == "face-history-resume", State == "face-history-input", 1, [], [], []) { TargetIds = [11], PhotoIds = [1] });
            if (State.StartsWith("ppl-history-", StringComparison.Ordinal) && State != "ppl-history-empty")
                _recognitionChanges.Add(new(Guid.Parse("98989898-9898-9898-9898-989898989898"), State == "ppl-history-resume" ? SynologyPhotoRecognitionKind.ShowPeople : SynologyPhotoRecognitionKind.RenamePerson,
                    SynologyPhotoSpace.Personal, State == "ppl-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false,
                    State == "ppl-history-resume", State is "ppl-history-input" or "ppl-history-input-error", 1, [], [], []) { TargetIds = [11] });
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoRecognitionChange>>(_recognitionChanges.ToArray());
    }
    public async Task<SynologyPhotoRecognitionChange> ReviewRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    { await RecognitionChangesAsync(); PeopleReviews++; return _recognitionChanges!.Single(value => value.Id == operationId); }
    public async Task<SynologyPhotoRecognitionChange> ContinueRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await RecognitionChangesAsync(); PeopleContinues++; var index = _recognitionChanges!.FindIndex(value => value.Id == operationId);
        return _recognitionChanges[index] = _recognitionChanges[index] with { State = SynologyPhotoChangeState.Completed, CompletedIds = [11], CanContinue = false };
    }
    public async Task<SynologyPhotoRecognitionChange> CancelRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await RecognitionChangesAsync(); PeopleCancels++; var index = _recognitionChanges!.FindIndex(value => value.Id == operationId);
        return _recognitionChanges[index] = _recognitionChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false, NeedsInput = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoPeopleAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        if (state == "ppl-shared") await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.People);
        var l = Localization.LocalizationService.Current; var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0; await Task.Delay(300);
        if (state == "ppl-cover")
        {
            // 封面由可见卡片异步加载；等待实际图像，不能把固定短延时当成完成信号。
            for (var attempt = 0; attempt < 100 && !Nodes(grid).OfType<Image>().Any(image => image.Source is not null); attempt++)
                await Task.Delay(30);
            if (!Nodes(grid).OfType<Image>().Any(image => image.Source is not null)) throw new InvalidOperationException("人物封面没有显示。");
            await WriteSnapshotAsync(page); return;
        }
        var history = state.StartsWith("ppl-history-", StringComparison.Ordinal);
        var merge = state.StartsWith("ppl-merge", StringComparison.Ordinal) || state is "ppl-safety" or "ppl-confirm-cancel";
        var rename = state.StartsWith("ppl-rename", StringComparison.Ordinal) || state is "ppl-clear" or "ppl-shared" or "ppl-cancel";
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoRecognitionChangesMenu" : merge ? "MergePhotoPeopleMenu" : rename ? "RenamePhotoPersonMenu" : "ShowPhotoPeopleMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("人物原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        await Wait(() => Dialog()?.IsLoaded == true); await Task.Delay(120); var dialog = Dialog()!;
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        TextBox Text(string key) => Nodes(Dialog()!).OfType<TextBox>().Single(value => Equals(value.Header, l.Get(key)));
        try
        {
            var editor = Nodes(dialog).OfType<SynologyPhotoPeopleEditor>().SingleOrDefault();
            if (!history && state is not ("ppl-loading" or "ppl-error") && editor is null) throw new InvalidOperationException("人物表单未加载。");
            if (state is "ppl-loading" or "ppl-error" or "ppl-empty" or "ppl-safety" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不可用表单仍可提交。");
            if (rename) { Text("PhotosPersonName").Text = state == "ppl-clear" ? "" : "  Synthetic name  "; if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("姓名输入没有启用保存。"); }
            if (editor is not null && !rename && state is not ("ppl-empty" or "ppl-safety"))
            {
                var list = Nodes(editor).OfType<ListView>().Single();
                if (!merge) Nodes(editor).OfType<ComboBox>().Single().SelectedIndex = 1;
                list.SelectedIndex = 0; if (state == "ppl-partial") list.SelectedItems.Add(list.Items[1]);
                if (state == "ppl-filter")
                {
                    Text("PhotosFindPeople").Text = "absent"; await Task.Delay(80);
                    if (list.Items.Count != 0 || editor.Input()?.People.Count != 1 || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("人物搜索丢失选择。");
                    Text("PhotosFindPeople").Text = ""; await Wait(() => list.Items.Count > 0);
                    if (list.SelectedItems.Count != 1) throw new InvalidOperationException("清空搜索丢失选择。");
                    Text("PhotosFindPeople").Text = "absent";
                }
            }
            if (state is "ppl-rename-submit" or "ppl-rename-unknown" or "ppl-clear")
            {
                Invoke(Button("PhotosSaveChanges")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(120); dialog = Dialog()!;
                if (repo.PeopleWrites != 1 || repo.SubmittedPeople?.Name != (state == "ppl-clear" ? "" : "  Synthetic name  ")) throw new InvalidOperationException("姓名保存丢失原输入。");
                if (state == "ppl-rename-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (repo.PeopleContinues != 0 || Button("PhotosShareContinue").IsEnabled) throw new InvalidOperationException("未知人物操作可以重放。"); }
            }
            if (state is "ppl-merge-confirm" or "ppl-merge-submit" or "ppl-hide-submit" or "ppl-partial" or "ppl-confirm-cancel")
            {
                Invoke(Button("PhotosShareContinue")); await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(120); dialog = Dialog()!;
                if (repo.PeopleWrites != 0 || Nodes(dialog).OfType<SynologyPhotoPeopleEditor>().Any()) throw new InvalidOperationException("人物确认前已经写入。");
                if (merge && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosPeopleMergeRisk"))) throw new InvalidOperationException("缺少合并风险说明。");
                if (state == "ppl-confirm-cancel") { Invoke(Button("PhotosCancel")); await Task.Delay(160); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消合并仍写入。"); await WriteSnapshotAsync(page); return; }
                if (state != "ppl-merge-confirm")
                {
                    Invoke(Button(merge ? "PhotosMergePeople" : "PhotosPeopleHide")); await Wait(() => Equals(Dialog()?.Title, l.Get("PhotosRecognitionChanges"))); await Task.Delay(120); dialog = Dialog()!;
                    if (repo.PeopleWrites != 1) throw new InvalidOperationException("人物操作未提交一次。");
                    if (state == "ppl-partial" && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Format("PhotosPeoplePartial", 1, 2))) throw new InvalidOperationException("部分结果未保留。");
                    if (state == "ppl-merge-submit" && model.Collections.Any(value => value.Id == 12)) throw new InvalidOperationException("合并来源卡片未更新。");
                }
            }
            if (state == "ppl-history-cold" && (repo.PeopleReviews == 0 || repo.PeopleContinues != 0)) throw new InvalidOperationException("冷恢复未保持只读。");
            if (state == "ppl-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(120); if (repo.PeopleContinues != 1) throw new InvalidOperationException("继续没有绑定原任务。"); }
            if (state == "ppl-history-input")
            {
                Invoke(Button("PhotosShareEditAgain")); await Wait(() => Dialog() is { IsLoaded: true } next && !ReferenceEquals(next, dialog)); await Task.Delay(120); dialog = Dialog()!;
                if (repo.PeopleCancels != 1 || repo.PeopleWrites != 0 || !Nodes(dialog).OfType<SynologyPhotoPeopleEditor>().Any()) throw new InvalidOperationException("重新输入未先结束旧任务。");
            }
            if (state == "ppl-history-input-error")
            {
                Invoke(Button("PhotosShareEditAgain")); await Task.Delay(120);
                if (!Button("PhotosShareEditAgain").IsEnabled || !Button("PhotosShareStop").IsEnabled || repo.PeopleCancels != 0 || repo.PeopleWrites != 0 ||
                    !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosEditPermission"))) throw new InvalidOperationException("重新输入读取失败后不能恢复。");
            }
            if (state == "ppl-cancel") { Invoke(Button("PhotosCancel")); await Task.Delay(160); if (repo.PeopleWrites != 0) throw new InvalidOperationException("取消姓名仍写入。"); await WriteSnapshotAsync(page); return; }
            await Task.Delay(400); dialog.UpdateLayout();
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("人物控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.PeopleRelease.TrySetResult(); Dialog()?.Hide(); }
        static async Task Wait(Func<bool> ready) { for (var attempt = 0; attempt < 100 && !ready(); attempt++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("人物窗口未就绪。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
