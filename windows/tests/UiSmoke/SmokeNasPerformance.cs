using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeNasPerformanceRepository(string state) : INasDetailsRepository
{
    private readonly SmokeRepository _read = new();
    public Guid ProfileId => _read.ProfileId;
    public NasDetailsAvailability Availability => _read.Availability;
    public bool CanReadPerformance => true;
    public int Calls;
    public bool Fail = state is "error" or "retry";
    public TaskCompletionSource<NasPerformanceSnapshot> Pending { get; } = new();
    public NasPerformanceSnapshot Sample() => new(ProfileId, new DateTimeOffset(2026, 10, 16, 0, 0, 0, TimeSpan.Zero).AddSeconds(Calls * 2),
        Enum.GetValues<NasPerformanceMetric>().ToDictionary(metric => metric, metric => state == "empty" || state == "partial" && metric == NasPerformanceMetric.Cpu
            ? (double?)null : NasPerformanceViewModel.IsPercent(metric) ? 15 + Calls % 35 : 1048576 + Calls * 512));
    public async Task<NasPerformanceSnapshot> LoadPerformanceAsync(CancellationToken token = default)
    {
        Calls++;
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state == "late") return await Pending.Task;
        if (Fail) throw new IOException("合成性能读取失败");
        return Sample();
    }
    public Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken token = default) => _read.LoadDetailsAsync(token);
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken token = default) => _read.LoadStorageAnalysisAsync(token);
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken token = default) => _read.LoadDeepStorageAnalysisAsync(token);
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveNasPerformanceAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "content";
        var fake = new SmokeNasPerformanceRepository(state);
        using var page = new NasDetailsPage(fake);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150);
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        Click((Button)page.FindName("PerformanceButton"));
        await Task.Delay(300);
        var dialog = (ContentDialog?)typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page)
            ?? throw new InvalidOperationException("性能入口未打开。");
        var content = (NasPerformanceDialogContent)dialog.Content;
        var model = (NasPerformanceViewModel)typeof(NasPerformanceDialogContent).GetField("_model", flags)!.GetValue(content)!;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (state == "loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("性能加载状态缺失。");
        if (state == "empty" && Control<TextBlock>("EmptyText").Visibility != Visibility.Visible) throw new InvalidOperationException("性能空状态缺失。");
        if (state is "error" or "retry")
        {
            if (!Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("性能错误状态缺失。");
            if (state == "retry") { fake.Fail = false; await content.ReloadAsync(); if (model.Error is not null || model.Latest is null) throw new InvalidOperationException("性能刷新未恢复。"); }
        }
        if (state is "content" or "metric" or "paused" or "partial")
        {
            for (var index = 0; index < 20; index++) await content.ReloadAsync();
            if (Control<ItemsControl>("Metrics").Items.Count != 15) throw new InvalidOperationException("性能指标缺失。");
            if (state == "metric")
            { Control<ComboBox>("MetricChoice").SelectedIndex = 6; if (model.SelectedMetric != NasPerformanceMetric.NetworkReceived) throw new InvalidOperationException("性能指标切换失败。"); }
            if (state == "partial" && model.Latest![NasPerformanceMetric.Cpu] is not null) throw new InvalidOperationException("未知处理器使用率被补为零。");
            if (state == "paused")
            {
                Click(Control<Button>("PauseButton")); await Task.Delay(60); var reads = fake.Calls; await Task.Delay(2200);
                if (!model.IsPaused || fake.Calls != reads) throw new InvalidOperationException("暂停后仍自动采样。");
                await content.ReloadAsync(); if (fake.Calls != reads + 1 || !model.IsPaused) throw new InvalidOperationException("手动刷新错误恢复自动采样。");
            }
        }
        if (state == "late")
        {
            page.Deactivate(); fake.Pending.SetResult(fake.Sample()); await Task.Delay(120);
            if (model.History.Count != 0 || typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page) is not null)
                throw new InvalidOperationException("断开后迟到采样更新原窗口。");
            await WriteSnapshotAsync(page); return;
        }
        await Task.Delay(150); await WriteSnapshotAsync(dialog); page.Deactivate();
    }
}
