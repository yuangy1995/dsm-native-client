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
    private SynologyPhotoSharedMembers? _memberPreferences;
    internal SynologyPhotoSharedMembers MemberPreferences => _memberPreferences ??= new(ProfileId, 19, State != "pref-members-disabled", State == "pref-members-empty" ? [] :
        [new(new(new("user", "31", true), "Synthetic guest"), State == "pref-members-demote" ? "management" : "entry", State == "pref-members-demote"),
         new(new(new("group", "5", true), "administrators"), "management", true), new(new(new("group", "8", true), "Synthetic group"), "future", false)]);
    internal IReadOnlyList<SynologyPhotoMemberFolderEdit> SubmittedMemberEdits = [];
    internal IReadOnlyList<SynologyPhotoSharedMember> SubmittedMembers = [];
    public async Task<SynologyPhotoSharedMembers> SharedMembersAsync(CancellationToken cancellationToken = default)
    {
        if (State == "pref-members-loading") await PreferenceRelease.Task.WaitAsync(cancellationToken);
        if (State == "pref-members-error") throw new IOException(); return MemberPreferences;
    }
    public Task<IReadOnlyList<SynologyPhotoShareRecipient>> SharedMemberCandidatesAsync(CancellationToken cancellationToken = default) => State == "pref-members-candidates-error"
        ? Task.FromException<IReadOnlyList<SynologyPhotoShareRecipient>>(new IOException()) : Task.FromResult<IReadOnlyList<SynologyPhotoShareRecipient>>([..MemberPreferences.Members.Select(x => x.Recipient), new(new("user", "42", true), "Synthetic new member")]);
    public Task<IReadOnlyList<SynologyPhotoMemberFolder>> SharedMemberFoldersAsync(SynologyPhotoShareIdentity member, CancellationToken cancellationToken = default)
    {
        if (State == "pref-members-folder-error") throw new IOException();
        SynologyPhotoMemberFolder Folder(long id, long parent, string name, string privacy, string? role) => new(ProfileId, member, 1, id, parent, name, parent == 1 ? 0 : 1, privacy, role, new('a',64), new('b',64), new('c',64));
        return Task.FromResult<IReadOnlyList<SynologyPhotoMemberFolder>>([Folder(2,1,"Shared album","private", "view"), Folder(3,2,"Holiday pictures","private","view"), Folder(4,1,"Public pictures","public-download",null)]);
    }
    public async Task<SynologyPhotoSettingsChange> SetSharedMembersAsync(Guid operationId, SynologyPhotoSharedMembers original, IReadOnlyList<SynologyPhotoSharedMember> members,
        IReadOnlyList<SynologyPhotoMemberFolderEdit> edits, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed || !SettingsSafety.SharedMembers) throw new InvalidOperationException("成员保存缺少确认或专项开关。");
        PreferenceWrites++; SubmittedMembers = members; SubmittedMemberEdits = edits;
        if (State == "pref-members-close") await PreferenceRelease.Task;
        var pending = State == "pref-members-unknown"; var partial = State == "pref-members-partial";
        _memberPreferences = pending ? original : original with { Members = members };
        _sharedPreferences = SharedPreferences with { Role = State == "pref-members-shared-lost" ? SynologyPhotoSharedRole.None : State is "pref-members-shared-role" or "pref-members-close" ? SynologyPhotoSharedRole.Entry : SharedPreferences.Role };
        return PreferenceChange = new(operationId, null, pending ? SynologyPhotoChangeState.PendingReview : partial ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Completed, false)
        { HasMemberChanges = true, SharedResult = pending ? null : SharedPreferences, CompletedSteps = pending ? 0 : 1, TotalSteps = 1, MemberChangesObserved = partial };
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SavePhotoSharedMembersAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? ""; var repo = new SmokePhotosRepository();
        if (state == "pref-members-cold") repo.PreferenceChange = new(Guid.NewGuid(), null, SynologyPhotoChangeState.PendingReview, false) { HasMemberChanges = true };
        using var page = new SynologyPhotosPage(repo, new WindowsTransferSavePicker(() => null)); ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        var model = (SynologyPhotosWorkspace)typeof(SynologyPhotosPage).GetField("_model",flags)!.GetValue(page)!; await model.LoadIfNeededAsync();
        if (state is "pref-members-shared-lost" or "pref-members-shared-role" or "pref-members-close") { await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); await model.Preview.OpenAsync(model.Items[0]); }
        var month = model.SelectedMonth; var photos = model.Items.Select(x => x.Id).ToArray(); var l = Localization.LocalizationService.Current; var verified = false;
        ContentDialog? Dialog() => (ContentDialog?)typeof(SynologyPhotosPage).GetField("_dialog",flags)!.GetValue(page);
        async Task Wait(Func<bool> ready) { for (var i=0;i<180 && !ready();i++) await Task.Delay(30); if (!ready()) throw new InvalidOperationException("成员界面未达到预期状态。"); }
        static IEnumerable<DependencyObject> Nodes(DependencyObject node) { yield return node; for (var i=0;i<VisualTreeHelper.GetChildrenCount(node);i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node,i))) yield return child; }
        T Control<T>(string id) where T : DependencyObject => Nodes(Dialog()!).OfType<T>().Single(x => AutomationProperties.GetAutomationId(x)==id);
        static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        Button Primary(string key) => Nodes(Dialog()!).OfType<Button>().Single(x => x.Name == "PrimaryButton" && Equals(x.Content,l.Get(key)));
        try
        {
            var menu = (MenuFlyoutItem)page.FindName("PhotoSharedMembersMenu");
            if (state == "pref-members-nonadmin") { if (menu.Visibility != Visibility.Collapsed) throw new InvalidOperationException("普通账号显示管理员入口。"); await WriteSnapshotAsync(page,markComplete:false); verified=true; return; }
            if (state == "pref-members-save")
            {
                var more = (Button)page.FindName("MoreButton"); more.Flyout.ShowAt(more); await Task.Delay(70);
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer((MenuFlyoutItem)page.FindName("SelectPhotosMenu")).GetPattern(PatternInterface.Invoke)).Invoke();
                var grid = (GridView)page.FindName("LibraryGrid"); await Wait(() => grid.SelectionMode == ListViewSelectionMode.Multiple && grid.Items.Count > 2); grid.SelectedItems.Add(grid.Items[0]); grid.SelectedItems.Add(grid.Items[1]);
            }
            var button = (Button)page.FindName("MoreButton"); button.Flyout.ShowAt(button); await Task.Delay(70);
            ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(menu).GetPattern(PatternInterface.Invoke)).Invoke(); await Wait(() => Dialog()?.IsLoaded == true);
            if (state is "pref-members-loading" or "pref-members-error" or "pref-members-cold")
            { await Task.Delay(160); if (Dialog()!.IsPrimaryButtonEnabled || repo.PreferenceWrites != 0) throw new InvalidOperationException("未就绪时可提交成员。"); }
            else
            {
                await Wait(() => Nodes(Dialog()!).OfType<Button>().Any(x => AutomationProperties.GetAutomationId(x)=="PhotoMemberAdd"));
                if (state == "pref-members-filtered") Control<TextBox>("PhotoMemberSearch").Text = "No such member";
                if (state == "pref-members-disabled" && Control<Button>("PhotoMemberAdd").IsEnabled) throw new InvalidOperationException("共享关闭时可新增成员。");
                if (state is not ("pref-members-empty" or "pref-members-filtered"))
                { if (Control<ComboBox>("PhotoMemberRole-group-5").IsEnabled || Control<ComboBox>("PhotoMemberRole-group-8").IsEnabled) throw new InvalidOperationException("受保护或未知角色可被改写。"); }
                if (state is "pref-members-add" or "pref-members-new-cancel" or "pref-members-candidates-error")
                {
                    Click(Control<Button>("PhotoMemberAdd"));
                    if (state == "pref-members-candidates-error") { await Wait(() => Nodes(Dialog()!).OfType<TextBlock>().Any(x => x.Text == l.Get("PhotosPreferenceLoadFailed"))); Click(Control<Button>("PhotoMemberBack")); }
                    else { await Wait(() => Nodes(Dialog()!).OfType<Button>().Any(x => AutomationProperties.GetAutomationId(x)=="PhotoMemberCandidate-user-42")); Click(Control<Button>("PhotoMemberCandidate-user-42")); }
                }
                else if (state == "pref-members-demote") Control<ComboBox>("PhotoMemberRole-user-31").SelectedIndex=0;
                else if (state is "pref-members-folders" or "pref-members-folders-save" or "pref-members-parent-revoke" or "pref-members-batch" or "pref-members-folder-error") Click(Control<Button>("PhotoMemberFolders-user-31"));
                if (state == "pref-members-folder-error")
                { await Wait(() => Nodes(Dialog()!).OfType<TextBlock>().Any(x => x.Text == l.Get("PhotosPreferenceLoadFailed"))); if (Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("目录失败仍可返回授权草稿。"); }
                else if (state is "pref-members-add" or "pref-members-new-cancel" or "pref-members-demote" or "pref-members-folders" or "pref-members-folders-save" or "pref-members-parent-revoke" or "pref-members-batch")
                {
                    await Wait(() => Nodes(Dialog()!).OfType<ComboBox>().Any(x => AutomationProperties.GetAutomationId(x)=="PhotoMemberFolderRole-2"));
                    if (repo.PreferenceWrites!=0) throw new InvalidOperationException("目录编辑提前写入。");
                    if (state == "pref-members-new-cancel")
                    { Click(Control<Button>("PhotoMemberBack")); if (Nodes(Dialog()!).OfType<ComboBox>().Any(x => AutomationProperties.GetAutomationId(x)=="PhotoMemberRole-user-42") || Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("取消新建保留了成员草稿。"); }
                    else
                    {
                        Click(Control<Button>("PhotoMemberExpand-2")); await Wait(() => Nodes(Dialog()!).OfType<ComboBox>().Any(x => AutomationProperties.GetAutomationId(x)=="PhotoMemberFolderRole-3"));
                        if (state == "pref-members-parent-revoke") { Control<ComboBox>("PhotoMemberFolderRole-2").SelectedIndex=0; if (Control<ComboBox>("PhotoMemberFolderRole-3").IsEnabled) throw new InvalidOperationException("上层撤权后子层仍可编辑。"); }
                        else if (state == "pref-members-batch") { Click(Control<Button>("PhotoMemberBatch-grant-Manage")); Click(Control<Button>("PhotoMemberBatch-revoke-Upload")); }
                        else if (state is "pref-members-add" or "pref-members-folders-save") { Control<ComboBox>("PhotoMemberFolderRole-2").SelectedIndex=3; Control<ComboBox>("PhotoMemberFolderRole-3").SelectedIndex=4; }
                        if (state != "pref-members-folders")
                        { Click(Primary("PhotosMemberFoldersDone")); await Wait(() => Dialog()!.PrimaryButtonText==l.Get("PhotosSaveChanges")); if (repo.PreferenceWrites!=0 || !Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("目录完成未只返回本地草稿。"); }
                    }
                }
                var save = state is "pref-members-save" or "pref-members-confirm" or "pref-members-unknown" or "pref-members-partial" or "pref-members-close" or "pref-members-shared-role" or "pref-members-shared-lost" or "pref-members-add" or "pref-members-folders-save" or "pref-members-parent-revoke" or "pref-members-batch" or "pref-members-demote";
                if (state is "pref-members-save" or "pref-members-confirm" or "pref-members-unknown" or "pref-members-partial" or "pref-members-close" or "pref-members-shared-role" or "pref-members-shared-lost" or "pref-members-locked" or "pref-members-candidates-error") Control<ToggleSwitch>("PhotoMemberBackup-user-31").IsOn=true;
                if (state == "pref-members-locked" && Dialog()!.IsPrimaryButtonEnabled) throw new InvalidOperationException("保护开关未限制成员写入。");
                if (save)
                {
                    await Wait(() => Dialog()!.IsPrimaryButtonEnabled); Click(Primary("PhotosSaveChanges")); await Wait(() => Dialog()!.PrimaryButtonText==l.Get("PhotosSharedConfirm"));
                    if (repo.PreferenceWrites!=0) throw new InvalidOperationException("最终确认前写入。");
                    if (state=="pref-members-confirm") { await Task.Delay(120); await WriteSnapshotAsync(Dialog()!,markComplete:false); verified=true; return; }
                    Click(Primary("PhotosSharedConfirm")); await Wait(() => repo.PreferenceWrites==1);
                    if (state=="pref-members-close") { Dialog()!.Hide(); repo.PreferenceRelease.TrySetResult(); }
                    if (state is "pref-members-unknown" or "pref-members-partial") await Wait(() => !Dialog()!.IsPrimaryButtonEnabled);
                    else
                    {
                        await Wait(() => Dialog() is null);
                        if (state is "pref-members-shared-role" or "pref-members-shared-lost" or "pref-members-close")
                        { if (model.CanManageSharedSpace || model.Preview.Photo is not null || state=="pref-members-shared-lost" && model.SelectedSpace==SynologyPhotoSpace.Shared) throw new InvalidOperationException("共享权限更新未清理旧访问。"); }
                        else if (model.SelectedMonth != month || !photos.SequenceEqual(model.Items.Select(x=>x.Id))) throw new InvalidOperationException("成员保存改变了个人照片位置。");
                        if (state=="pref-members-save" && ((GridView)page.FindName("LibraryGrid")).SelectedItems.Count!=2) throw new InvalidOperationException("成员保存丢失个人多选。");
                        if (state=="pref-members-add" && !repo.SubmittedMembers.Any(x=>x.Id.Value=="42")) throw new InvalidOperationException("新成员未加入最终命令。");
                        if (state is "pref-members-folders-save" or "pref-members-add" && repo.SubmittedMemberEdits.Single().Changes?.Count!=2) throw new InvalidOperationException("目录草稿未包含真实选择。");
                        if (state=="pref-members-batch" && repo.SubmittedMemberEdits.Single() is { } edit && edit.Original.Any(x=>edit.Expected(x)!="download")) throw new InvalidOperationException("连续批量未组合。");
                    }
                }
            }
            await Task.Delay(120); await WriteSnapshotAsync(Dialog() is { IsLoaded:true } dialog ? dialog : page,markComplete:false); verified=true;
        }
        finally
        {
            repo.PreferenceRelease.TrySetResult();
            if (Dialog() is { } dialog)
            {
                var closed=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void Closed(ContentDialog sender,ContentDialogClosedEventArgs args) { sender.Closed-=Closed; closed.TrySetResult(); }
                dialog.Closed+=Closed; dialog.Hide(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
            page.Dispose(); if (verified) MarkSnapshotComplete();
        }
    }
}
