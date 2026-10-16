using LanStash.App.Features.Files.Permissions;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokePermissionRepository(string state) : IFilePermissionRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public int Writes, Reviews;
    private bool _pending;
    private FilePermissionSnapshot _snapshot = new("synthetic", new("/share/Project", "Project", true, 0, DateTimeOffset.UnixEpoch, "Sample owner", true, true),
        "/synthetic/Project", "Sample group", "normal", state != "posix", state != "readonly", true, true,
        state == "empty" ? [] : [new("user", "Sample person", 1000, false, FileAclEffect.Allow, FileAclRights.ReadData | FileAclRights.ReadPermissions,
            FileAclInheritance.ThisFolder), new("group", "Sample group", 1001, false, FileAclEffect.Allow, FileAclRights.ReadData, FileAclInheritance.ChildFiles, 1)],
        new("Sample owner", "user", "1000", state != "readonly"), "755");
    public async Task<FilePermissionSnapshot> LoadFilePermissionsAsync(string path, CancellationToken cancellationToken = default)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "error") throw new InvalidDataException("synthetic");
        return _snapshot;
    }
    public Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(string prefix, CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<FileSharePrincipal>>(state == "members-empty" ? [] : [new("Sample person", FileSharePrincipalKind.User), new("Sample group", FileSharePrincipalKind.Group)]);
    public Task<FilePermissionProgress> ChangeFilePermissionsAsync(FilePermissionChange change, CancellationToken cancellationToken = default)
    {
        Writes++;
        if (!change.ConfirmedAccessRemoval) throw new InvalidOperationException("缺少权限风险确认。");
        _snapshot = _snapshot with { Rules = (change.ExplicitRules ?? _snapshot.Rules.Where(rule => rule.Level == 0)).Concat(_snapshot.Rules.Where(rule => rule.Level > 0)).ToArray() };
        _pending = state == "unknown";
        return Task.FromResult(Result(_pending));
    }
    public Task<FilePermissionProgress?> ReviewFilePermissionsAsync(string path, CancellationToken cancellationToken = default)
    {
        if (!_pending) return Task.FromResult<FilePermissionProgress?>(null);
        Reviews++; _pending = false;
        return Task.FromResult<FilePermissionProgress?>(Result(false));
    }
    private static FilePermissionProgress Result(bool pending) => new(new(1, pending ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
        "filePermissions", true, pending, new(pending ? 0 : 1, 0, pending ? 1 : 0)));
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveFilePermissionsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "acl";
        var repository = new SmokePermissionRepository(state);
        using var model = new FilePermissionViewModel(repository, "/share/Project");
        using var dialog = new FilePermissionDialog(model, root.XamlRoot);
        var opening = dialog.ShowAsync().AsTask(); await Task.Delay(260);
        var text = Localization.LocalizationService.Current;
        if (state is not ("error" or "loading") && model.Snapshot is null) throw new InvalidOperationException("未加载权限表单。");
        if (state == "loading" && !model.IsBusy || state == "error" && !model.LoadFailed) throw new InvalidOperationException("权限状态错误。");
        if (state is "acl" or "readonly")
        {
            var expander = Nodes(dialog).OfType<Expander>().First(); expander.IsExpanded = true; await Task.Delay(80);
            if (state == "readonly" && (model.IsEditable || dialog.IsPrimaryButtonEnabled)) throw new InvalidOperationException("只读权限允许编辑。");
        }
        if (state is "members" or "members-empty")
        {
            await Click(Nodes(dialog).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "FilePermissionsAddRule"));
            if (model.Members.Count != (state == "members" ? 2 : 0)) throw new InvalidOperationException("成员结果错误。");
        }
        if (state is "run" or "unknown")
        {
            var expander = Nodes(dialog).OfType<Expander>().First(); expander.IsExpanded = true; await Task.Delay(90);
            var effect = Nodes(expander).OfType<ComboBox>().Single(); effect.SelectedIndex = 1;
            if (model.CanSave || repository.Writes != 0) throw new InvalidOperationException("权限未经确认提交。");
            var confirmation = Nodes(dialog).OfType<CheckBox>().Single(item => AutomationProperties.GetAutomationId(item) == "FilePermissionsAccessRisk");
            confirmation.StartBringIntoView(); await Task.Delay(60);
            ((Microsoft.UI.Xaml.Automation.Provider.IToggleProvider)new Microsoft.UI.Xaml.Automation.Peers.ToggleButtonAutomationPeer(confirmation)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Toggle)).Toggle(); await Task.Delay(60);
            if (!dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("权限确认后无法保存。");
            await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get("ActionSave"))));
            if (repository.Writes != 1) throw new InvalidOperationException("保存未执行一次。");
            if (state == "unknown")
            {
                if (!model.IsPending || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("未知写允许重复保存。");
                await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get("FileShareRefreshAction"))));
                if (repository.Reviews != 1 || repository.Writes != 1 || model.IsPending) throw new InvalidOperationException("恢复发生重放。");
            }
        }
        dialog.UpdateLayout(); await Task.Delay(180);
        if (dialog.ActualTheme != ((FrameworkElement)root.XamlRoot.Content).ActualTheme) throw new InvalidOperationException("权限主题错误。");
        await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); dialog.Dispose(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();

        static IEnumerable<DependencyObject> Nodes(DependencyObject parent)
        {
            for (var index = 0; index < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); index++)
            { var node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, index); yield return node; foreach (var child in Nodes(node)) yield return child; }
        }
        static async Task Click(Button button)
        {
            button.StartBringIntoView(); await Task.Delay(80);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); await Task.Delay(120);
        }
    }
}
