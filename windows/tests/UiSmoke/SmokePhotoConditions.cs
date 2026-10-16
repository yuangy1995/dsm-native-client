using System.Text.Json;
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
    private static bool ConditionFrozen => State is "cond-unfreeze" or "cond-rebuild" or "cond-partial" or "cond-safety" or "cond-history-cleanup" or "cond-history-cold" or "cond-history-cancel";
    internal int ConditionPreviews;
    private static SynologyPhotoCondition SampleCondition()
    {
        var fields = new Dictionary<string, JsonElement> { ["item_type"] = JsonSerializer.SerializeToElement(new[] { -1 }), ["person"] = JsonSerializer.SerializeToElement(new[] { 5, 6 }),
            ["keyword"] = JsonSerializer.SerializeToElement(new[] { "Synthetic keyword" }), ["keyword_policy"] = JsonSerializer.SerializeToElement("and") };
        if (State == "cond-preserved") fields["future_rule"] = JsonSerializer.SerializeToElement(new { threshold = 1.25m, values = new[] { 2, 1 } });
        return new(SynologyPhotoSpace.Personal, fields, new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>
            { ["person"] = [new("Synthetic person", JsonSerializer.SerializeToElement(5)), new(null, JsonSerializer.SerializeToElement(6))] });
    }
    public async Task<SynologyPhotoConditionSnapshot> AlbumConditionAsync(long albumId, CancellationToken cancellationToken = default)
    {
        if (State == "cond-loading") await AlbumRelease.Task;
        if (State == "cond-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return new(SyntheticAlbum(albumId), SampleCondition(), new('b', 64));
    }
    public Task<SynologyPhotoFrozenAlbum> FrozenAlbumAsync(long albumId, CancellationToken cancellationToken = default) =>
        Task.FromResult(new SynologyPhotoFrozenAlbum(SyntheticAlbum(albumId), SampleCondition(), ["recently_comment", "future_rule"], true));
    public Task<IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>> ConditionSuggestionsAsync(SynologyPhotoSpace space, string keyword, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyDictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>>(State == "cond-empty" ? new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>>() :
            new Dictionary<string, IReadOnlyList<SynologyPhotoConditionOption>> { ["person"] = [new("Synthetic suggested person", JsonSerializer.SerializeToElement(9))],
                ["focal_length_group"] = [new(null, JsonSerializer.SerializeToElement(new { start = 24, end = 70 }))] });
    public Task<int> ConditionItemCountAsync(SynologyPhotoCondition condition, CancellationToken cancellationToken = default)
    { ConditionPreviews++; return Task.FromResult(23); }
    private Task<IReadOnlyList<SynologyPhotoCollection>> ConditionFoldersAsync(long parent, int offset, int limit, SynologyPhotoSpace space) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(parent != 1 ? [] : Enumerable.Range(2, State == "cond-folder-pages" ? 101 : 1).Skip(offset).Take(limit)
            .Select(id => new SynologyPhotoCollection(id, $"Synthetic folder {id}", 1) { Space = space }).ToArray());
    private void InitializeConditionHistory()
    {
        if (!State.StartsWith("cond-history-", StringComparison.Ordinal)) return;
        var cleanup = ConditionFrozen;
        var kind = cleanup ? SynologyPhotoAlbumEditKind.Rebuild : State == "cond-history-name" ? SynologyPhotoAlbumEditKind.CreateCondition : SynologyPhotoAlbumEditKind.Condition;
        var edit = new SynologyPhotoAlbumEdit(kind) { Album = kind == SynologyPhotoAlbumEditKind.CreateCondition ? null : SyntheticAlbum(), OriginalConditionRevision = new('b', 64), ConditionSpace = SynologyPhotoSpace.Personal };
        var state = State == "cond-history-cold" ? SynologyPhotoChangeState.PendingReview : State == "cond-history-stale" ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed;
        _albumChanges!.Add(new(Guid.Parse("55555555-5555-5555-5555-555555555555"), edit, state, [], cleanup ? SyntheticAlbum(91) : null,
            state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null, false, cleanup && !State.EndsWith("cold", StringComparison.Ordinal)) { ReplacementCreated = cleanup && State != "cond-history-cold" });
    }
    private SynologyPhotoAlbumChange EditCondition(Guid id, SynologyPhotoAlbumEdit edit, int old)
    {
        if (old >= 0)
        {
            if (State == "cond-history-name" && edit.Name != "Synthetic condition album") throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            return _albumChanges![old] = _albumChanges[old] with { Edit = edit, CanContinue = true };
        }
        AlbumWrites++; SubmittedAlbum = edit;
        var state = State == "cond-unknown" ? SynologyPhotoChangeState.PendingReview : State == "cond-partial" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed;
        var result = SyntheticAlbum(edit.Kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild ? 91 : 41) with { Name = edit.Name ?? SyntheticAlbum().Name, Frozen = false, Conditional = edit.Kind != SynologyPhotoAlbumEditKind.Unfreeze };
        var change = new SynologyPhotoAlbumChange(id, edit, state, [], state == SynologyPhotoChangeState.PendingReview ? null : result,
            state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null, false, state == SynologyPhotoChangeState.Failed) { ReplacementCreated = edit.Kind == SynologyPhotoAlbumEditKind.Rebuild && state != SynologyPhotoChangeState.PendingReview };
        _albumChanges!.Add(change); return change;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoConditionsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        var l = Localization.LocalizationService.Current; var history = state.StartsWith("cond-history-", StringComparison.Ordinal);
        await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        if (!history) await model.OpenCollectionAsync(model.Collections[0]);
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
        ComboBox Combo(string key) => Nodes(Dialog()!).OfType<ComboBox>().Single(box => Equals(box.Header, l.Get(key)));
        TextBox Text(string key) => Nodes(Dialog()!).OfType<TextBox>().Single(box => Equals(box.Header, l.Get(key)));
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        if (state == "cond-safety")
        {
            if (((MenuFlyoutItem)page.FindName("UnfreezeAlbumMenu")).IsEnabled || ((MenuFlyoutItem)page.FindName("RebuildAlbumMenu")).IsEnabled) throw new InvalidOperationException("冻结相册专项保护失效。");
            more.Flyout.Hide(); await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
        }
        var menuName = history ? "PhotoAlbumChangesMenu" : state is "cond-unfreeze" ? "UnfreezeAlbumMenu" : state is "cond-rebuild" or "cond-partial" ? "RebuildAlbumMenu" :
            state is "cond-create" or "cond-submit" or "cond-cancel" ? "CreateConditionAlbumMenu" : "EditConditionAlbumMenu";
        var menu = (MenuFlyoutItem)page.FindName(menuName);
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("条件相册菜单不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        try
        {
            await Task.Delay(300); var dialog = Dialog() ?? throw new InvalidOperationException("没有打开条件相册窗口。");
            if (state is "cond-loading" or "cond-error" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未读取规则时仍能提交。");
            if (state is "cond-history-name" or "cond-history-resume" or "cond-history-cleanup")
            {
                Invoke(Button("PhotosAlbumContinue"));
                for (var attempt = 0; attempt < 100 && (Dialog() is null || Equals(Dialog()?.Title, l.Get("PhotosAlbumChanges"))); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("条件恢复缺少确认窗口。");
                for (var attempt = 0; attempt < 100 && (!dialog.IsLoaded || dialog.ActualWidth == 0); attempt++) await Task.Delay(30);
                if (repo.AlbumContinues != 0) throw new InvalidOperationException("条件恢复未经确认就提交。");
                if (state == "cond-history-cleanup" && Nodes(dialog).OfType<SynologyPhotoConditionEditor>().Any()) throw new InvalidOperationException("已有新相册却重新创建条件。");
            }
            var editor = Nodes(dialog).OfType<SynologyPhotoConditionEditor>().SingleOrDefault();
            if (state is not ("cond-loading" or "cond-error" or "cond-unfreeze" or "cond-history-cleanup" or "cond-history-cold" or "cond-history-stale" or "cond-history-cancel") && editor is null)
                throw new InvalidOperationException("条件编辑器没有成功加载。");
            if (state is "cond-create" or "cond-submit" or "cond-history-name")
            {
                if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空名称可以提交。");
                if (state == "cond-history-name")
                {
                    Text("PhotosAlbumName").Text = "Wrong synthetic name"; await Task.Delay(100);
                    Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText))); await Task.Delay(100);
                    if (repo.AlbumContinues != 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosConditionIntentMismatch"))) throw new InvalidOperationException("冷恢复没有要求保持原意图。");
                }
                Text("PhotosAlbumName").Text = "Synthetic condition album";
            }
            if (state == "cond-preview")
            {
                Invoke(Button("PhotosConditionPreview")); await Task.Delay(100);
                if (repo.ConditionPreviews != 1 || repo.AlbumWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Format("PhotosConditionCount", 23))) throw new InvalidOperationException("条件预览没有保持只读。");
            }
            if (state == "cond-keyword")
            {
                Combo("PhotosConditionMatch").SelectedIndex = 1; Text("PhotosConditionSearch").Text = "Second synthetic keyword"; await Task.Delay(100); Invoke(Button("PhotosConditionAdd"));
                if (editor!.Build().Fields["keyword"].GetArrayLength() != 2 || editor.Build().Fields["keyword_policy"].GetString() != "and") throw new InvalidOperationException("关键词或匹配策略丢失。");
            }
            if (state is "cond-suggest" or "cond-empty")
            {
                Combo("PhotosConditionField").SelectedIndex = 1; Invoke(Button("PhotosConditionFind")); await Task.Delay(100);
                var list = Nodes(editor!).OfType<ListView>().Single(view => view.DisplayMemberPath != nameof(SynologyPhotoCollection.Name));
                if (state == "cond-empty")
                { if (list.Items.Count != 0 || Button("PhotosConditionAdd").IsEnabled || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosConditionNoSuggestions"))) throw new InvalidOperationException("空建议缺少提示。"); }
                else
                {
                    list.SelectedIndex = 0; Invoke(Button("PhotosConditionAdd"));
                    Combo("PhotosConditionField").SelectedIndex = 9; list.SelectedIndex = 0; Invoke(Button("PhotosConditionAdd"));
                    if (editor!.Build().Fields["person"].GetArrayLength() != 3 || editor.Build().Fields["focal_length_group"][0].GetProperty("end").GetInt32() != 70) throw new InvalidOperationException("建议引用或范围失真。");
                }
            }
            if (state is "cond-refs" or "cond-preserved")
            {
                if (!Nodes(editor!).OfType<TextBlock>().Any(text => text.Text.Contains(l.Format("PhotosConditionSavedItem", 6), StringComparison.Ordinal))) throw new InvalidOperationException("无名称引用被丢弃。");
                if (state == "cond-preserved" && (Combo("PhotosChooseSource").IsEnabled || !editor!.Build().Fields.ContainsKey("future_rule"))) throw new InvalidOperationException("未知规则没有完整保留。");
            }
            if (state == "cond-source")
            {
                Combo("PhotosChooseSource").SelectedIndex = 1;
                if (editor!.Build().Space != SynologyPhotoSpace.Shared || editor.Build().Fields.ContainsKey("person") || !editor.Build().Fields.ContainsKey("keyword")) throw new InvalidOperationException("来源切换混用引用或丢失关键词。");
            }
            if (state == "cond-folder-pages")
            {
                Nodes(editor!).OfType<Expander>().Single(value => Equals(value.Header, l.Get("PhotosLibraryFolders"))).IsExpanded = true; await Task.Delay(200);
                Invoke(Button("PhotosLoadOlder")); await Task.Delay(100);
                var folders = Nodes(editor!).OfType<ListView>().Single(view => view.DisplayMemberPath == nameof(SynologyPhotoCollection.Name));
                if (folders.Items.Count != 101) throw new InvalidOperationException("条件目录选择未完整分页。");
                folders.SelectedIndex = 100; Invoke(Button("PhotosOpenFolder")); await Task.Delay(100); Invoke(Button("PhotosConditionUseFolder"));
                if (editor!.Build().Fields["folder_filter"][0].GetInt32() != 102) throw new InvalidOperationException("条件目录没有绑定所选目标。");
            }
            if (state == "cond-date")
            {
                Nodes(editor!).OfType<Expander>().Single(value => Equals(value.Header, l.Get("PhotosFilterDate"))).IsExpanded = true; await Task.Delay(100);
                Nodes(editor!).OfType<CheckBox>().Single(box => Equals(box.Content, l.Get("PhotosDateFrom"))).IsChecked = true;
                Nodes(editor!).OfType<CheckBox>().Single(box => Equals(box.Content, l.Get("PhotosDateTo"))).IsChecked = true;
                var pickers = Nodes(editor!).OfType<CalendarDatePicker>().ToArray(); pickers[0].Date = new(2026, 9, 2, 0, 0, 0, TimeSpan.Zero); pickers[1].Date = new(2026, 9, 1, 0, 0, 0, TimeSpan.Zero); await Task.Delay(100);
                if (dialog.IsPrimaryButtonEnabled || editor!.Valid) throw new InvalidOperationException("无效日期范围可以提交。");
                pickers[1].Date = new(2026, 9, 3, 0, 0, 0, TimeSpan.Zero); await Task.Delay(100);
                if (!dialog.IsPrimaryButtonEnabled || !editor.Valid) throw new InvalidOperationException("有效日期范围无法恢复。");
            }
            await Task.Delay(100);
            if (state is "cond-submit" or "cond-unfreeze" or "cond-rebuild" or "cond-unknown" or "cond-partial" or "cond-history-name" or "cond-history-resume" or "cond-history-cleanup")
            {
                if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效条件相册表单无法提交。");
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosAlbumChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("条件提交后缺少操作记录。"); await Task.Delay(100);
                if (history ? repo.AlbumContinues != 1 || repo.AlbumWrites != 0 : repo.AlbumWrites != 1) throw new InvalidOperationException("条件操作重复提交或恢复错阶段。");
                if (state == "cond-unknown")
                { var reads = repo.AlbumReviews; Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (repo.AlbumReviews <= reads || repo.AlbumWrites != 1 || Button("PhotosAlbumContinue").IsEnabled) throw new InvalidOperationException("条件未知结果自动重发。"); }
                if (state == "cond-partial" && (model.CurrentAlbum?.Id != 41 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosConditionBothKept")))) throw new InvalidOperationException("重建部分完成错误替换旧相册。");
            }
            if (state == "cond-history-cold" && (repo.AlbumReviews < 1 || repo.AlbumWrites != 0 || repo.AlbumContinues != 0 || !(await repo.AlbumChangesAsync()).Single().ReplacementCreated)) throw new InvalidOperationException("重建冷恢复没有保持只读。");
            if (state == "cond-history-stale" && (repo.AlbumWrites != 0 || repo.AlbumReviews != 0)) throw new InvalidOperationException("历史结果被重新执行。");
            if (state == "cond-history-cancel")
            { Invoke(Button("PhotosAlbumCancel")); await Task.Delay(100); if ((await repo.AlbumChangesAsync()).Single().State != SynologyPhotoChangeState.Cancelled || repo.AlbumContinues != 0 || repo.AlbumWrites != 0) throw new InvalidOperationException("取消错误删除相册。"); }
            if (state == "cond-cancel")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.CloseButtonText)));
                for (var attempt = 0; attempt < 100 && Dialog() is not null; attempt++) await Task.Delay(30);
                if (Dialog() is not null || repo.AlbumWrites != 0) throw new InvalidOperationException("取消条件表单仍有提交。");
                await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
            }
            // 展示长表单的当前操作位置，避免仅截到滚动区首屏。
            if (state is "cond-preview" or "cond-keyword" or "cond-suggest" or "cond-empty" or "cond-refs")
            { ((ScrollViewer)dialog.Content).ChangeView(null, ((ScrollViewer)dialog.Content).ScrollableHeight, null, true); }
            await Task.Delay(500); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("条件窗口未继承主题或布局。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("条件控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.AlbumRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
