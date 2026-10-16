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
    public bool SupportsRequestManagement => State.StartsWith("req-", StringComparison.Ordinal);
    internal readonly TaskCompletionSource RequestRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int RequestWrites, RequestReviews, RequestContinues, RequestCancels;
    internal SynologyPhotoRequestEdit? SubmittedRequest;
    private List<SynologyPhotoRequestChange>? _requestChanges;
    private SynologyPhotoRequest SyntheticRequest => new(ProfileId, "synthetic-request", new("Synthetic collection", "Photos from our synthetic event", SynologyPhotoSpace.Personal, "/Synthetic folder")
        { FolderId = 2, AlbumId = 41, SizeLimit = 1_048_577, Expiration = 1893455999 }, true, "Synthetic private album", new("https://example.invalid/synthetic-collection"));
    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope, int offset, int limit, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<SynologyPhotoSharedEntry>>(State is "req-search" or "req-no-match"
            ? Enumerable.Range(1, 201).Skip(offset).Take(limit).Select(id => new SynologyPhotoSharedEntry("synthetic-" + id, id == 201 ? "Find this collection" : "Synthetic request " + id)).ToArray()
            : offset == 0 ? [new(SyntheticRequest.Id, SyntheticRequest.Settings.Subject, Url: SyntheticRequest.Url)] : []);
    public async Task<SynologyPhotoRequest> PhotoRequestAsync(string id, CancellationToken cancellationToken = default)
    {
        if (State == "req-loading") await RequestRelease.Task;
        if (State == "req-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SyntheticRequest;
    }
    public Task<IReadOnlyList<SynologyPhotoRequestAlbum>> PhotoRequestAlbumsAsync(CancellationToken cancellationToken = default)
    {
        if (State == "req-albums-error" || State == "req-new-album-read-error" && AlbumWrites > 0) throw new HttpRequestException();
        var values = new List<SynologyPhotoRequestAlbum>();
        if (State != "req-empty") values.AddRange([new(41, 41, null, "Synthetic private album", false), new(42, null, "synthetic-other-token", "Synthetic shared album", true)]);
        if (AlbumWrites > 0 && State != "req-album-unknown") values.Add(new(91, 91, null, SubmittedAlbum?.Name ?? "Synthetic new album", false));
        return Task.FromResult<IReadOnlyList<SynologyPhotoRequestAlbum>>(values);
    }
    public Task PreparePhotoRequestAsync(SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public async Task<SynologyPhotoRequestChange> EditPhotoRequestAsync(Guid operationId, SynologyPhotoRequestEdit edit, CancellationToken cancellationToken = default)
    {
        await PhotoRequestChangesAsync(); RequestWrites++; SubmittedRequest = edit;
        var pending = State == "req-unknown";
        var result = edit.Kind == SynologyPhotoRequestEditKind.Delete ? null : SyntheticRequest with { Settings = edit.Settings! };
        var change = new SynologyPhotoRequestChange(operationId, edit.Kind, pending ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Completed, null, false, false, false, pending ? null : result);
        _requestChanges!.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoRequestChange>> PhotoRequestChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_requestChanges is null)
        {
            _requestChanges = [];
            if (State.StartsWith("req-history-", StringComparison.Ordinal) && State != "req-history-empty")
                _requestChanges.Add(new(Guid.Parse("88888888-8888-8888-8888-888888888888"), SynologyPhotoRequestEditKind.Update,
                    State == "req-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false, State == "req-history-resume", State == "req-history-input", SyntheticRequest));
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoRequestChange>>(_requestChanges.ToArray());
    }
    public async Task<SynologyPhotoRequestChange> ReviewPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    { await PhotoRequestChangesAsync(); RequestReviews++; return _requestChanges!.Single(value => value.Id == operationId); }
    public async Task<SynologyPhotoRequestChange> ContinuePhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await PhotoRequestChangesAsync(); RequestContinues++; var index = _requestChanges!.FindIndex(value => value.Id == operationId);
        return _requestChanges[index] = _requestChanges[index] with { State = SynologyPhotoChangeState.Completed, CanContinue = false, Result = SyntheticRequest };
    }
    public async Task<SynologyPhotoRequestChange> CancelPhotoRequestAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await PhotoRequestChangesAsync(); RequestCancels++; var index = _requestChanges!.FindIndex(value => value.Id == operationId);
        return _requestChanges[index] = _requestChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoRequestsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSectionAsync(SynologyPhotosSection.Sharing); await model.SelectShareScopeAsync(SynologyPhotoShareScope.Requests);
        var l = Localization.LocalizationService.Current; var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0;
        if (state is "req-search" or "req-no-match")
        {
            if (((AutoSuggestBox)page.FindName("SearchBox")).Visibility != Visibility.Visible) throw new InvalidOperationException("收集列表缺少搜索。");
            await model.SearchAsync(state == "req-search" ? "find" : "absent");
            if (model.HasMoreCollections || model.VisibleSharedEntries.Count != (state == "req-search" ? 1 : 0)) throw new InvalidOperationException("搜索没有覆盖后续页或空结果。");
            await Task.Delay(200); await WriteSnapshotAsync(page); return;
        }
        if (state == "req-folder-shortcut") { await model.SelectSectionAsync(SynologyPhotosSection.Folders); grid.SelectedIndex = 0; }
        if (state == "req-album-shortcut") { await model.SelectSectionAsync(SynologyPhotosSection.Albums); grid.SelectedIndex = 0; }
        var history = state.StartsWith("req-history-", StringComparison.Ordinal);
        var editing = state is "req-edit" or "req-loading" or "req-error" or "req-limits";
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoRequestChangesMenu" : state == "req-delete" ? "DeletePhotoRequestMenu" : editing ? "EditPhotoRequestMenu" : "CreatePhotoRequestMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("照片收集原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        for (var attempt = 0; attempt < 100 && (Dialog() is null || !Dialog()!.IsLoaded); attempt++) await Task.Delay(30);
        var dialog = Dialog() ?? throw new InvalidOperationException("没有照片收集窗口。"); await Task.Delay(180);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)) && value.Visibility == Visibility.Visible);
        async Task WaitHistory()
        { for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosRequestChanges")); attempt++) await Task.Delay(30); dialog = Dialog() ?? throw new InvalidOperationException("缺少收集记录。"); await Task.Delay(180); }
        try
        {
            var editor = Nodes(dialog).OfType<SynologyPhotoRequestEditor>().SingleOrDefault();
            if (state is "req-loading" or "req-error" or "req-safety" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("不可用收集仍可提交。");
            if (state == "req-edit" && (editor!.Input().SizeLimit != 1_048_577 || editor.Input().Expiration != 1893455999)) throw new InvalidOperationException("原日期或非整数大小被归一化。");
            if (state == "req-limits")
            {
                Nodes(dialog).OfType<ComboBox>().Single(value => Equals(value.Header, l.Get("PhotosShareExpiration"))).SelectedIndex = 1;
                Nodes(dialog).OfType<NumberBox>().Single().Value = 10; await Task.Delay(100);
                if (editor!.Input().Expiration != 0 || editor.Input().SizeLimit != 10 * 1_048_576) throw new InvalidOperationException("收集期限或大小修改没有生效。");
                var scroll = (ScrollViewer)dialog.Content; scroll.ChangeView(null, scroll.ScrollableHeight, null, true); await Task.Delay(180);
            }
            if (state == "req-folder-shortcut" && editor!.Input().FolderId != 2) throw new InvalidOperationException("文件夹快捷入口没有固定目标。");
            if (state == "req-album-shortcut" && editor!.Input().AlbumId != 41) throw new InvalidOperationException("相册快捷入口没有固定目标。");
            if (state == "req-shared-default" && (editor!.Input().Space != SynologyPhotoSpace.Shared || editor.Input().FolderId is not null)) throw new InvalidOperationException("共享管理账号默认目录错误。");
            if (state is "req-shared-entry" or "req-folder-pages")
            {
                if (state == "req-shared-entry" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("共享普通账号未选目录即可提交。");
                Invoke(Button("PhotosRequestChooseFolder")); await Task.Delay(150);
                if (state == "req-folder-pages") { Invoke(Button("PhotosLoadOlder")); await Task.Delay(100); if (Nodes(dialog).OfType<ListView>().Single().Items.Count != 101) throw new InvalidOperationException("目录选择未完整翻页。"); }
                Invoke(Button("PhotosRequestUseFolder")); await Task.Delay(100);
                if (editor!.Input().FolderId != 1 || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("选择目录没有进入收集设置。");
            }
            if (state is "req-new-album" or "req-album-unknown" or "req-new-album-read-error")
            {
                var expander = Nodes(dialog).OfType<Expander>().Single(); expander.IsExpanded = true; await Task.Delay(80);
                Nodes(dialog).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosAlbumName"))).Text = "Synthetic newly created album";
                for (var attempt = 0; attempt < 100 && !Button("PhotosCreateAlbum").IsEnabled; attempt++) await Task.Delay(20);
                if (!Button("PhotosCreateAlbum").IsEnabled) throw new InvalidOperationException("填写相册名后仍不可创建。");
                Invoke(Button("PhotosCreateAlbum")); await Task.Delay(150);
                if (repo.AlbumWrites != 1 || state is "req-new-album" or "req-new-album-read-error" && editor!.Input().AlbumId != 91 || state == "req-album-unknown" && editor!.Input().AlbumId is not null)
                    throw new InvalidOperationException("内联创建未按本次相册结果选择。");
                if (state == "req-album-unknown")
                {
                    Invoke(Nodes(expander).OfType<Button>().Single(value => Equals(value.Content, l.Get("PhotosRefresh")))); await Task.Delay(80);
                    if (repo.AlbumWrites != 1 || repo.AlbumContinues != 0) throw new InvalidOperationException("未知相册被重建。");
                }
            }
            if (state == "req-cancel")
            { Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText))); await Task.Delay(150); if (repo.RequestWrites != 0) throw new InvalidOperationException("取消草稿触发写入。"); await WriteSnapshotAsync(page); return; }
            if (state is "req-submit" or "req-unknown" or "req-delete")
            {
                if (editor is not null)
                {
                    Nodes(dialog).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosRequestSubject"))).Text = "Synthetic submitted request";
                    var album = Nodes(dialog).OfType<ComboBox>().Single(value => Equals(value.Header, l.Get("PhotosRequestAlbum"))); album.SelectedIndex = 2;
                }
                if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("合法收集无法提交。");
                Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.PrimaryButtonText))); await WaitHistory();
                if (repo.RequestWrites != 1 || state != "req-delete" && repo.SubmittedRequest?.Settings?.AlbumPassphrase != "synthetic-other-token") throw new InvalidOperationException("收集设置没有进入原流程。");
                if (state == "req-unknown" && Button("PhotosShareContinue").IsEnabled) throw new InvalidOperationException("未知收集可以重发。");
            }
            if (state == "req-history-cold" && (repo.RequestReviews == 0 || repo.RequestContinues != 0)) throw new InvalidOperationException("冷恢复自动写入。");
            if (state == "req-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(100); if (repo.RequestContinues != 1) throw new InvalidOperationException("继续未绑定原任务。"); }
            if (state == "req-history-input")
            {
                if (Button("PhotosShareContinue").IsEnabled) throw new InvalidOperationException("冷恢复丢失输入仍可重发。");
                Invoke(Button("PhotosShareEditAgain")); for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosRequestEdit")); attempt++) await Task.Delay(30);
                dialog = Dialog()!; if (repo.RequestCancels != 1 || repo.RequestWrites != 0) throw new InvalidOperationException("重新编辑没有先结束未执行记录。");
            }
            await Task.Delay(350); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("收集窗口主题或布局错误。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("收集控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.RequestRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
