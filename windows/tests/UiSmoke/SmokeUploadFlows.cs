using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeUploadRepository(string state) : IDsmRepository, IFileMutationRepository
{
    public Guid ProfileId => SmokeActivityProbe.Profile;
    public FileMutationAvailability FileMutationAvailability => new(true, false, 2, null);
    public IReadOnlyList<AppModule> AvailableModules => [];
    public int Uploads, Refreshes, Directories;
    public TaskCompletionSource Reading { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource CleanupEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource CleanupRelease { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public Stream? LastContent;
    public async Task<MutationResult> UploadFileAsync(FileUploadRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        Uploads++;
        LastContent = request.Content;
        try
        {
            var bytes = new byte[1]; long read = 0;
            while (await request.Content.ReadAsync(bytes, cancellationToken) > 0)
            {
                read++; progress?.Report(read);
                if (Uploads == 1 && read == 1 && state is "pause" or "resume" or "cancel" or "drain")
                { Reading.TrySetResult(); await Release.Task.WaitAsync(cancellationToken); }
            }
            if (read != request.Length) throw new InvalidDataException("合成上传内容长度错误。");
            return Result(state == "partial" && Uploads == 2 ? MutationResultStatus.ConfirmedFailure :
                state is "unknown" or "refresh" or "refresh-child" && Uploads == 1 ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess);
        }
        catch (OperationCanceledException)
        {
            if (state == "drain") { CleanupEntered.TrySetResult(); await CleanupRelease.Task; }
            return Result(MutationResultStatus.CancellationRequestedAfterSubmission);
        }
    }
    public Task<MutationResult?> ReviewFileUploadAsync(string folderPath, string fileName, CancellationToken cancellationToken = default, Guid? operationId = null)
    { Refreshes++; return Task.FromResult<MutationResult?>(Result(state is "refresh" or "refresh-child" ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified)); }
    public Task<FileMutationOutcome> CreateFolderAsync(CreateFolderRequest request, CancellationToken cancellationToken = default)
    {
        Directories++;
        return Task.FromResult(new FileMutationOutcome(Result(state == "folder-rejected" ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.ConfirmedSuccess),
            state == "folder-rejected" ? null : new FileItem(request.ParentPath + "/" + request.Name, request.Name, true, 0, null, null, true, true)));
    }
    private static MutationResult Result(MutationResultStatus status) => new(1, status, "uploadFile", true,
        status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission,
        new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, status == MutationResultStatus.ConfirmedFailure ? 1 : 0,
            status is MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0),
        status == MutationResultStatus.ConfirmedFailure ? MutationErrorCategory.Permission : null);
    public Task<FileMutationOutcome> RenameAsync(RenameFileItemRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length, string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveUploadFlowsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少原生 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "batch";
        var repository = new SmokeUploadRepository(state);
        var directory = Path.Combine(Path.GetTempPath(), "LanStash-upload-smoke-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "folder"); Directory.CreateDirectory(source); Directory.CreateDirectory(Path.Combine(source, "empty"));
        var first = Path.Combine(source, "first.txt"); var second = Path.Combine(source, "second.txt");
        await File.WriteAllBytesAsync(first, [1, 2, 3]); await File.WriteAllBytesAsync(second, [4, 5, 6]);
        using var coordinator = new ForegroundTransferCoordinator(); var profile = repository.ProfileId.ToString(); coordinator.ActivateProfile(profile);
        var picker = new SmokeTransferPicker(directory);
        using var transfers = new WindowsTransferPickerService(repository, coordinator, picker, picker);
        var downloads = System.Reflection.DispatchProxy.Create<IDownloadStationRepository, SmokeActivityProbe>(); ((SmokeActivityProbe)downloads).Hold = false;
        await using var page = new TransferActivityPage(coordinator, transfers, profile, downloads, new SmokeFileTaskRepository("missing"));
        var flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        ((Frame)shell.FindName("ContentFrame")).Content = page;
        ContentDialog? dialog = null;
        var finished = new TaskCompletionSource<FileUploadBatchSummary>(TaskCreationOptions.RunContinuationsAsynchronously);
        transfers.UploadBatchFinished += value => finished.TrySetResult(value.Summary);
        transfers.FolderUploadBatchFinished += value => finished.TrySetResult(value.Summary);
        try
        {
            if (state is "folder" or "folder-rejected")
            {
                var plan = await transfers.PlanFolderUploadAsync(source);
                if (plan.Plan is null || (await transfers.StartFolderUploadAsync(profile, "/sample", plan.Plan)).Status != FolderUploadBatchStartStatus.Started)
                    throw new InvalidOperationException("合成目录上传未启动。");
            }
            else if (transfers.StartUploadBatch(profile, "/sample", [first, second]) != FileUploadBatchValidationStatus.Valid)
                throw new InvalidOperationException("合成批量上传未启动。");
            if (state is "pause" or "resume" or "cancel")
            {
                await repository.Reading.Task.WaitAsync(TimeSpan.FromSeconds(3)); Render(); await Task.Delay(80);
                var parent = coordinator.GetActivities(profile).Single(item => item.ItemResults.Count == 2);
                Invoke(ButtonFor(parent.Id, "TransferActivityPause")); repository.Release.TrySetResult();
                await Task.Delay(120);
                if (repository.Uploads != 1 || coordinator.GetActivities(profile).Where(item => item.CanPause).Any(item => item.State != ForegroundTransferState.Paused))
                    throw new InvalidOperationException("暂停未覆盖整批与当前文件。");
                Render(); await Task.Delay(80);
                if (state == "pause") await WriteSnapshotAsync(root, markComplete: false);
                Invoke(ButtonFor(parent.Id, state == "cancel" ? "TransferActivityCancel.Content" : "TransferActivityResume"));
            }
            var summary = await finished.Task.WaitAsync(TimeSpan.FromSeconds(8));
            var activity = coordinator.GetActivities(profile).Single(item => item.ItemResults.Count > 0);
            if (state is "batch" or "folder" or "pause" or "resume" && (activity.State != ForegroundTransferState.Completed || repository.Uploads != 2))
                throw new InvalidOperationException("批量上传未完成：" + activity.FailureMessage);
            if (state == "folder" && (repository.Directories != 2 || summary.ConfirmedCount != 4)) throw new InvalidOperationException("空目录或逐项结果缺失。");
            if (state == "folder-rejected" && (repository.Uploads != 0 || summary.NotStartedCount != 3 || activity.ItemResults.Count(item => item.State == ForegroundTransferItemState.Failed) != 1))
                throw new InvalidOperationException("目录创建失败后仍上传或丢失未执行结果。");
            if (state == "partial" && (summary.ConfirmedCount != 1 || summary.FailedCount != 1 || activity.State != ForegroundTransferState.Failed))
                throw new InvalidOperationException("部分成功结果丢失。");
            if (state == "cancel" && (repository.Uploads != 1 || summary.NeedsReviewCount != 1 || summary.NotStartedCount != 1))
                throw new InvalidOperationException("取消后仍启动后续文件或把提交中断误报为未上传。");
            Render(); await Task.Delay(80);
            if (state is "refresh" or "refresh-child")
            {
                var child = coordinator.GetActivities(profile).Single(item => item.ItemResults.Count == 0 && item.State == ForegroundTransferState.ResultNeedsReview);
                Invoke(ButtonFor(state == "refresh" ? activity.Id : child.Id, "FileTaskDetails.Content")); await Task.Delay(160);
                dialog = (ContentDialog)typeof(TransferActivityPage).GetField("_detailsDialog", flags)!.GetValue(page)!;
                Invoke(Nodes(dialog).OfType<Button>().Single(button => Equals(button.Content, LocalizationService.Current.Get("FileTaskRefresh"))));
                for (var i = 0; i < 40 && coordinator.GetActivities(profile).Any(item => item.State == ForegroundTransferState.ResultNeedsReview); i++) await Task.Delay(50);
                if (repository.Uploads != 2 || repository.Refreshes != 1 || coordinator.GetActivities(profile).Any(item => item.State != ForegroundTransferState.Completed))
                    throw new InvalidOperationException("只读刷新重传文件或未更新父批次。");
                if (state == "refresh")
                {
                    var list = Nodes(dialog).OfType<ListView>().Single();
                    var completed = LocalizationService.Current.Get("TransferUploadItemCompleted");
                    for (var i = 0; i < 40 && Nodes(list).OfType<TextBlock>().Count(block => block.Text == completed) != 2; i++)
                    { dialog.UpdateLayout(); await Task.Delay(50); }
                    if (Nodes(list).OfType<TextBlock>().Count(block => block.Text == completed) != 2)
                        throw new InvalidOperationException("刷新后详情仍显示旧的逐项结果。");
                }
            }
            else if (state is not ("pause" or "resume"))
            {
                Invoke(ButtonFor(activity.Id, "FileTaskDetails.Content")); await Task.Delay(160);
                dialog = (ContentDialog)typeof(TransferActivityPage).GetField("_detailsDialog", flags)!.GetValue(page)!;
            }
            if (state != "pause") await WriteSnapshotAsync(dialog ?? root, markComplete: false);
            dialog?.Hide(); dialog = null; MarkSnapshotComplete();
        }
        finally
        {
            dialog?.Hide(); repository.Release.TrySetResult(); transfers.Dispose(); await page.SetWindowVisibleAsync(false);
            if (!Path.GetFullPath(directory).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("合成清理边界错误。");
            Directory.Delete(directory, recursive: true);
        }
        void Render() => typeof(TransferActivityPage).GetMethod("RenderActivities", flags)!.Invoke(page, []);
        Button ButtonFor(Guid id, string key) => Nodes(page).OfType<Button>().Single(button => button.Visibility == Visibility.Visible &&
            button.Tag is ForegroundTransferActivity item && item.Id == id && Equals(button.Content, LocalizationService.Current.Get(key)));
        static void Invoke(Button button) => ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button).GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
        static IEnumerable<DependencyObject> Nodes(DependencyObject node)
        { yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Nodes(VisualTreeHelper.GetChild(node, i))) yield return child; }
    }
}
