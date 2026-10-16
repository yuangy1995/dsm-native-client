using LanStash.App.Features.Downloads;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeDownloadReadRepository(string state) : IDownloadStationRepository
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available,
        new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks, DownloadStationReadFeature.TaskAdvancedDetails, DownloadStationReadFeature.RssSummary });
    public DownloadTask TaskItem { get; } = new("one", "Synthetic download", "downloading", 1048576, 524288, 65536, 4096, "downloads", null);
    public int RssWrites, Reviews, Continues, Cancels;
    private DownloadRssSite _site = new(1, new string('a', 64), "Synthetic releases", false, 1700000000);
    private DownloadActionInfo? _record;
    public async Task<DownloadTaskDetails> LoadTaskDetailsAsync(string id, CancellationToken token = default)
    {
        if (state == "details-loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "details-error") throw new IOException("合成详情失败");
        return new(TaskItem, "bt", "synthetic-user", 1700000000,
            state == "details-missing" ? null : state == "details-empty" ? [] : [new("Synthetic large file.iso", 1048576, 524288, "normal")],
            state == "details-missing" ? null : state == "details-empty" ? [] : [new("https://tracker.invalid", "working", 3, 5, 30)],
            state == "details-missing" ? null : state == "details-empty" ? [] : [new("peer.invalid", "Synthetic client", 0.5, 4096, 1024)]);
    }
    public async Task<IReadOnlyList<DownloadRssSite>> ListRssSitesAsync(CancellationToken token = default)
    {
        if (state == "rss-loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "rss-error") throw new IOException("合成订阅读取失败");
        return state == "rss-empty" ? [] : [_site];
    }
    public Task<IReadOnlyList<DownloadRssFeed>> ListRssFeedsAsync(int siteId, CancellationToken token = default) => Task.FromResult<IReadOnlyList<DownloadRssFeed>>(
        state == "rss-no-items" ? [] : [new("one", "Synthetic release image", 1048576, 1700000000, "https://source.invalid/release"), new("two", "Synthetic release notes", 2048, 1700000020, "https://source.invalid/notes")]);
    public Task<DownloadActionInfo> RefreshRssSiteAsync(DownloadRssSite site, CancellationToken token = default)
    { RssWrites++; _site = site with { LastUpdate = site.LastUpdate + 1 }; return Task.FromResult(new DownloadActionInfo(Guid.NewGuid(), ProfileId, DownloadActionKind.RefreshRss, DateTimeOffset.UtcNow, [new("1", DownloadActionStage.Confirmed, null)])); }
    public async Task<IReadOnlyList<DownloadActionInfo>> LoadDownloadActionsAsync(CancellationToken token = default)
    {
        if (state == "recovery-loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "recovery-error") throw new IOException("合成恢复记录读取失败");
        if (state == "recovery-empty") return [];
        _record ??= new(Guid.NewGuid(), ProfileId, state == "recovery-create" ? DownloadActionKind.CreateFile : DownloadActionKind.Pause,
            DateTimeOffset.FromUnixTimeSeconds(1700000000), state == "recovery-create" ? [new(new string('a', 64), DownloadActionStage.Unknown, null)]
                : [new("one", DownloadActionStage.Unknown, null, TaskItem), new("two", DownloadActionStage.NotStarted, null, TaskItem with { Id = "two", Title = "Synthetic second download" })]);
        return [_record];
    }
    public Task<DownloadActionInfo> ReviewDownloadActionAsync(Guid id, CancellationToken token = default)
    { Reviews++; _record = _record! with { Items = _record!.Items.Select(item => item.Stage == DownloadActionStage.Unknown ? item with { Stage = DownloadActionStage.Confirmed } : item).ToArray() }; return Task.FromResult(_record); }
    public Task<DownloadActionInfo> ContinueDownloadActionAsync(Guid id, CancellationToken token = default)
    { Continues++; _record = _record! with { Items = _record!.Items.Select(item => item.Stage == DownloadActionStage.NotStarted ? item with { Stage = DownloadActionStage.Confirmed } : item).ToArray() }; return Task.FromResult(_record); }
    public Task<DownloadActionInfo> CancelDownloadActionRemainderAsync(Guid id, CancellationToken token = default)
    { Cancels++; _record = _record! with { Items = _record!.Items.Select(item => item.Stage == DownloadActionStage.NotStarted ? item with { Stage = DownloadActionStage.Cancelled } : item).ToArray() }; return Task.FromResult(_record); }
    public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken token = default) => Task.FromResult(new DownloadTaskPage([TaskItem], 0, 1, 1, null, false));
    public async Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken token = default) => new(ProfileId, await ListTasksAsync(offset, limit, token), new(DownloadStationSectionStatus.Unavailable, null), new(DownloadStationSectionStatus.Unavailable, null));
    public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken token = default) => throw new NotSupportedException();
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveDownloadReadActionsAsync(FrameworkElement root)
    {
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "details-ready";
        var repository = new SmokeDownloadReadRepository(state);
        static IEnumerable<DependencyObject> Nodes(DependencyObject value)
        { yield return value; for (var index = 0; index < VisualTreeHelper.GetChildrenCount(value); index++) foreach (var child in Nodes(VisualTreeHelper.GetChild(value, index))) yield return child; }
        static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        string L(string key) => Localization.LocalizationService.Current.Get(key);
        DownloadTaskDetailsModel? details = null; DownloadRssModel? rss = null; DownloadRecoveryModel? recovery = null;
        UserControl content; IDisposable model; Task load; string title;
        if (state.StartsWith("details", StringComparison.Ordinal))
        { details = new(repository, repository.TaskItem); model = details; content = new DownloadTaskDetailsContent(details); title = "DownloadDetailsEntry.Content"; load = details.LoadAsync(); }
        else if (state.StartsWith("rss", StringComparison.Ordinal))
        { rss = new(repository); model = rss; content = new DownloadRssContent(rss); title = "DownloadRssTitle"; load = rss.LoadAsync(); }
        else
        { recovery = new(repository); model = recovery; content = new DownloadRecoveryContent(recovery); title = "DownloadActionHistory"; load = recovery.LoadAsync(); }
        var dialog = new ContentDialog { XamlRoot = root.XamlRoot, RequestedTheme = root.ActualTheme, Title = L(title), Content = content,
            CloseButtonText = L("ActionClose"), DefaultButton = ContentDialogButton.Close };
        if (!state.EndsWith("loading", StringComparison.Ordinal)) await load;
        var showing = dialog.ShowAsync();
        try
        {
            await Task.Delay(200); dialog.UpdateLayout();
            if (state.EndsWith("loading", StringComparison.Ordinal) && !Nodes(content).OfType<ProgressRing>().Any(ring => ring.IsActive)) throw new InvalidOperationException("下载加载状态缺失。");
            if (state.EndsWith("error", StringComparison.Ordinal) && !Nodes(content).OfType<InfoBar>().Any(bar => bar.IsOpen)) throw new InvalidOperationException("下载错误恢复入口缺失。");
            if (details is not null && state is "details-ready" or "details-empty" or "details-missing")
            {
                if (Nodes(content).OfType<Expander>().Count() != 3) throw new InvalidOperationException("下载详情分区缺失。");
                if (state == "details-ready" && !Nodes(content).OfType<TextBlock>().Any(block => block.Text == "Synthetic large file.iso")) throw new InvalidOperationException("任务文件详情未显示。");
                if (state is "details-empty" or "details-missing" && !Nodes(content).OfType<TextBlock>().Any(block => block.Text == L(state == "details-empty" ? "DownloadDetailsNoItems" : "DownloadDetailsNotProvided"))) throw new InvalidOperationException("空详情或未提供字段没有区分。");
            }
            if (rss is not null && state is "rss-ready" or "rss-select" or "rss-filtered" or "rss-update")
            {
                if (rss.Feeds.Count != 2) throw new InvalidOperationException("订阅条目丢失。");
                var list = Nodes(content).OfType<ListView>().Single();
                if (state == "rss-select") { list.SelectedIndex = 0; if (rss.SelectedFeed?.DownloadUri != "https://source.invalid/release" || repository.RssWrites != 0) throw new InvalidOperationException("选择条目未保留明确来源或产生写入。"); }
                if (state == "rss-filtered") { rss.Search("no-match"); if (list.Items.Count != 0 || rss.SelectedFeed is not null) throw new InvalidOperationException("订阅筛选空状态错误。"); }
                if (state == "rss-update")
                {
                    Invoke(Nodes(content).OfType<Button>().Single(button => button.Content as string == L("DownloadRssUpdate")));
                    for (var attempt = 0; attempt < 50 && (repository.RssWrites == 0 || rss.IsUpdating || rss.IsLoading); attempt++) await Task.Delay(20);
                    if (repository.RssWrites != 1 || rss.FeedbackKey != "DownloadRssUpdated") throw new InvalidOperationException("订阅更新没有完成单项结果流程。");
                }
            }
            if (recovery is not null && state is "recovery-review" or "recovery-cancel")
            {
                if (!recovery.CanReview || recovery.CanContinue || !recovery.CanCancel) throw new InvalidOperationException("恢复初始门禁错误。");
                if (state == "recovery-review")
                {
                    Invoke(Nodes(content).OfType<Button>().Single(button => button.Content as string == L("DownloadActionRefresh")));
                    for (var attempt = 0; attempt < 50 && (repository.Reviews == 0 || recovery.IsBusy); attempt++) await Task.Delay(20);
                    if (repository.Reviews != 1 || repository.Continues != 0 || !recovery.CanContinue) throw new InvalidOperationException("只读恢复自动执行了剩余任务。");
                    Invoke(Nodes(content).OfType<Button>().Single(button => button.Content as string == L("DownloadBatchContinue")));
                    for (var attempt = 0; attempt < 50 && (repository.Continues == 0 || recovery.IsBusy); attempt++) await Task.Delay(20);
                    if (repository.Continues != 1 || recovery.Selected!.IsPending) throw new InvalidOperationException("明确继续未结束原任务。");
                }
                else
                {
                    Invoke(Nodes(content).OfType<Button>().Single(button => button.Content as string == L("DownloadBatchStopRemaining")));
                    for (var attempt = 0; attempt < 50 && (repository.Cancels == 0 || recovery.IsBusy); attempt++) await Task.Delay(20);
                    if (repository.Cancels != 1 || !recovery.CanReview || recovery.CanCancel || repository.Continues != 0) throw new InvalidOperationException("取消剩余项清除了未知保护。");
                }
            }
            if (dialog.ActualTheme != root.ActualTheme || content.ActualWidth <= 0 || content.ActualHeight <= 0) throw new InvalidOperationException("下载弹窗主题或布局错误。");
            await Task.Delay(100); dialog.UpdateLayout(); await WriteSnapshotAsync(dialog);
        }
        finally { model.Dispose(); (content as IDisposable)?.Dispose(); dialog.Hide(); await showing; await load; }
    }
}
