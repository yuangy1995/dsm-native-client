using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeFileTaskRepository(string state) : IFileBackgroundTaskRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public bool IsAvailable => true;
    public FileBackgroundTaskSummary Item = new("synthetic-task", FileBackgroundTaskKind.CopyOrMove,
        state is "finished" or "clear" ? FileBackgroundTaskState.Finished : FileBackgroundTaskState.Active, 0.45,
        DateTimeOffset.FromUnixTimeSeconds(1700000000), 14, 30, 10485760, 20485760)
        { CreationTimestamp = 1700000000.123456789m, ApiVersion = 3, Method = "start" };
    public FileBackgroundTaskProgress? Pending;
    public int Writes; public bool Removed;
    public bool CanControlTask(FileBackgroundTaskSummary task, FileBackgroundTaskAction action) => state != "readonly" && !Removed;
    public async Task<FileBackgroundTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, cancellationToken);
        if (state == "error") throw new IOException("合成读取失败");
        return Removed || state == "missing" ? new([], 0, 0, 0, false) : new([Item], 0, 1, 1, false);
    }
    public Task<IReadOnlyList<FileBackgroundTaskProgress>> GetTaskOperationsAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<FileBackgroundTaskProgress>>(Pending is null ? [] : [Pending]);
    public Task<FileBackgroundTaskProgress?> ReviewTaskAsync(Guid requestId, CancellationToken token = default) => Task.FromResult(Pending);
    public Task<FileBackgroundTaskProgress> ControlTaskAsync(FileBackgroundTaskChange change, CancellationToken token = default)
    {
        if (!change.Confirmed || !Item.SameIdentity(change.Task)) throw new InvalidOperationException("合成任务确认或身份错误。");
        Writes++; var unknown = state == "unknown";
        if (!unknown) { Removed = change.Action == FileBackgroundTaskAction.Clear; Item = Item with { State = FileBackgroundTaskState.Finished }; }
        var result = new FileBackgroundTaskProgress(change, new(1, unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess,
            "fileBackgroundTask", true, unknown, new(unknown ? 0 : 1, 0, unknown ? 1 : 0)));
        if (unknown) Pending = result; return Task.FromResult(result);
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveFileTasksAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "active";
        var repository = new SmokeFileTaskRepository(state);
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var downloads = System.Reflection.DispatchProxy.Create<IDownloadStationRepository, SmokeActivityProbe>(); ((SmokeActivityProbe)downloads).Hold = false;
        var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator, new WindowsTransferSavePicker(() => null), new WindowsTransferOpenPicker(() => null));
        var navigation = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var page = new TransferActivityPage(coordinator, picker, profile, downloads, repository, folder => { navigation.TrySetResult(folder); return Task.CompletedTask; });
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        await Task.Delay(100);
        var isApp = state.StartsWith("app-", StringComparison.Ordinal);
        Task opening;
        if (isApp)
        {
            var unknown = state == "app-unknown";
            await coordinator.RunUploadAsync(new(profile, "/sample/original", "Document.txt", 4096, Guid.NewGuid()), (_, _) => Task.FromResult(new MutationResult(1,
                unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.PermissionDenied, "upload", unknown, unknown,
                new(0, unknown ? 0 : 1, unknown ? 1 : 0), MutationErrorCategory.Permission)));
            await Task.Delay(700); page.UpdateLayout();
            Invoke(Nodes(page).OfType<Button>().Single(b => b.Tag is ForegroundTransferActivity { Source: ForegroundTransferSource.App } && b.Visibility == Visibility.Visible));
            opening = Task.CompletedTask;
        }
        else opening = page.ShowFileTaskDetailsAsync(repository.Item);
        await Task.Delay(250);
        var dialog = (ContentDialog)typeof(TransferActivityPage).GetField("_detailsDialog", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(page)!;
        if (root.XamlRoot.Content is FrameworkElement themeRoot && dialog.ActualTheme != themeRoot.ActualTheme) throw new InvalidOperationException("任务详情没有采用工作区主题。");
        if (state is "confirm" or "stop" or "clear" or "unknown")
        {
            Invoke(Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText))); await Task.Delay(100);
            if (repository.Writes != 0) throw new InvalidOperationException("尚未确认就控制了任务。");
            if (state != "confirm")
            {
                Invoke(Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText))); await Task.Delay(100);
                if (repository.Writes != 1 || state is "clear" or "unknown" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("控制入口或未知保护错误。");
            }
        }
        if (state is "readonly" or "loading" or "error" or "missing" && dialog.IsPrimaryButtonEnabled) throw new InvalidOperationException("只读状态开放了控制。");
        dialog.UpdateLayout(); await Task.Delay(100); await WriteSnapshotAsync(dialog, markComplete: false);
        if (state == "app-navigation")
        {
            Invoke(Nodes(dialog).OfType<Button>().Single(b => Equals(b.Content, dialog.PrimaryButtonText)));
            if (await navigation.Task.WaitAsync(TimeSpan.FromSeconds(3)) != "/sample/original") throw new InvalidOperationException("原位置导航丢失了原目标。");
        }
        await page.SetWindowVisibleAsync(false); dialog.Hide(); await opening.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();
        static IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    }
}
