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
    public bool SupportsAlbumManagement => State.StartsWith("alb-", StringComparison.Ordinal) || State.StartsWith("cond-", StringComparison.Ordinal) || State.StartsWith("shr-", StringComparison.Ordinal) || State.StartsWith("tmp-", StringComparison.Ordinal) || State.StartsWith("req-", StringComparison.Ordinal);
    public SynologyPhotoAlbumSafety AlbumSafety => State is "alb-safety" or "cond-safety" ? new() : new(true, State.StartsWith("cond-", StringComparison.Ordinal), State.StartsWith("cond-", StringComparison.Ordinal));
    internal bool EditingAlbums;
    internal int AlbumWrites, AlbumReviews, AlbumContinues;
    internal SynologyPhotoAlbumEdit? SubmittedAlbum;
    internal readonly TaskCompletionSource AlbumRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private List<SynologyPhotoAlbumChange>? _albumChanges;
    private SynologyPhotoAlbum SyntheticAlbum(long id = 41) => new(id, 19, 19, "Synthetic shared album", State.StartsWith("cond-", StringComparison.Ordinal), id == 41 && ConditionFrozen, new('a', 64))
        { ProfileId = ProfileId, CanContribute = true, Sort = new(SynologyPhotoSortField.TakenTime), Shared = false, ItemCount = 8 };
    public async Task<SynologyPhotoAlbum> AlbumAsync(long id, CancellationToken cancellationToken = default)
    {
        if (EditingAlbums && State == "alb-loading") await AlbumRelease.Task;
        if (EditingAlbums && State == "alb-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SyntheticAlbum(id);
    }
    public Task<SynologyPhotoAlbumListSort> AlbumListSortAsync(SynologyPhotoAlbumListScope scope, CancellationToken cancellationToken = default) =>
        Task.FromResult(new SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField.Name));
    public Task<SynologyPhotoAlbumDisplay> AlbumDisplayAsync(CancellationToken cancellationToken = default) => Task.FromResult(SynologyPhotoAlbumDisplay.All);
    public Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, SynologyPhotoAlbumDisplay display, SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default) => AlbumsAsync(offset, limit, cancellationToken);
    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoSharedEntry>>(offset == 0 ? [new("synthetic", "Synthetic shared album", 41)] : []);
    private Task<IReadOnlyList<SynologyPhotoCollection>> AlbumTargetsAsync(int offset, int limit) => Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(
        State == "alb-empty" ? [] : Enumerable.Range(41, State == "alb-pages" ? 101 : 1).Skip(offset).Take(limit).Select(id => new SynologyPhotoCollection(id, $"Synthetic album {id}")).ToArray());
    public Task PrepareAlbumAsync(SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public async Task<SynologyPhotoAlbumChange> EditAlbumAsync(Guid operationId, SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default)
    {
        await AlbumChangesAsync(); var old = _albumChanges!.FindIndex(change => change.Id == operationId);
        if (State.StartsWith("cond-", StringComparison.Ordinal)) return EditCondition(operationId, edit, old);
        if (old >= 0 && State == "alb-history-name" && edit.Name != "Synthetic renamed album") throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (old >= 0) return _albumChanges[old] = _albumChanges[old] with { Edit = edit, CanContinue = true };
        AlbumWrites++; SubmittedAlbum = edit;
        var state = State is "alb-unknown" or "req-album-unknown" ? SynologyPhotoChangeState.PendingReview : State == "alb-partial" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed;
        var result = (edit.Album ?? SyntheticAlbum(91)) with { Name = edit.Name ?? edit.Album?.Name ?? "Synthetic album", Sort = edit.Sort ?? edit.Album?.Sort };
        var change = new SynologyPhotoAlbumChange(operationId, edit, state, edit.Photos.Select((photo, index) => new SynologyPhotoAlbumMemberChange(photo,
            state == SynologyPhotoChangeState.PendingReview ? state : State == "alb-partial" && index > 0 ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed)).ToArray(),
            state == SynologyPhotoChangeState.Completed ? result : null, state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null, false, state == SynologyPhotoChangeState.Failed);
        _albumChanges.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoAlbumChange>> AlbumChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_albumChanges is null)
        {
            _albumChanges = [];
            InitializeConditionHistory();
            if (State is "alb-history-resume" or "alb-history-name" or "alb-history-cold" or "alb-history-stale" or "alb-history-cancel")
            {
                var kind = State == "alb-history-name" ? SynologyPhotoAlbumEditKind.Rename : SynologyPhotoAlbumEditKind.Sort;
                var edit = new SynologyPhotoAlbumEdit(kind) { Album = SyntheticAlbum(), Sort = kind == SynologyPhotoAlbumEditKind.Sort ? new(SynologyPhotoSortField.Filename, true) : null };
                var state = State == "alb-history-cold" ? SynologyPhotoChangeState.PendingReview : State == "alb-history-stale" ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed;
                _albumChanges.Add(new(Guid.Parse("44444444-4444-4444-4444-444444444444"), edit, state, [], null, state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null,
                    false, State is "alb-history-resume" or "alb-history-cancel"));
            }
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoAlbumChange>>(_albumChanges.ToArray());
    }
    public async Task<SynologyPhotoAlbumChange> ReviewAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await AlbumChangesAsync(); AlbumReviews++; var index = _albumChanges!.FindIndex(change => change.Id == operationId);
        if (State == "cond-history-cold") _albumChanges[index] = _albumChanges[index] with { State = SynologyPhotoChangeState.Ready, ReplacementCreated = true, CanContinue = true, Result = SyntheticAlbum(91) };
        if (State == "alb-history-cold") _albumChanges[index] = _albumChanges[index] with { State = SynologyPhotoChangeState.Completed, Result = SyntheticAlbum() with { Sort = new(SynologyPhotoSortField.Filename, true) } };
        return _albumChanges[index];
    }
    public async Task<SynologyPhotoAlbumChange> ContinueAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await AlbumChangesAsync(); AlbumContinues++; var index = _albumChanges!.FindIndex(change => change.Id == operationId);
        return _albumChanges[index] = _albumChanges[index] with { State = SynologyPhotoChangeState.Completed, CanContinue = false, Result = SyntheticAlbum(_albumChanges[index].ReplacementCreated ? 91 : 41) with { Name = _albumChanges[index].Edit.Name ?? SyntheticAlbum().Name } };
    }
    public async Task<SynologyPhotoAlbumChange> CancelAlbumChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await AlbumChangesAsync(); var index = _albumChanges!.FindIndex(change => change.Id == operationId);
        return _albumChanges[index] = _albumChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoAlbumsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        if (state == "alb-shared-sort") await model.SelectSectionAsync(SynologyPhotosSection.Sharing);
        var opened = state is "alb-remove" or "alb-cover" or "alb-sort" or "alb-partial" or "alb-unknown";
        if (opened) await model.OpenCollectionAsync(model.Collections[0]);
        repo.EditingAlbums = true; var l = Localization.LocalizationService.Current;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var history = state.StartsWith("alb-history-", StringComparison.Ordinal);
        var adding = state is "alb-add" or "alb-pages" or "alb-empty";
        if (adding) await model.SelectSectionAsync(SynologyPhotosSection.Timeline);
        if (adding || state is "alb-remove" or "alb-cover" or "alb-partial" or "alb-unknown")
        {
            typeof(SynologyPhotosPage).GetMethod("SetPhotoSelection", flags)!.Invoke(page, [true]);
            var grid = (GridView)page.FindName("LibraryGrid");
            foreach (var cell in grid.Items.OfType<SynologyPhotoCell>().Where(cell => cell.Photo is not null).Take(state == "alb-partial" ? 2 : 1)) grid.SelectedItems.Add(cell);
        }
        else if (state is "alb-rename" or "alb-delete" or "alb-loading" or "alb-error" or "alb-safety")
        { var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedItem = grid.Items.OfType<SynologyPhotoCell>().First(cell => cell.Collection is not null); }
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        if (state == "alb-safety")
        {
            if (((MenuFlyoutItem)page.FindName("DeletePhotoAlbumMenu")).IsEnabled) throw new InvalidOperationException("相册删除专项保护失效。");
            more.Flyout.Hide(); await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
        }
        var menuName = history ? "PhotoAlbumChangesMenu" : adding ? "AddPhotoAlbumMenu" : state switch
        {
            "alb-rename" or "alb-loading" or "alb-error" => "RenamePhotoAlbumMenu", "alb-delete" => "DeletePhotoAlbumMenu", "alb-remove" or "alb-partial" or "alb-unknown" => "RemovePhotoAlbumMenu",
            "alb-cover" => "CoverPhotoAlbumMenu", "alb-sort" => "SortPhotoAlbumMenu", "alb-list-sort" or "alb-shared-sort" => "SortAlbumListMenu", "alb-display" => "AlbumDisplayMenu", _ => "CreatePhotoAlbumMenu",
        };
        var menu = (MenuFlyoutItem)page.FindName(menuName);
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("相册菜单不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        try
        {
            await Task.Delay(300); var dialog = Dialog() ?? throw new InvalidOperationException("相册菜单没有打开窗口。");
            if (adding)
            {
                var albums = Nodes(dialog).OfType<ListView>().Single(list => list.DisplayMemberPath == nameof(SynologyPhotoCollection.Name));
                if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未选择相册时可提交。");
                if (state == "alb-pages") { Invoke(Button("PhotosLoadOlder")); await Task.Delay(100); if (albums.Items.Count != 101) throw new InvalidOperationException("相册目标未完整分页。"); }
                if (state != "alb-empty") { albums.SelectedItem = albums.Items[^1]; await Task.Delay(100); if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("相册选择未生效。"); }
            }
            if (state is "alb-loading" or "alb-error" or "alb-empty" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未完成准备时仍能提交。");
            if (state is "alb-history-resume" or "alb-history-name")
            {
                Invoke(Button("PhotosAlbumContinue"));
                for (var attempt = 0; attempt < 100 && (Dialog() is null || Equals(Dialog()?.Title, l.Get("PhotosAlbumChanges"))); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("继续没有确认窗口。");
                for (var attempt = 0; attempt < 100 && (!dialog.IsLoaded || dialog.ActualWidth == 0); attempt++) await Task.Delay(30);
                if (repo.AlbumContinues != 0) throw new InvalidOperationException("相册任务未经确认就继续。");
                if (state == "alb-history-name" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("冷恢复没有要求输入原名称。");
            }
            if (state == "alb-history-name")
            {
                Nodes(dialog).OfType<TextBox>().Single(box => Equals(box.Header, l.Get("PhotosAlbumName"))).Text = "Wrong synthetic name"; await Task.Delay(100);
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText))); await Task.Delay(100);
                if (repo.AlbumContinues != 0 || repo.AlbumWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(text => text.Text == l.Get("PhotosAlbumNameMismatch"))) throw new InvalidOperationException("原名称不一致没有明确恢复提示。");
            }
            if (state is "alb-create" or "alb-rename" or "alb-history-name") Nodes(dialog).OfType<TextBox>().Single(box => Equals(box.Header, l.Get("PhotosAlbumName"))).Text = "Synthetic renamed album";
            if (state is "alb-sort" or "alb-list-sort" or "alb-shared-sort")
            { Nodes(dialog).OfType<ComboBox>().Single(box => Equals(box.Header, l.Get("PhotosSortBy"))).SelectedIndex = 1; Nodes(dialog).OfType<ComboBox>().Single(box => Equals(box.Header, l.Get("PhotosSortDirection"))).SelectedIndex = 1; }
            if (state == "alb-display") Nodes(dialog).OfType<ComboBox>().Single(box => Equals(box.Header, l.Get("PhotosAlbumDisplay"))).SelectedIndex = 1;
            // TextBox.TextChanged 在 WinUI 消息队列中派发，等待表单实际重算按钮状态。
            await Task.Delay(100);
            if (state is "alb-create" or "alb-rename" or "alb-delete" or "alb-add" or "alb-remove" or "alb-cover" or "alb-sort" or "alb-list-sort" or "alb-shared-sort" or "alb-display" or "alb-partial" or "alb-unknown" or "alb-history-resume" or "alb-history-name")
            {
                if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("有效相册操作不能提交。");
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.PrimaryButtonText)));
                for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosAlbumChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("相册提交后没有操作记录。"); await Task.Delay(100);
                if (state is "alb-history-resume" or "alb-history-name" ? repo.AlbumContinues != 1 || repo.AlbumWrites != 0 : repo.AlbumWrites != 1) throw new InvalidOperationException("相册操作被重复提交。");
                if (state == "alb-unknown")
                {
                    var reads = repo.AlbumReviews; Invoke(Button("PhotosRefresh")); await Task.Delay(100);
                    if (repo.AlbumReviews <= reads || repo.AlbumWrites != 1 || Button("PhotosAlbumContinue").IsEnabled) throw new InvalidOperationException("未知相册结果没有保持只读恢复。");
                }
                if (state == "alb-partial" && !Nodes(dialog).OfType<ItemsControl>().Any(list => list.Items.Count == 2)) throw new InvalidOperationException("成员逐项结果缺失。");
                if (state == "alb-shared-sort" && repo.SubmittedAlbum?.Scope != SynologyPhotoAlbumListScope.WithMe) throw new InvalidOperationException("分享列表排序使用了错误范围。");
            }
            if (state == "alb-history-cold" && (repo.AlbumReviews < 1 || repo.AlbumWrites != 0 || (await repo.AlbumChangesAsync()).Single().State != SynologyPhotoChangeState.Completed)) throw new InvalidOperationException("相册冷恢复没有只读刷新。");
            if (state == "alb-history-stale" && (repo.AlbumReviews != 0 || repo.AlbumWrites != 0)) throw new InvalidOperationException("已完成的相册历史被重新执行。");
            if (state == "alb-history-cancel")
            { Invoke(Button("PhotosAlbumCancel")); await Task.Delay(100); if ((await repo.AlbumChangesAsync()).Single().State != SynologyPhotoChangeState.Cancelled || repo.AlbumWrites != 0) throw new InvalidOperationException("取消原相册任务失效。"); }
            if (state == "alb-cancel")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, dialog.CloseButtonText)));
                for (var attempt = 0; attempt < 100 && Dialog() is not null; attempt++) await Task.Delay(30);
                if (Dialog() is not null || repo.AlbumWrites != 0) throw new InvalidOperationException("取消相册表单仍有提交。");
                await WriteSnapshotAsync(page, markComplete: false); MarkSnapshotComplete(); return;
            }
            await Task.Delay(200); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("相册窗口未继承布局或主题。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(control => control.Visibility == Visibility.Visible && control.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("相册控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
            Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(button => Equals(button.Content, l.Get(key)));
        }
        finally { repo.AlbumRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(value); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
