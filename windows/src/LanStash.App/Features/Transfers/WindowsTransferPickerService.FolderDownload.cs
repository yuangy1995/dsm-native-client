using LanStash.App.Features.Files.Downloads;
using LanStash.App.Localization;
using LanStash.Domain;
using Windows.Storage;

namespace LanStash.App.Features.Transfers;

internal sealed partial class WindowsTransferPickerService
{
    private async Task RunStructuredDownloadAsync(RunningTransfer running, IReadOnlyList<FileItem> selection, string localRoot)
    {
        // 入队先返回活动编号，页面随后才能可靠接收完成事件。
        await Task.Yield();
        var status = FileDownloadBatchAttemptStatus.Failed;
        try
        {
            await _coordinator.RunAsync(new(running.ProfileId, FileDownloadSelection.SourceLocation(selection),
                selection.Count == 1 ? selection[0].Name : LocalizationService.Current.Get("FileStructureDownloadName"), 0, running.ActivityId),
                async (progress, token) =>
                {
                    var plan = await ForegroundFolderDownloadPlan.CreateAsync(_repository, selection, running.Control, token);
                    var results = plan.Entries.Select(entry => new ForegroundTransferItemResult(entry.RelativePath, entry.Item.IsDirectory,
                        ForegroundTransferItemState.Waiting)).ToArray();
                    void Publish() => _coordinator.UpdateDownloadPlan(running.ProfileId, running.ActivityId, plan.TotalBytes, results);
                    Publish();
                    // 全部源清单有效后才访问输出；已存在的顶层目标要求另选保存位置。
                    using var rootLease = ForegroundDownloadDirectoryLease.Acquire(localRoot);
                    var root = await StorageFolder.GetFolderFromPathAsync(localRoot);
                    foreach (var item in selection)
                        if (await root.TryGetItemAsync(item.Name) is not null) throw new ForegroundDownloadException(MutationErrorCategory.Conflict);
                    var failedDirectories = new List<string>();
                    long received = 0;
                    var hasFailure = false;
                    for (var index = 0; index < plan.Entries.Count; index++)
                    {
                        await running.Control.WaitAsync(token);
                        var entry = plan.Entries[index];
                        var path = ForegroundDownloadDirectoryLease.Resolve(localRoot, entry.RelativePath);
                        long itemReceived = 0;
                        results[index] = results[index] with { State = ForegroundTransferItemState.Running };
                        Publish();
                        try
                        {
                            rootLease.Validate();
                            if (failedDirectories.Any(parent => entry.RelativePath.StartsWith(parent + "/", StringComparison.Ordinal)))
                                throw new IOException("download.parent-failed");
                            using var parentLease = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(path)!);
                            if (entry.Item.IsDirectory)
                            {
                                var parent = await StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(path)!);
                                await parent.CreateFolderAsync(entry.Item.Name, CreationCollisionOption.FailIfExists);
                            }
                            else
                            {
                                await ForegroundFolderDownloadPlan.ValidateSourceAsync(_repository, entry.Item, token);
                                var destination = await WindowsTransactionalDownloadDestination.CreateAsync(path, allowReplaceExisting: false,
                                    validateTarget: () => { rootLease.Validate(); parentLease.Validate(); });
                                await _downloadService.DownloadAsync(_repository, entry.Item.Path, entry.Item.Size, destination,
                                    new DownloadProgress(value =>
                                    {
                                        itemReceived = value.BytesTransferred;
                                        progress.Report(new(received + itemReceived, plan.TotalBytes));
                                    }), token, running.Control);
                            }
                            results[index] = results[index] with { State = ForegroundTransferItemState.Completed };
                        }
                        catch (OperationCanceledException) when (token.IsCancellationRequested)
                        {
                            results[index] = results[index] with { State = ForegroundTransferItemState.Cancelled };
                            throw;
                        }
                        catch
                        {
                            hasFailure = true;
                            results[index] = results[index] with { State = ForegroundTransferItemState.Failed };
                            if (entry.Item.IsDirectory) failedDirectories.Add(entry.RelativePath);
                        }
                        finally { received += itemReceived; Publish(); }
                    }
                    if (hasFailure) throw new IOException("download.partial-failure");
                }, running.Cancellation.Token, running.Control);
            status = FileDownloadBatchAttemptStatus.Completed;
        }
        catch (OperationCanceledException) { status = FileDownloadBatchAttemptStatus.Cancelled; }
        catch { /* 活动详情保留每项结果，禁止撤销已成功保存的文件。 */ }
        finally
        {
            lock (_sync) _running.Remove(running);
            running.Cancellation.Dispose();
            running.Completion.TrySetResult();
        }
        SelectionDownloadFinished?.Invoke(new(running.ProfileId, running.ActivityId, selection.Count, status));
    }

    private sealed class DownloadProgress(Action<ForegroundTransferProgress> report) : IProgress<ForegroundTransferProgress>
    {
        public void Report(ForegroundTransferProgress value) => report(value);
    }
}
