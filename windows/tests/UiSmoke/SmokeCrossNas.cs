using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeCrossNasRepository(string state) : IFileCopyMoveRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public static readonly NasProfile Target = new(Guid.Parse("22222222-2222-2222-2222-222222222222"), "Backup NAS", "target.invalid", null, "synthetic");
    public FileCopyMoveAvailability Availability => new(true, true, 3);
    public bool SupportsCopyMoveReview => true;
    public CrossNasCopyMoveAvailability CrossNasAvailability => new(true, false);
    public Guid Id { get; } = Guid.NewGuid();
    public int Copies, Reads, Continues, Deletes;
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public async Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        Copies++; Started.TrySetResult();
        if (request.SourceProfileId != ProfileId || request.TargetProfileId != Target.Id || request.DestinationFolderPath != "/backup" || request.Overwrite)
            throw new InvalidOperationException("跨 NAS 未绑定原目标。");
        if (state == "cancel") { try { await Task.Delay(Timeout.Infinite, cancellationToken); } catch (OperationCanceledException) { } }
        return Result(state == "success" || state.StartsWith("delete-", StringComparison.Ordinal));
    }
    public Task<CrossNasCopyMoveOutcome?> ReviewCrossNasTransferAsync(Guid operationId, CancellationToken cancellationToken = default)
    { if (operationId != Id) throw new InvalidOperationException("恢复身份变化。"); Reads++; return Task.FromResult<CrossNasCopyMoveOutcome?>(state == "global-deleted" ? DeletionResult(true) : Deletes > 0 ? DeletionResult(state == "delete-refresh") : Result(state == "refresh", state == "continue")); }
    public Task<CrossNasCopyMoveOutcome?> DeleteCrossNasSourcesAsync(Guid operationId, bool confirmed, CancellationToken cancellationToken = default)
    {
        if (operationId != Id || !confirmed || Deletes > 0) throw new InvalidOperationException("删除缺少独立确认或发生重放。");
        Deletes++; return Task.FromResult<CrossNasCopyMoveOutcome?>(DeletionResult(state == "delete-complete"));
    }
    private CrossNasCopyMoveOutcome DeletionResult(bool complete)
    {
        var copy = Result(true);
        return copy with { CanDeleteSources = false, SourceDeletion = new(new(1,
            complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, "crossNasDeleteSources", true, !complete,
            new(complete ? 3 : 0, 0, complete ? 0 : 1)),
            copy.Items.Select((item, index) => new CrossNasSourceDeletionItem(item.SourcePath, item.IsDirectory,
                complete ? CrossNasSourceDeletionState.Deleted : index == 1 ? CrossNasSourceDeletionState.ResultUnavailable : CrossNasSourceDeletionState.NotStarted)).ToArray()) };
    }
    public Task<CrossNasCopyMoveOutcome?> ContinueCrossNasTransferAsync(Guid operationId, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    { if (operationId != Id) throw new InvalidOperationException("继续身份变化。"); Continues++; return Task.FromResult<CrossNasCopyMoveOutcome?>(Result(true)); }
    public Task<IReadOnlyList<CrossNasTransferSummary>> GetCrossNasTransfersAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<CrossNasTransferSummary>>((state == "history" || state.StartsWith("global-", StringComparison.Ordinal)) ? [new(Id, ProfileId, Target.Id, "/share/target", "/backup", "target", true, 0, state == "global-deleted" ? DeletionResult(true) : Result(false))] : []);
    private CrossNasCopyMoveOutcome Result(bool complete, bool remaining = false)
    {
        var rows = new[]
        {
            new CrossNasTransferItemResult("/share/target", "/backup/target", true, CrossNasTransferItemState.Copied, null),
            new CrossNasTransferItemResult("/share/target/first.txt", "/backup/target/first.txt", false,
                complete || remaining ? CrossNasTransferItemState.Copied : CrossNasTransferItemState.ResultUnavailable, null),
            new CrossNasTransferItemResult("/share/target/second.txt", "/backup/target/second.txt", false,
                complete ? CrossNasTransferItemState.Copied : CrossNasTransferItemState.NotStarted, null),
        };
        return new(new(1, complete ? MutationResultStatus.ConfirmedSuccess : remaining ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.SubmittedButUnverified,
            "crossNasCopy", true, !complete && !remaining, new(complete ? 3 : remaining ? 2 : 1, 0, complete || remaining ? 0 : 1)),
            "/share/target", "/backup/target") { OperationId = Id, Items = rows, CanContinue = remaining,
                CanDeleteSources = complete && state.StartsWith("delete-", StringComparison.Ordinal), RecoveryStorageUnavailable = state == "storage-error" };
    }
    public sealed class Folders(string state) : IFileCopyMoveFolderSource
    {
        public Guid ProfileId => Target.Id;
        public async Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken)
        {
            if (state == "loading") await Task.Delay(Timeout.Infinite, cancellationToken);
            if (state == "error") throw new IOException("合成目录读取失败。");
            return state == "empty" || path.Length > 0 ? [] : [new("/backup", "backup", true)];
        }
        public bool IsReadOnlyPath(string path) => false;
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveCrossNasAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "success";
        var repository = new SmokeCrossNasRepository(state); var data = new SmokeDragMoveRepository();
        using var browser = new FileBrowserViewModel(data);
        var preview = System.Reflection.DispatchProxy.Create<IFilePreviewRepository, SmokeDragPreview>();
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        using var picker = new WindowsTransferPickerService(new SmokeRepository(), coordinator,
            new WindowsTransferSavePicker(() => null), new SmokeFileUploadPicker([]));
        using var page = new FilesPage(browser, preview, profile, picker, copyMoveRepository: repository);
        page.SetCrossNasDependencies([SmokeCrossNasRepository.Target], (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(new SmokeCrossNasRepository.Folders(state)));
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        await Task.Delay(150); await browser.OpenLocationAsync("/share"); browser.SelectedItem = browser.Items.Single(item => item.Item.IsDirectory);
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        Task showing;
        if (state.StartsWith("global-", StringComparison.Ordinal))
        {
            browser.SelectedItem = null;
            showing = (Task)typeof(FilesPage).GetMethod("ShowCopyMoveRecoveryAsync", flags)!.Invoke(page, null)!;
            await Task.Delay(240);
            var history = (ContentDialog?)typeof(FilesPage).GetField("_fileOperationRecoveryDialog", flags)!.GetValue(page) ?? throw new InvalidOperationException("任务列表未打开。");
            if (state == "global-history")
            {
                if (repository.Copies != 0 || repository.Reads != 0 || !Nodes(history).OfType<ComboBox>().Any()) throw new InvalidOperationException("任务列表执行了原操作。");
                await WriteSnapshotAsync(history, markComplete: false); history.Hide(); await showing; MarkSnapshotComplete(); return;
            }
            await Click(Nodes(history).OfType<Button>().Single(button => Equals(button.Content, LocalizationService.Current.Get("CrossNasOpenTask"))));
        }
        else showing = (Task)typeof(FilesPage).GetMethod("ShowCrossNasCopyMoveAsync", flags)!.Invoke(page, [FileCopyMoveOperation.Copy, null])!;
        await Task.Delay(240);
        var dialog = (ContentDialog?)typeof(FilesPage).GetField("_crossNasCopyMoveDialog", flags)!.GetValue(page) ?? throw new InvalidOperationException("跨 NAS 对话框未打开。");
        var model = (CrossNasCopyMoveViewModel)typeof(FilesPage).GetField("_crossNasCopyMoveModel", flags)!.GetValue(page)!;
        var text = LocalizationService.Current;
        if (state == "global-deleted")
        {
            if (browser.SelectedItem is not null || repository.Copies != 0 || repository.Deletes != 0 || repository.Reads != 1 || model.State != CrossNasCopyMoveState.Completed)
                throw new InvalidOperationException("已删源的任务无法从全局列表只读打开。");
        }
        else if (state == "history")
        {
            await Click(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Format("CrossNasHistoryItem", "Backup NAS", "/backup"))));
            if (repository.Copies != 0 || repository.Reads != 1 || model.State != CrossNasCopyMoveState.Recoverable)
                throw new InvalidOperationException("历史复制发生重放。");
        }
        else if (state != "choose")
        {
            Nodes(dialog).OfType<ListView>().Single().SelectedIndex = 0;
            await Task.Delay(160);
            if (state == "loading" && model.State != CrossNasCopyMoveState.LoadingFolders || state == "error" && model.State != CrossNasCopyMoveState.Failure)
                throw new InvalidOperationException("目录读取状态错误。");
            if (state == "empty" && (model.Folders.Count > 0 || dialog.IsPrimaryButtonEnabled)) throw new InvalidOperationException("空目录可提交。");
            if (state is "success" or "unknown" or "refresh" or "continue" or "cancel" or "storage-error" || state.StartsWith("delete-", StringComparison.Ordinal))
            {
                // 等实际目录行完成绑定；构建负载下不能按固定毫秒数猜测布局完成。
                for (var attempt = 0; attempt < 250 && !Nodes(dialog).OfType<ListView>().Any(list => list.Items.OfType<FileCopyMoveFolder>().Any()); attempt++)
                    await Task.Delay(20);
                var destinations = Nodes(dialog).OfType<ListView>().Single(list => list.Items.OfType<FileCopyMoveFolder>().Any());
                destinations.SelectedIndex = 0; await Task.Delay(120);
                await Click(Button("CrossNasSubmitButton"));
                if (state == "cancel")
                {
                    await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(3));
                    await Click(Button("FileCopyMove_Cancel_Button"));
                }
                for (var attempt = 0; attempt < 30 && model.IsTransferring; attempt++) await Task.Delay(50);
                if (repository.Copies != 1 || model.IsTransferring) throw new InvalidOperationException("复制未正确结束或重复提交。");
                if (state is "refresh" or "continue")
                {
                    await Click(Button("CrossNasRefresh"));
                    if (repository.Reads != 1 || repository.Copies != 1) throw new InvalidOperationException("刷新重放了复制。");
                }
                if (state == "continue")
                {
                    await Click(Button("CrossNasContinue"));
                    if (repository.Continues != 1 || repository.Copies != 1) throw new InvalidOperationException("继续未复用原操作。");
                }
                if (state is "success" or "refresh" or "continue" && model.State != CrossNasCopyMoveState.Completed)
                    throw new InvalidOperationException("完成结果错误。");
                if (state is "unknown" or "cancel" && (model.State != CrossNasCopyMoveState.Recoverable || model.CanSubmit))
                    throw new InvalidOperationException("未知结果开放重复提交。");
                if (state == "storage-error" && (model.CanRefresh || dialog.IsPrimaryButtonEnabled || !model.Outcome!.RecoveryStorageUnavailable))
                    throw new InvalidOperationException("存储失败未保持关闭并显示恢复提示。");
                if (state.StartsWith("delete-", StringComparison.Ordinal))
                {
                    if (repository.Deletes != 0 || model.State != CrossNasCopyMoveState.SourceDeletionReady)
                        throw new InvalidOperationException("复制自动触发删源。");
                    if (state != "delete-ready")
                    {
                        await Click(Button("CrossNasDeleteSources"));
                        if (repository.Deletes != 0 || model.State != CrossNasCopyMoveState.ConfirmingSourceDeletion || dialog.DefaultButton != ContentDialogButton.Secondary)
                            throw new InvalidOperationException("未显示独立删除风险确认。");
                        if (state == "delete-cancel")
                        {
                            await Click(Button("FileCopyMove_Cancel_Button"));
                            if (repository.Deletes != 0 || model.State != CrossNasCopyMoveState.SourceDeletionReady)
                                throw new InvalidOperationException("取消确认仍删除。");
                        }
                        else if (state != "delete-confirm")
                        {
                            await Click(Button("CrossNasConfirmDeleteSources"));
                            if (repository.Deletes != 1 || repository.Copies != 1) throw new InvalidOperationException("删源重放复制或重复删除。");
                            if (state == "delete-refresh")
                            {
                                await Click(Button("CrossNasRefresh"));
                                if (repository.Reads != 1 || repository.Deletes != 1) throw new InvalidOperationException("恢复重发删除。");
                            }
                            if (state is "delete-complete" or "delete-refresh" && model.State != CrossNasCopyMoveState.Completed ||
                                state == "delete-unknown" && model.State != CrossNasCopyMoveState.Recoverable)
                                throw new InvalidOperationException("删源结果错误。");
                        }
                    }
                }
            }
        }
        await Task.Delay(150); dialog.UpdateLayout();
        if (dialog.ActualTheme != ((FrameworkElement)root.XamlRoot.Content).ActualTheme) throw new InvalidOperationException("跨 NAS 主题未继承。");
        await WriteSnapshotAsync(dialog, markComplete: false);
        model.Dispose(); dialog.Hide(); await showing.WaitAsync(TimeSpan.FromSeconds(3)); MarkSnapshotComplete();

        Button Button(string key) => Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, text.Get(key)));
        static IEnumerable<DependencyObject> Nodes(DependencyObject parent)
        {
            for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            { var child = VisualTreeHelper.GetChild(parent, index); yield return child; foreach (var nested in Nodes(child)) yield return nested; }
        }
        static async Task Click(Button button)
        {
            button.StartBringIntoView(); await Task.Delay(60);
            ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button)
                .GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke(); await Task.Delay(150);
        }
    }
}
