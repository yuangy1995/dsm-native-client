using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeNasLogsRepository(string state) : INasDetailsRepository
{
    private readonly SmokeRepository _read = new();
    public Guid ProfileId => _read.ProfileId;
    public NasDetailsAvailability Availability => _read.Availability;
    public bool CanReadLogs => true;
    public int Calls;
    public bool Fail = state is "error" or "retry";
    public TaskCompletionSource<NasLogPage> Pending { get; } = new();
    public NasLogPage Sample(int offset, int limit) => new(ProfileId, offset, limit,
        Enumerable.Range(offset, state == "empty" || offset >= 100 ? 0 : limit).Select(index =>
            new NasLogEntry(new DateTimeOffset(2026, 10, 16, 0, 0, 0, TimeSpan.Zero).AddSeconds(index), "Synthetic service",
                index % 3 == 0 ? "warning" : index % 3 == 1 ? "error" : "info", "synthetic-account",
                index == 0 ? string.Join("\n", Enumerable.Repeat("Synthetic long log body <b>plain text</b>.", 12)) : $"Synthetic event {index}")).ToArray(),
        state == "unknown" ? null : 100, 33, 34, 33);
    public async Task<NasLogPage> LoadLogPageAsync(int offset, int limit, CancellationToken token = default)
    {
        Calls++;
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        if (state is "late" or "rebind") return await Pending.Task;
        if (Fail) throw new IOException("合成日志读取失败");
        return Sample(offset, limit);
    }
    public Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken token = default) => _read.LoadDetailsAsync(token);
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken token = default) => _read.LoadStorageAnalysisAsync(token);
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken token = default) => _read.LoadDeepStorageAnalysisAsync(token);
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveNasLogsAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "content";
        var fake = new SmokeNasLogsRepository(state);
        using var page = new NasDetailsPage(fake);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(150);
        var sections = (ListView)page.FindName("SectionList");
        sections.SelectedItem = sections.Items.OfType<NasDetailsSectionOption>().Single(item => item.Kind == NasDetailsSectionKind.Logs);
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
        var open = (Button)page.FindName("LogsButton");
        if (open.Visibility != Visibility.Visible) throw new InvalidOperationException("日志分区没有正文入口。");
        Click(open); await Task.Delay(300);
        var dialog = (ContentDialog?)typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page)
            ?? throw new InvalidOperationException("日志入口未打开。");
        var content = (NasLogsDialogContent)dialog.Content;
        var model = (NasLogsViewModel)typeof(NasLogsDialogContent).GetField("_model", flags)!.GetValue(content)!;
        T Control<T>(string name) where T : FrameworkElement => (T)content.FindName(name);
        if (state == "loading" && !Control<ProgressRing>("LoadingIndicator").IsActive) throw new InvalidOperationException("日志加载状态缺失。");
        if (state == "empty" && Control<TextBlock>("EmptyText").Visibility != Visibility.Visible) throw new InvalidOperationException("日志空状态缺失。");
        if (state is "error" or "retry")
        {
            if (!Control<InfoBar>("ErrorNotice").IsOpen) throw new InvalidOperationException("日志错误状态缺失。");
            if (state == "retry") { fake.Fail = false; await content.ReloadAsync(); if (model.Error is not null || model.Page is null) throw new InvalidOperationException("日志刷新未恢复。"); }
        }
        if (state == "content")
        {
            var rows = Control<ListView>("EntriesList").Items.Cast<NasLogRow>().ToArray();
            if (rows.Length != 50 || !rows[0].Message.Contains("<b>plain text</b>", StringComparison.Ordinal)) throw new InvalidOperationException("正文没有原样显示。");
        }
        if (state is "filtered" or "filter")
        {
            Control<ComboBox>("FilterChoice").SelectedIndex = 2;
            Control<TextBox>("SearchBox").Text = state == "filter" ? "long log" : "not-present"; await Task.Delay(100);
            if (model.VisibleEntries.Count != (state == "filter" ? 1 : 0) || fake.Calls != 1) throw new InvalidOperationException("日志本页筛选不正确。");
        }
        if (state is "paging" or "retry-page" or "unknown")
        {
            if (state == "retry-page") fake.Fail = true;
            Click(Control<Button>("NextButton")); await Task.Delay(120);
            if (state == "retry-page")
            {
                if (model.Page?.Offset != 0 || model.Error is null) throw new InvalidOperationException("翻页失败丢失原页。");
                fake.Fail = false; await content.ReloadAsync();
            }
            if (model.Page?.Offset != 50) throw new InvalidOperationException("翻页未进入原目标。");
            if (state == "unknown")
            {
                if (!Control<Button>("NextButton").IsEnabled || model.Page.Total is not null) throw new InvalidOperationException("未知总数阻断后续页。");
                Click(Control<Button>("NextButton")); await Task.Delay(120);
                if (model.CanNext || !model.CanPrevious) throw new InvalidOperationException("未知总数空页状态错误。");
            }
        }
        if (state == "size")
        {
            Control<ComboBox>("PageSizeChoice").SelectedIndex = 2; await Task.Delay(120);
            if (model.Page?.Limit != 200 || model.Page.Offset != 0) throw new InvalidOperationException("日志页大小未更新。");
        }
        if (state is "late" or "rebind")
        {
            if (state == "rebind") await page.ActivateAsync(new SmokeNasLogsRepository("content")); else page.Deactivate();
            fake.Pending.SetResult(fake.Sample(0, 50)); await Task.Delay(120);
            if (model.Page is not null || Control<ListView>("EntriesList").Items.Count != 0 || typeof(NasDetailsPage).GetField("_serviceSettingsDialog", flags)!.GetValue(page) is not null)
                throw new InvalidOperationException("连接切换后日志正文未清除。");
            await WriteSnapshotAsync(page); return;
        }
        await Task.Delay(160); await WriteSnapshotAsync(dialog); page.Deactivate();
        if (model.Page is not null || Control<ListView>("EntriesList").Items.Count != 0 || Control<TextBox>("SearchBox").Text.Length != 0)
            throw new InvalidOperationException("关闭日志窗口未清理正文和搜索。");
    }
}
