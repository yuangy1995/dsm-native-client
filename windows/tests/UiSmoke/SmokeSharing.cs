using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Sharing;
using LanStash.App.Features.Transfers;
using LanStash.App.Platform.Sharing;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

// 仅编译进合成宿主；全部目标和数据均为虚构，不连接 NAS。
internal sealed class SmokeSharingRepository(string state) : IFileShareLinkRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileShareLinkAvailability ShareLinkAvailability => new(FileShareLinkAvailabilityStatus.Available, 3);
    public int Writes, Reviews;
    public EditFileShareLinkRequest? LastEdit;
    public CreateFileShareLinkRequest? LastCreate;
    public FileShareLink[] Links { get; } = Enumerable.Range(1, 3).Select(index =>
        new FileShareLink($"link-{index}", $"/share/Project {index}", new Uri($"https://share.invalid/link-{index}"), false, null)
        { AvailabilityDateKnown = true, Advanced = new(FileShareProtection.None, [], [], 0, false, false, "", "") }).ToArray();
    public async Task<IReadOnlyList<FileShareLink>> ListFileShareLinksAsync(CancellationToken cancellationToken = default)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "error") throw new InvalidDataException("synthetic");
        return state == "empty" ? [] : Links;
    }
    public async Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(string prefix, CancellationToken cancellationToken = default)
    {
        if (state == "members-loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "members-error") throw new InvalidDataException("synthetic");
        return state == "members-empty" ? [] : [new("Sample user", FileSharePrincipalKind.User), new("Sample group", FileSharePrincipalKind.Group)];
    }
    public Task<FileShareLinkEditOutcome> EditFileShareLinkAsync(EditFileShareLinkRequest request, CancellationToken cancellationToken = default)
    {
        Writes++; LastEdit = request;
        return Task.FromResult(new FileShareLinkEditOutcome(state == "edit-unknown" ? Unknown("shareLinkEdit") : Success("shareLinkEdit"),
            request.Link with { HasPassword = request.PasswordIntent == FileShareValueIntent.Replace }));
    }
    public Task<FileShareLinkEditOutcome> ReviewFileShareLinkEditAsync(string id, CancellationToken cancellationToken = default)
    {
        Reviews++; return Task.FromResult(new FileShareLinkEditOutcome(Success("shareLinkEdit"), Links.Single(link => link.Id == id) with { HasPassword = true }));
    }
    public Task<FileShareLinkDeletionOutcome> DeleteFileShareLinkAsync(DeleteFileShareLinkRequest request, CancellationToken cancellationToken = default)
    {
        Writes++; return Task.FromResult(new FileShareLinkDeletionOutcome(Success("shareLinkDelete"), request.Link));
    }
    public Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(CreateFileShareLinkRequest request, CancellationToken cancellationToken = default)
    {
        Writes++; LastCreate = request;
        var link = new FileShareLink("created", request.Target.Path, new("https://share.invalid/created"), !string.IsNullOrEmpty(request.Password), request.ExpiresOn)
        {
            AvailableOn = request.AvailableOn, AvailabilityDateKnown = true,
            Advanced = request.FileRequest is { } collection ? new(FileShareProtection.None, [], [], 0, true, true, collection.Name, collection.Message) : null,
        };
        return Task.FromResult(new FileShareLinkCreationOutcome(Success("shareLinkCreate"), link));
    }
    private static MutationResult Success(string operation) => new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0));
    private static MutationResult Unknown(string operation) => new(1, MutationResultStatus.SubmittedButUnverified, operation, true, true, new(0, 0, 1));
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveFileSharingAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "list";
        var repository = new SmokeSharingRepository(state);
        var localization = Localization.LocalizationService.Current;
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        if (state.StartsWith("create", StringComparison.Ordinal))
        {
            if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
            var files = new SmokeDragMoveRepository();
            using var browser = new FileBrowserViewModel(files);
            var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
            using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
            using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator,
                new WindowsTransferSavePicker(() => null), new SmokeFileUploadPicker([]));
            using var page = new FilesPage(browser, preview, profile, picker, shareRepository: repository, shareReviewBlocker: new());
            ((Frame)shell.FindName("ContentFrame")).Content = page;
            await Task.Delay(160); await browser.OpenLocationAsync("/share"); await Task.Delay(100);
            browser.SelectedItem = browser.Items.First(item => item.Item.IsDirectory);
            Task? showing = null;
            if (state == "create-batch")
            {
                typeof(FilesPage).GetMethod("ShareMultiple_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]); await Task.Delay(100);
                ((ListView)page.FindName("FileList")).SelectAll();
                typeof(FilesPage).GetMethod("ShareSelectedItems_Click", flags)!.Invoke(page, [null, new RoutedEventArgs()]);
            }
            else showing = (Task)typeof(FilesPage).GetMethod("ShowShareLinkAsync", flags)!.Invoke(page, null)!;
            await Task.Delay(220);
            var dialog = (ContentDialog?)typeof(FilesPage).GetField("_shareLinkDialog", flags)!.GetValue(page)
                ?? throw new InvalidOperationException("分享创建未打开。");
            if (state != "create-batch")
            {
                var collect = Nodes(dialog).OfType<CheckBox>().Single(item => Equals(item.Content, localization.Get("FileShareCollectFiles")));
                collect.IsChecked = true;
                Nodes(dialog).OfType<TextBox>().Single(item => Equals(item.Header, localization.Get("FileShareCollectionName"))).Text = "Project files";
                var create = Button(dialog, "FileShareLinkCreateAction");
                if (create.IsEnabled || repository.Writes != 0) throw new InvalidOperationException("收集未确认就可提交。");
                Nodes(dialog).OfType<CheckBox>().Single(item => Equals(item.Content, localization.Get("FileShareCollectionRisk"))).IsChecked = true;
                if (!create.IsEnabled) throw new InvalidOperationException("确认收集后不能提交。");
                if (state == "create-run")
                {
                    await Click(create); await Task.Delay(120);
                    if (repository.Writes != 1 || repository.LastCreate?.FileRequest?.UploadConfirmed != true)
                        throw new InvalidOperationException("收集创建未接通。");
                }
            }
            dialog.UpdateLayout(); await Task.Delay(200);
            if (dialog.ActualTheme != page.ActualTheme) throw new InvalidOperationException("创建表单主题未继承。");
            await WriteSnapshotAsync(dialog, markComplete: false);
            dialog.Hide();
            if (showing is not null) await showing.WaitAsync(TimeSpan.FromSeconds(3));
            await Task.Delay(80); MarkSnapshotComplete(); return;
        }
        using var owner = new FileShareLinkManagementDialog(repository, repository.ProfileId, new WindowsClipboard(), root.DispatcherQueue);
        var opening = owner.ShowAsync(root.XamlRoot); await Task.Delay(220);
        var managementDialog = (ContentDialog?)typeof(FileShareLinkManagementDialog).GetField("_dialog", flags)!.GetValue(owner)
            ?? throw new InvalidOperationException("分享管理未打开。");
        if (state.StartsWith("edit", StringComparison.Ordinal) || state.StartsWith("members", StringComparison.Ordinal))
        {
            if (state == "edit-batch")
            {
                await Click(Button(managementDialog, "FileShareSelectAll")); await Task.Delay(80);
                await Click(Button(managementDialog, "FileShareEditAction"));
            }
            else typeof(FileShareLinkManagementDialog).GetMethod("OpenEditor", flags)!.Invoke(owner, [new[] { repository.Links[0] }]);
            await Task.Delay(140);
            var editor = (FileShareLinkEditViewModel)typeof(FileShareLinkManagementDialog).GetField("_editor", flags)!.GetValue(owner)!;
            var passwordChoice = Nodes(managementDialog).OfType<ComboBox>().First();
            if (state.StartsWith("members", StringComparison.Ordinal))
            {
                Nodes(managementDialog).OfType<ComboBox>().Single(item => Equals(item.Header, localization.Get("FileShareAudienceLabel"))).SelectedIndex = 2;
                Nodes(managementDialog).OfType<CheckBox>().Single(item => Equals(item.Content, localization.Get("FileShareAudienceRisk"))).IsChecked = true;
                await Click(Button(managementDialog, "FileShareFindMembersAction")); await Task.Delay(150);
                if (state == "members")
                {
                    var list = Nodes(managementDialog).OfType<ListView>().Single(); list.SelectAll();
                    Nodes(managementDialog).OfType<CheckBox>().Single(item => Equals(item.Content, localization.Get("FileShareAudienceRisk"))).IsChecked = true;
                    if (editor.SelectedMembers.Count != 2 || !editor.CanSave) throw new InvalidOperationException("成员选择未接通。");
                }
                if (state == "members-error" && !editor.MembersFailed || state == "members-empty" && editor.Members.Count != 0 ||
                    state == "members-loading" && !editor.IsLoadingMembers) throw new InvalidOperationException("成员状态错误。");
            }
            else
            {
                passwordChoice.SelectedIndex = 1;
                Nodes(managementDialog).OfType<PasswordBox>().Single().Password = " synthetic "; await Task.Delay(90);
                if (!editor.CanSave || repository.Writes != 0) throw new InvalidOperationException("分享编辑默认提交状态错误。");
                if (state is "edit-run" or "edit-unknown" or "edit-batch")
                {
                    await Click(Button(managementDialog, "FileShareSaveAction")); await Task.Delay(150);
                    if (repository.Writes != (state == "edit-batch" ? 3 : 1) || repository.LastEdit?.Password != " synthetic ")
                        throw new InvalidOperationException("编辑数量或密码意图错误。");
                    if (state == "edit-unknown")
                    {
                        if (!editor.CanReview || editor.CanSave) throw new InvalidOperationException("未知编辑允许重发。");
                        await Click(Button(managementDialog, "FileShareRefreshAction")); await Task.Delay(100);
                        if (!editor.IsComplete || repository.Reviews != 1 || repository.Writes != 1) throw new InvalidOperationException("编辑恢复发生重放。");
                    }
                }
            }
        }
        else if (state == "delete-batch")
        {
            await Click(Button(managementDialog, "FileShareSelectAll")); await Task.Delay(70);
            await Click(Button(managementDialog, "FileShareLinkManageDeleteAction")); await Task.Delay(100);
            if (repository.Writes != 0) throw new InvalidOperationException("取消分享未经确认。");
            await Click(Button(managementDialog, "FileShareLinkManageDeleteAction")); await Task.Delay(130);
            if (repository.Writes != 3) throw new InvalidOperationException("批量取消分享未逐项执行。");
        }
        managementDialog.UpdateLayout(); await Task.Delay(180);
        if (managementDialog.ActualTheme != ((FrameworkElement)root.XamlRoot.Content).ActualTheme)
            throw new InvalidOperationException("分享管理主题未继承。");
        await WriteSnapshotAsync(managementDialog, markComplete: false);
        owner.Close(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();

        static IEnumerable<DependencyObject> Nodes(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            {
                var node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return node;
                foreach (var nested in Nodes(node)) yield return nested;
            }
        }
        Button Button(DependencyObject parent, string key) => Nodes(parent).OfType<Button>()
            .Single(item => Equals(item.Content, localization.Get(key)));
        static async Task Click(Button button)
        {
            button.StartBringIntoView(); await Task.Delay(90);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(60);
        }
    }
}
