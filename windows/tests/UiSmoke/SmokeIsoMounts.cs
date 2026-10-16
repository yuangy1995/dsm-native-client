using System.Reflection;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal class SmokeIsoRepository : DispatchProxy
{
    public string State = "mount";
    public int Writes, Reviews;
    private IsoMountProgress? _pending;
    private IsoMountChange? _submitted;
    protected override object? Invoke(MethodInfo? method, object?[]? args)
    {
        if (method!.Name == "get_ProfileId") return SmokeActivityProbe.Profile;
        if (method.Name == "get_CanManageIsoMounts") return State != "readonly";
        if (method.Name == "LoadRemoteMountInventoryAsync") return Inventory((CancellationToken)args![0]!);
        if (method.Name == "GetIsoMountOperationsAsync") return Task.FromResult<IReadOnlyList<IsoMountProgress>>(_pending is null ? [] : [_pending]);
        if (method.Name == "ChangeIsoMountAsync")
        {
            var change = (IsoMountChange)args![0]!;
            if (!change.Confirmed || change.AutomaticMount && !change.ConfirmedAutomatic) throw new InvalidOperationException("ISO 缺少确认。");
            Writes++; _submitted = change; var result = Progress(change, State == "unknown"); _pending = result.Outcome.RequiresRefresh ? result : null;
            return Task.FromResult(result);
        }
        if (method.Name == "ReviewIsoMountAsync")
        { Reviews++; var result = _pending is null ? null : Progress(_pending.Change, false); _pending = null; return Task.FromResult(result); }
        throw new NotSupportedException(method.Name);
    }
    private async Task<RemoteMountInventory> Inventory(CancellationToken token)
    {
        if (State == "loading") await Task.Delay(Timeout.Infinite, token);
        if (State == "error") throw new InvalidDataException("synthetic");
        return new(SmokeActivityProbe.Profile, true, []) { IsoMountingEnabled = State != "readonly", IsoItems = _submitted is { } submitted
            ? submitted.IsUnmount ? [] : [new(submitted.ProfileId, submitted.Source!.Path, submitted.MountPoint, submitted.AutomaticMount)] : State is "unmount" or "filtered" or "readonly"
            ? [new(SmokeActivityProbe.Profile, "/share/Example.iso", "/share/Disc", false)] : [] };
    }
    private static IsoMountProgress Progress(IsoMountChange change, bool pending) => new(change,
        new(1, pending ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, "isoMount", true, pending, new(pending ? 0 : 1, 0, pending ? 1 : 0)));
}

internal sealed class SmokeIsoFolders : IFileCopyMoveFolderSource
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public bool IsReadOnlyPath(string path) => false;
    public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken token) => Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>(path switch
    { "" => [new("/share", "Shared folder", true)], "/share" => [new("/share/Disc", "Disc", true)], _ => [] });
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveIsoMountsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "mount";
        var repository = DispatchProxy.Create<IFileLocationsRepository, SmokeIsoRepository>();
        var fake = (SmokeIsoRepository)repository; fake.State = state;
        var source = state is "mount" or "run" or "unknown" or "automatic" ? new FileItem("/share/Example.iso", "Example.iso", false, 42, DateTimeOffset.UnixEpoch, "sample", true, true) : null;
        using var model = new IsoMountViewModel(repository, new SmokeIsoFolders(), source);
        using var dialog = new IsoMountDialog(model, root.XamlRoot);
        var opening = dialog.ShowAsync().AsTask(); await Task.Delay(250);
        var text = Localization.LocalizationService.Current;
        if (state == "error" && !model.LoadFailed || state == "loading" && !model.IsBusy) throw new InvalidOperationException("ISO 加载状态错误。");
        if (state == "filtered") Nodes(dialog).OfType<TextBox>().Single().Text = "no-match";
        if (state is "unmount" or "readonly")
        {
            Nodes(dialog).OfType<ListView>().First().SelectedIndex = 0; await Task.Delay(50);
            if (state == "readonly" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("只读 ISO 可提交。");
        }
        if (source is not null)
        {
            await Click(Nodes(dialog).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "IsoChoose"));
            Nodes(dialog).OfType<ListView>().Last().SelectedIndex = 0; await Task.Delay(60);
            if (model.CanChooseFolder) throw new InvalidOperationException("ISO 允许共享根。");
            Nodes(dialog).OfType<ListView>().Last().SelectedIndex = 0; await Task.Delay(60);
            await Click(Nodes(dialog).OfType<Button>().Single(button => AutomationProperties.GetAutomationId(button) == "IsoUseFolder"));
            if (model.Destination != "/share/Disc") throw new InvalidOperationException("ISO 未选择目标。");
        }
        if (state == "automatic")
        {
            var toggle = Nodes(dialog).OfType<CheckBox>().Single(box => Equals(box.Content, text.Get("IsoAutomatic")));
            ((Microsoft.UI.Xaml.Automation.Provider.IToggleProvider)new Microsoft.UI.Xaml.Automation.Peers.ToggleButtonAutomationPeer(toggle)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Toggle)).Toggle(); await Task.Delay(70);
            if (dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("自动挂载缺少独立确认。");
        }
        if (state is "run" or "unknown" or "unmount")
        {
            await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get(state == "unmount" ? "IsoUnmount" : "IsoMount"))));
            if (fake.Writes != 1 || dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("ISO 重复提交或未提交。");
            if (state == "unmount" && (model.Inventory?.IsoItems?.Count != 0 || model.Selected is not null)) throw new InvalidOperationException("卸载后仍显示旧挂载。");
            if (state == "unknown")
            {
                if (!model.IsPending) throw new InvalidOperationException("未知 ISO 未保留。");
                await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get("FileShareRefreshAction"))));
                if (fake.Reviews != 1 || fake.Writes != 1 || model.IsPending) throw new InvalidOperationException("ISO 恢复发生重放。");
            }
        }
        dialog.UpdateLayout(); await Task.Delay(150);
        if (dialog.ActualTheme != ((FrameworkElement)root.XamlRoot.Content).ActualTheme) throw new InvalidOperationException("ISO 主题错误。");
        await WriteSnapshotAsync(dialog, markComplete: false);
        dialog.Hide(); dialog.Dispose(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();

        static IEnumerable<DependencyObject> Nodes(DependencyObject element)
        {
            yield return element;
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element); i++)
                foreach (var child in Nodes(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element, i))) yield return child;
        }
        static async Task Click(Button button)
        {
            button.StartBringIntoView(); await Task.Delay(40);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
            await Task.Delay(100);
        }
    }
}
