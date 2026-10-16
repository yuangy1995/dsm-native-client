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
    public bool SupportsSharingManagement => State.StartsWith("shr-", StringComparison.Ordinal) || State.StartsWith("tmp-", StringComparison.Ordinal);
    public SynologyPhotoSharingSafety SharingSafety => new(State is not ("shr-safety" or "tmp-safety"), State != "tmp-safety", Requests: State != "req-safety", FolderPermissions: State != "fperm-safety");
    internal readonly TaskCompletionSource SharingRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int SharingWrites, SharingReviews, SharingContinues;
    internal SynologyPhotoSharingEdit? SubmittedSharing;
    private List<SynologyPhotoSharingChange>? _sharingChanges;
    private SynologyPhotoSharing SyntheticSharing() => new(SyntheticAlbum(), SynologyPhotoLinkAccess.Invited, new('b', 64))
    {
        ConfiguredAccess = SynologyPhotoLinkAccess.Invited, Url = new("https://example.invalid/synthetic-sharing"), HasPassword = true, Expiration = 1893455999,
        Temporary = State.StartsWith("tmp-", StringComparison.Ordinal) && State != "tmp-ordinary",
        Members = State == "shr-unknown-members" ? null : State == "shr-empty" ? [] :
            [new(new(new("user", "44", true), "Synthetic person"), "download"), new(new(new("group", "legacy"), "Synthetic older group"), "future-role")],
    };
    public async Task<SynologyPhotoSharing> AlbumSharingAsync(long id, CancellationToken cancellationToken = default)
    {
        if (State is "shr-loading" or "tmp-loading") await SharingRelease.Task;
        if (State is "shr-error" or "tmp-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SyntheticSharing();
    }
    public Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharingRecipientsAsync(bool sharedFolder = false, CancellationToken cancellationToken = default)
    {
        if (State is "shr-recipients-error" or "fperm-candidates-error") throw new HttpRequestException();
        return Task.FromResult<IReadOnlyList<SynologyPhotoShareRecipient>>(State is "shr-empty" or "fperm-empty" ? [] :
            [new(new("user", "52", true), "Synthetic new person"), new(new("group", "52"), "Synthetic new group")]);
    }
    public Task PrepareSharingAsync(SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public async Task<SynologyPhotoSharingChange> EditSharingAsync(Guid operationId, SynologyPhotoSharingEdit edit, CancellationToken cancellationToken = default)
    {
        await SharingChangesAsync(); SharingWrites++; SubmittedSharing = edit;
        var state = State == "shr-unknown" ? SynologyPhotoChangeState.PendingReview : State == "shr-partial" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed;
        var result = SyntheticSharing() with { Access = edit.Access, Members = edit.Members ?? edit.Original.Members };
        var change = new SynologyPhotoSharingChange(operationId, 41, edit.Access, state == SynologyPhotoChangeState.Completed ? SynologyPhotoSharingStage.Finished : SynologyPhotoSharingStage.Configure,
            state, state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null, false, state == SynologyPhotoChangeState.Failed, false,
            state == SynologyPhotoChangeState.Completed ? result : result with { Access = SynologyPhotoLinkAccess.Disabled, Url = null });
        _sharingChanges!.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoSharingChange>> SharingChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_sharingChanges is null)
        {
            _sharingChanges = [];
            if (State.StartsWith("shr-history-", StringComparison.Ordinal) && State != "shr-history-empty")
            {
                var cold = State == "shr-history-cold"; var input = State == "shr-history-reedit";
                _sharingChanges.Add(new(Guid.Parse("55555555-5555-5555-5555-555555555555"), 41, SynologyPhotoLinkAccess.View,
                    input ? SynologyPhotoSharingStage.Configure : SynologyPhotoSharingStage.Open,
                    cold ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false, !cold && !input, input, null));
            }
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoSharingChange>>(_sharingChanges.ToArray());
    }
    public async Task<SynologyPhotoSharingChange> ReviewSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await SharingChangesAsync(); SharingReviews++; var index = _sharingChanges!.FindIndex(value => value.Id == operationId);
        if (State == "shr-history-cold") _sharingChanges[index] = _sharingChanges[index] with { State = SynologyPhotoChangeState.Ready, CanContinue = true };
        return _sharingChanges[index];
    }
    public async Task<SynologyPhotoSharingChange> ContinueSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await SharingChangesAsync(); SharingContinues++; var index = _sharingChanges!.FindIndex(value => value.Id == operationId);
        return _sharingChanges[index] = _sharingChanges[index] with { State = SynologyPhotoChangeState.Completed, Stage = SynologyPhotoSharingStage.Finished, CanContinue = false, Result = SyntheticSharing() };
    }
    public async Task<SynologyPhotoSharingChange> CancelSharingChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await SharingChangesAsync(); var index = _sharingChanges!.FindIndex(value => value.Id == operationId);
        return _sharingChanges[index] = _sharingChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoSharingAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSectionAsync(SynologyPhotosSection.Albums); var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0;
        var l = Localization.LocalizationService.Current; var history = state.StartsWith("shr-history-", StringComparison.Ordinal);
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoSharingChangesMenu" : "PhotoSharingMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("分享原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        for (var attempt = 0; attempt < 100 && (Dialog() is null || !Dialog()!.IsLoaded); attempt++) await Task.Delay(30);
        var dialog = Dialog() ?? throw new InvalidOperationException("没有分享窗口。"); await Task.Delay(180);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        ComboBox Combo(string key) => Nodes(Dialog()!).OfType<ComboBox>().Single(value => Equals(value.Header, l.Get(key)));
        try
        {
            if (!history && state is not ("shr-loading" or "shr-error") && !Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Any()) throw new InvalidOperationException("分享编辑器加载失败。");
            if (state is "shr-loading" or "shr-error")
            { if (dialog.IsPrimaryButtonEnabled || repo.SharingWrites != 0) throw new InvalidOperationException("读取失败仍可保存。"); }
            if (state == "shr-members")
            {
                var list = Nodes(dialog).OfType<ListView>().Single(); list.SelectedIndex = 1; Invoke(Button("PhotosShareAddMember"));
                var editor = Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Single(); var edit = editor.Input();
                if (edit.Members?.Count != 3 || edit.Members[2].Id != new SynologyPhotoShareIdentity("group", "52") || edit.Members[1].Role != "future-role") throw new InvalidOperationException("成员身份或旧角色丢失。");
                var remove = Nodes(editor).OfType<Button>().First(value => Equals(value.Content, l.Get("PhotosShareRemoveMember"))); Invoke(remove);
                if (editor.Input().Members?.Count != 2) throw new InvalidOperationException("成员移除未更新输入。");
            }
            if (state == "shr-member-filter")
            {
                Nodes(dialog).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosShareFindMembers"))).Text = "absent-synthetic";
                await Task.Delay(100);
                if (Nodes(dialog).OfType<ListView>().Single().Items.Count != 0 || Button("PhotosShareAddMember").IsEnabled ||
                    !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosShareNoMatches"))) throw new InvalidOperationException("无匹配成员状态没有禁用添加或缺少恢复提示。");
            }
            if (state == "shr-empty" && (!Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosShareNoMembers")) || Button("PhotosShareAddMember").IsEnabled)) throw new InvalidOperationException("空名单状态不完整。");
            if (state == "shr-unknown-members" && Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Single().Input().Members is not null) throw new InvalidOperationException("未知名单被当为空名单。");
            if (state == "shr-password")
            {
                Combo("PhotosSharePassword").SelectedIndex = 1; if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空新密码可提交。");
                Nodes(dialog).OfType<PasswordBox>().Single().Password = " synthetic password ";
                await Task.Delay(100);
                if (!dialog.IsPrimaryButtonEnabled || Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Single().Input().Password != " synthetic password ") throw new InvalidOperationException("密码合法原值被改变。");
            }
            if (state == "shr-expiry")
            {
                Combo("PhotosShareExpiration").SelectedIndex = 2; if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空日期可提交。");
                Nodes(dialog).OfType<CalendarDatePicker>().Single().Date = new DateTimeOffset(2026, 10, 19, 0, 0, 0, TimeSpan.Zero);
                var local = DateTime.SpecifyKind(new DateTime(2026, 10, 19, 23, 59, 59), DateTimeKind.Unspecified);
                if (Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Single().Input().Expiration != new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUnixTimeSeconds()) throw new InvalidOperationException("有效期没有使用本地日末。");
            }
            if (state == "shr-recipients-error" && !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("候选失败阻断无关分享设置。");
            if (state == "shr-safety")
            {
                Combo("PhotosShareAccess").SelectedIndex = 3; if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未验收的扩大访问入口开放。");
                Combo("PhotosShareAccess").SelectedIndex = 0; if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("关闭访问被阻断。");
            }
            if (state is "shr-submit" or "shr-unknown" or "shr-partial")
            {
                Combo("PhotosShareAccess").SelectedIndex = 2; Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.PrimaryButtonText)));
                for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosShareChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("保存后缺少分享记录。"); await Task.Delay(150);
                if (repo.SharingWrites != 1 || repo.SubmittedSharing?.Access != SynologyPhotoLinkAccess.View) throw new InvalidOperationException("分享没有使用显式输入或重复提交。");
                if (state == "shr-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (Button("PhotosShareContinue").IsEnabled || repo.SharingWrites != 1 || repo.SharingContinues != 0) throw new InvalidOperationException("未知分享被重放。"); }
                if (state == "shr-partial" && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosShareClosedIncomplete"))) throw new InvalidOperationException("部分完成未说明访问保持关闭。");
            }
            if (state == "shr-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(100); if (repo.SharingContinues != 1) throw new InvalidOperationException("继续没有执行原分享任务。"); }
            if (state == "shr-history-cold" && (repo.SharingContinues != 0 || repo.SharingReviews == 0)) throw new InvalidOperationException("冷恢复没有保持只读。");
            if (state == "shr-history-reedit")
            {
                Invoke(Button("PhotosShareEditAgain")); for (var attempt = 0; attempt < 100 && Equals(Dialog()?.Title, l.Get("PhotosShareChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("冷恢复未打开新设置。"); await Task.Delay(150);
                if ((await repo.SharingChangesAsync()).Single().State != SynologyPhotoChangeState.Cancelled || repo.SharingWrites != 0 || !Nodes(dialog).OfType<SynologyPhotoSharingEditor>().Any()) throw new InvalidOperationException("冷恢复未取消未执行部分或自动重写。");
            }
            if (state == "shr-history-cancel") { Invoke(Button("PhotosShareStop")); await Task.Delay(100); if ((await repo.SharingChangesAsync()).Single().State != SynologyPhotoChangeState.Cancelled) throw new InvalidOperationException("取消分享任务失败。"); }
            if (state == "shr-cancel")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(value => Equals(value.Content, dialog.CloseButtonText)));
                for (var attempt = 0; attempt < 100 && Dialog() is not null; attempt++) await Task.Delay(30);
                if (repo.SharingWrites != 0) throw new InvalidOperationException("关闭分享表单写入了 NAS。");
                if (Dialog() is not null) throw new InvalidOperationException("分享表单关闭后没有释放。"); await WriteSnapshotAsync(page); return;
            }
            var scroll = dialog.Content as ScrollViewer; if (state is "shr-members" or "shr-member-filter" or "shr-unknown-members") scroll?.ChangeView(null, scroll.ScrollableHeight, null, true);
            await Task.Delay(500); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("分享窗口未继承主题或布局。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("分享控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.SharingRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
