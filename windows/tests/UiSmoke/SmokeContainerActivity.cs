using LanStash.App.Features.Containers;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeContainerActivityRepository(string state) : IContainerManagerRepository
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public int Calls, Inventories;
    public bool Fail = state is "error" or "retry";
    public CancellationToken Token;
    public TaskCompletionSource<ContainerManagerSection<ServiceActivityEntry>> Pending { get; } = new();
    public ContainerManagerAvailability Availability => new(ContainerManagerAvailabilityStatus.InternalObserved,
        state == "unavailable" ? new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers } :
        new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers, ContainerManagerReadFeature.Events });
    public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default)
    {
        Inventories++;
        return Task.FromResult(new ContainerManagerSnapshot(ProfileId,
            ContainerManagerSection<ContainerSummary>.Available([new("synthetic-container", "Synthetic container", ContainerOperationalState.Stopped, "synthetic/web")]),
            ContainerManagerSection<ContainerResourceSummary>.Available([]), ContainerManagerSection<ContainerResourceSummary>.Available([]),
            ContainerManagerSection<ContainerResourceSummary>.Available([]), ContainerManagerSection<ServiceEventSummary>.Available([])));
    }
    public ContainerManagerSection<ServiceActivityEntry> Sample() => ContainerManagerSection<ServiceActivityEntry>.Available(state == "empty" ? [] : [
        new(new("a", null, ServiceEventLevel.Warning), string.Join("\n", Enumerable.Repeat("Synthetic <b>plain text</b>. A network operation could not finish.", 7)),
            "synthetic-account", new DateTime(2026, 10, 16, 12, 30, 45)),
        new(new("b", null, ServiceEventLevel.Information), "Synthetic container started.", "another-account", new DateTime(2026, 10, 16, 12, 25, 0)),
        new(new("c", null, ServiceEventLevel.Error), "Synthetic image download failed.", "synthetic-account", new DateTime(2026, 10, 16, 12, 20, 0))]);
    public async Task<ContainerManagerSection<ServiceActivityEntry>> LoadActivityAsync(CancellationToken token = default)
    {
        Calls++; Token = token;
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "late") return await Pending.Task;
        if (Fail) return ContainerManagerSection<ServiceActivityEntry>.Failed;
        return Sample();
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveContainerActivityAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "content";
        var repository = new SmokeContainerActivityRepository(state); var model = new ContainerManagerViewModel();
        using var page = new ContainerManagerPage(repository, model);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(220);
        if (repository.Calls != 0) throw new InvalidOperationException("未进入活动页就读取日志正文。");
        var pivot = (Pivot)page.FindName("SectionPivot"); pivot.SelectedIndex = 5; await Task.Delay(220);
        T Control<T>(string name) where T : FrameworkElement => (T)page.FindName(name);
        if (state == "loading" && Control<StackPanel>("EventsLoadingState").Visibility != Visibility.Visible) throw new InvalidOperationException("活动加载状态缺失。");
        if (state == "empty" && Control<StackPanel>("EventsEmptyState").Visibility != Visibility.Visible) throw new InvalidOperationException("活动空状态缺失。");
        if (state == "unavailable" && (repository.Calls != 0 || Control<StackPanel>("EventsUnavailableState").Visibility != Visibility.Visible)) throw new InvalidOperationException("不支持活动读取时仍发起请求。");
        if (state is "error" or "retry")
        {
            if (Control<StackPanel>("EventsErrorState").Visibility != Visibility.Visible) throw new InvalidOperationException("活动错误状态缺失。");
            if (state == "retry") { repository.Fail = false; await model.RefreshAsync(); await Task.Delay(80); if (model.ActivityReadFailed || model.Events.Count != 3) throw new InvalidOperationException("活动重试未恢复。"); }
        }
        if (state == "content" && (model.Events.Count != 3 || !model.Events[0].Message.Contains("<b>plain text</b>", StringComparison.Ordinal) ||
            !model.Events[0].TimeText.Contains("12:30", StringComparison.Ordinal))) throw new InvalidOperationException("活动正文或 NAS 本地时间未保留。");
        if (state is "filter" or "filtered")
        {
            Control<ComboBox>("ActivityLevelPicker").SelectedIndex = 2;
            Control<TextBox>("ActivitySearchBox").Text = state == "filter" ? "network operation" : "not-present"; await Task.Delay(100);
            if (model.Events.Count != (state == "filter" ? 1 : 0) || repository.Calls != 1 || model.ActivitySearch != (state == "filter" ? "network operation" : "not-present"))
                throw new InvalidOperationException($"活动本地筛选不正确：rows={model.Events.Count}, reads={repository.Calls}, search={model.ActivitySearch}, level={model.ActivityLevel}。");
            if (state == "filtered" && Control<StackPanel>("EventsFilteredEmptyState").Visibility != Visibility.Visible)
                throw new InvalidOperationException($"活动筛选空状态缺失：state={model.EventsState}, loading={model.IsActivityLoading}, visibility={Control<StackPanel>("EventsFilteredEmptyState").Visibility}。");
        }
        if (state is "leave" or "late")
        {
            pivot.SelectedIndex = 0;
            if (state == "late") { if (!repository.Token.IsCancellationRequested) throw new InvalidOperationException("离开活动页未取消读取。"); repository.Pending.SetResult(repository.Sample()); }
            await Task.Delay(100);
            if (model.Events.Count != 0 || Control<ListView>("EventsList").Items.Count != 0 || Control<TextBox>("ActivitySearchBox").Text.Length != 0)
                throw new InvalidOperationException("离开活动页未清理正文或迟到响应重新出现。");
        }
        await Task.Delay(100); await WriteSnapshotAsync(page); page.Dispose();
        if (model.Events.Count != 0 || Control<ListView>("EventsList").Items.Count != 0 || Control<TextBox>("ActivitySearchBox").Text.Length != 0)
            throw new InvalidOperationException("关闭页面仍保留活动正文。");
    }
}
