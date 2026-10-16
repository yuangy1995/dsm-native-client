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
    public bool SupportsFolderSharing => State.StartsWith("fperm-", StringComparison.Ordinal);
    internal readonly TaskCompletionSource FolderSharingRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal int FolderSharingWrites, FolderSharingReviews, FolderSharingContinues, FolderSharingCancels;
    internal SynologyPhotoFolderSharingEdit? SubmittedFolderSharing;
    private List<SynologyPhotoFolderSharingChange>? _folderSharingChanges;
    private SynologyPhotoFolderSharing SyntheticFolderSharing => new(ProfileId,
        new(SynologyPhotoSpace.Shared, 2, State is "fperm-parent" or "fperm-second" ? 3 : 1, State is "fperm-parent" or "fperm-second" ? "/Synthetic folder/Child" : "/Synthetic folder"),
        SynologyPhotoFolderAccess.Invited, State != "fperm-parent", false, new('d', 64))
    {
        Url = new("https://example.invalid/synthetic-folder"), HasPassword = true,
        Members = State == "fperm-unknown-members" ? null : State == "fperm-empty" ? [] :
            [new(new(new("user", "44", true), "Synthetic person"), "download"), new(new(new("group", "legacy"), "Synthetic older group"), "future-role")],
    };
    public async Task<SynologyPhotoFolderSharing> FolderSharingAsync(SynologyPhotoFolder folder, CancellationToken cancellationToken = default)
    {
        if (State == "fperm-loading") await FolderSharingRelease.Task;
        if (State == "fperm-error") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SyntheticFolderSharing;
    }
    public Task PrepareFolderSharingAsync(SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default) => Task.CompletedTask;
    public async Task<SynologyPhotoFolderSharingChange> EditFolderSharingAsync(Guid operationId, SynologyPhotoFolderSharingEdit edit, CancellationToken cancellationToken = default)
    {
        await FolderSharingChangesAsync(); FolderSharingWrites++; SubmittedFolderSharing = edit;
        var state = State == "fperm-unknown" ? SynologyPhotoChangeState.PendingReview : State == "fperm-partial" ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed;
        var result = SyntheticFolderSharing with { Access = edit.Access, Members = edit.Members ?? edit.Original.Members };
        var change = new SynologyPhotoFolderSharingChange(operationId, 2, state == SynologyPhotoChangeState.Completed ? SynologyPhotoFolderSharingStage.Finished :
            state == SynologyPhotoChangeState.Failed ? SynologyPhotoFolderSharingStage.DefaultOption : SynologyPhotoFolderSharingStage.Permissions,
            state, state == SynologyPhotoChangeState.Failed ? SynologyPhotoFailure.Permission : null, false, state == SynologyPhotoChangeState.Failed, false, state != SynologyPhotoChangeState.PendingReview, result);
        _folderSharingChanges!.Add(change); return change;
    }
    public Task<IReadOnlyList<SynologyPhotoFolderSharingChange>> FolderSharingChangesAsync(CancellationToken cancellationToken = default)
    {
        if (_folderSharingChanges is null)
        {
            _folderSharingChanges = [];
            if (State.StartsWith("fperm-history-", StringComparison.Ordinal) && State != "fperm-history-empty")
                _folderSharingChanges.Add(new(Guid.Parse("99999999-9999-9999-9999-999999999999"), 2,
                    State == "fperm-history-resume" ? SynologyPhotoFolderSharingStage.DefaultOption : SynologyPhotoFolderSharingStage.Permissions,
                    State == "fperm-history-cold" ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, null, false,
                    State == "fperm-history-resume", State == "fperm-history-input", State == "fperm-history-resume", SyntheticFolderSharing));
        }
        return Task.FromResult<IReadOnlyList<SynologyPhotoFolderSharingChange>>(_folderSharingChanges.ToArray());
    }
    public async Task<SynologyPhotoFolderSharingChange> ReviewFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    { await FolderSharingChangesAsync(); FolderSharingReviews++; return _folderSharingChanges!.Single(value => value.Id == operationId); }
    public async Task<SynologyPhotoFolderSharingChange> ContinueFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FolderSharingChangesAsync(); FolderSharingContinues++; var index = _folderSharingChanges!.FindIndex(value => value.Id == operationId);
        return _folderSharingChanges[index] = _folderSharingChanges[index] with { State = SynologyPhotoChangeState.Completed, CanContinue = false, PermissionsSaved = true };
    }
    public async Task<SynologyPhotoFolderSharingChange> CancelFolderSharingAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await FolderSharingChangesAsync(); FolderSharingCancels++; var index = _folderSharingChanges!.FindIndex(value => value.Id == operationId);
        return _folderSharingChanges[index] = _folderSharingChanges[index] with { State = SynologyPhotoChangeState.Cancelled, CanContinue = false };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoFolderSharingAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null));
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(300);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model", flags)!.GetValue(page)!;
        await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var l = Localization.LocalizationService.Current; var grid = (GridView)page.FindName("LibraryGrid"); grid.SelectedIndex = 0;
        var history = state.StartsWith("fperm-history-", StringComparison.Ordinal);
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog", flags)!.GetValue(page);
        var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(100);
        var menu = (MenuFlyoutItem)page.FindName(history ? "PhotoFolderSharingChangesMenu" : "PhotoFolderSharingMenu");
        if (!menu.IsEnabled || menu.Visibility != Visibility.Visible) throw new InvalidOperationException("目录权限原生入口不可用。");
        ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(menu).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        for (var attempt = 0; attempt < 100 && (Dialog() is null || !Dialog()!.IsLoaded); attempt++) await Task.Delay(30);
        var dialog = Dialog() ?? throw new InvalidOperationException("没有目录权限窗口。"); await Task.Delay(180);
        Button Button(string key) => Nodes(Dialog()!).OfType<Button>().Single(value => Equals(value.Content, l.Get(key)));
        ComboBox Combo(string key) => Nodes(Dialog()!).OfType<ComboBox>().Single(value => Equals(value.Header, l.Get(key)));
        try
        {
            var editor = Nodes(dialog).OfType<SynologyPhotoFolderSharingEditor>().SingleOrDefault();
            if (!history && state is not ("fperm-loading" or "fperm-error") && editor is null) throw new InvalidOperationException("目录权限表单未加载。");
            if (state is "fperm-loading" or "fperm-error" or "fperm-parent" or "fperm-safety" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("受限目录仍可写入。");
            if (state is "fperm-parent" or "fperm-second" && Nodes(dialog).OfType<CheckBox>().Any(value => value.Visibility == Visibility.Visible)) throw new InvalidOperationException("第二层显示了不允许更改的选项。");
            if (state == "fperm-empty" && (!Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosShareNoMembers")) || Button("PhotosShareAddMember").IsEnabled)) throw new InvalidOperationException("空成员状态不完整。");
            if (state == "fperm-unknown-members" && editor!.Input().Members is not null) throw new InvalidOperationException("未知成员被当作空名单。");
            if (state == "fperm-candidates-error" && !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("候选读取失败阻断其他设置。");
            if (state == "fperm-members")
            {
                Nodes(dialog).OfType<ListView>().Single().SelectedIndex = 1; Invoke(Button("PhotosShareAddMember"));
                var roles = Nodes(editor!).OfType<ComboBox>().Where(value => value.Items.OfType<string>().Contains(l.Get("PhotosFolderShareRoleManage"))).ToArray();
                roles[^1].SelectedIndex = 3; var input = editor!.Input();
                if (input.Members?.Count != 3 || input.Members[2].Id != new SynologyPhotoShareIdentity("group", "52") || input.Members[2].Role != "manage" || input.Members[1].Role != "future-role") throw new InvalidOperationException("目录成员身份或角色错误。");
            }
            if (state == "fperm-filter")
            {
                Nodes(dialog).OfType<TextBox>().Single(value => Equals(value.Header, l.Get("PhotosShareFindMembers"))).Text = "absent"; await Task.Delay(100);
                if (Nodes(dialog).OfType<ListView>().Single().Items.Count != 0 || Button("PhotosShareAddMember").IsEnabled || !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosShareNoMatches"))) throw new InvalidOperationException("成员筛选空状态错误。");
            }
            if (state == "fperm-password")
            {
                Combo("PhotosSharePassword").SelectedIndex = 1; if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("空密码可以保存。");
                Nodes(dialog).OfType<PasswordBox>().Single().Password = " synthetic password "; await Task.Delay(100);
                if (editor!.Input().Password != " synthetic password " || !dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("密码原值丢失。");
            }
            if (state is "fperm-confirm" or "fperm-submit" or "fperm-unknown" or "fperm-partial" or "fperm-confirm-cancel")
            {
                Combo("PhotosShareAccess").SelectedIndex = 2; Nodes(dialog).OfType<CheckBox>().Single().IsChecked = true;
                Invoke(Button("PhotosShareContinue"));
                for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosFolderShareConfirm")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("缺少权限确认。"); await Task.Delay(160);
                if (repo.FolderSharingWrites != 0 || !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosFolderShareApplyRisk")) ||
                    !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosFolderShareViewRisk"))) throw new InvalidOperationException("确认前写入或缺少准确的目录访问/覆盖风险。");
                if (state == "fperm-confirm-cancel")
                { Invoke(Button("PhotosCancel")); await Task.Delay(200); if (repo.FolderSharingWrites != 0) throw new InvalidOperationException("取消确认仍写入。"); await WriteSnapshotAsync(page); return; }
                if (state != "fperm-confirm")
                {
                    Invoke(Button("PhotosSaveChanges"));
                    for (var attempt = 0; attempt < 100 && !Equals(Dialog()?.Title, l.Get("PhotosFolderShareChanges")); attempt++) await Task.Delay(30);
                    dialog = Dialog() ?? throw new InvalidOperationException("保存后缺少更改记录。"); await Task.Delay(160);
                    if (repo.FolderSharingWrites != 1 || repo.SubmittedFolderSharing is not { Access: SynologyPhotoFolderAccess.View, AppliesToSubfolders: true }) throw new InvalidOperationException("提交未绑定显式输入。");
                    if (state == "fperm-unknown") { Invoke(Button("PhotosRefresh")); await Task.Delay(100); if (Button("PhotosShareContinue").IsEnabled || repo.FolderSharingContinues != 0 || repo.FolderSharingWrites != 1) throw new InvalidOperationException("未知权限写被重放。"); }
                    if (state == "fperm-partial" && !Nodes(dialog).OfType<TextBlock>().Any(value => value.Text == l.Get("PhotosFolderShareDefaultIncomplete"))) throw new InvalidOperationException("没有区分权限和默认选项。");
                }
            }
            if (state == "fperm-history-cold" && (repo.FolderSharingReviews == 0 || repo.FolderSharingContinues != 0)) throw new InvalidOperationException("冷恢复自动写入。");
            if (state == "fperm-history-resume") { Invoke(Button("PhotosShareContinue")); await Task.Delay(100); if (repo.FolderSharingContinues != 1) throw new InvalidOperationException("继续未绑定原任务。"); }
            if (state == "fperm-history-input")
            {
                Invoke(Button("PhotosShareEditAgain")); for (var attempt = 0; attempt < 100 && Equals(Dialog()?.Title, l.Get("PhotosFolderShareChanges")); attempt++) await Task.Delay(30);
                dialog = Dialog() ?? throw new InvalidOperationException("没有重新编辑窗口。"); await Task.Delay(160);
                if (repo.FolderSharingCancels != 1 || repo.FolderSharingWrites != 0 || !Nodes(dialog).OfType<SynologyPhotoFolderSharingEditor>().Any()) throw new InvalidOperationException("缺输入恢复没有结束旧记录。");
            }
            if (state == "fperm-cancel") { Invoke(Button("PhotosCancel")); await Task.Delay(200); if (repo.FolderSharingWrites != 0) throw new InvalidOperationException("取消表单写入。"); await WriteSnapshotAsync(page); return; }
            if (state is "fperm-members" or "fperm-filter" or "fperm-unknown-members") (dialog.Content as ScrollViewer)?.ChangeView(null, (dialog.Content as ScrollViewer)?.ScrollableHeight, null, true);
            await Task.Delay(500); dialog.UpdateLayout();
            if (dialog.ActualWidth <= 0 || dialog.ActualTheme != root.ActualTheme) throw new InvalidOperationException("目录权限窗口主题或布局错误。");
            foreach (var control in Nodes(dialog).OfType<Control>().Where(value => value.Visibility == Visibility.Visible && value.ActualWidth > 0))
            { var bounds = control.TransformToVisual(dialog).TransformBounds(new Windows.Foundation.Rect(0, 0, control.ActualWidth, control.ActualHeight)); if (bounds.X < -1 || bounds.Right > dialog.ActualWidth + 1) throw new InvalidOperationException("目录权限控件超出窗口。"); }
            await WriteSnapshotAsync(dialog, markComplete: false); MarkSnapshotComplete();
        }
        finally { repo.FolderSharingRelease.TrySetResult(); Dialog()?.Hide(); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
