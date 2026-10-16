using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.ViewModels;

internal sealed class SmokeNasAnalysisRepository(string state) : INasDetailsRepository
{
    private readonly SmokeRepository _read = new();
    public Guid ProfileId => _read.ProfileId;
    public NasDetailsAvailability Availability => _read.Availability;
    public TaskCompletionSource<NasDetailsSection<NasStorageAnalysisSummary>> Pending { get; } = new();
    public int DeepReads;
    public static NasDetailsSection<NasStorageAnalysisSummary> Content(bool partial = false) => new(NasDetailsSectionStatus.Available,
        [new(20, 120, 120 * 1024, partial,
            Enum.GetValues<NasStorageAnalysisCategory>().Select((category, index) => new NasStorageCategorySummary(category, index == 0 ? 18 : 17, (index == 0 ? 18 : 17) * 1024)).ToArray(),
            Enumerable.Range(1, 10).Select(index => File(index)).ToArray(), [File(1), File(2)], [File(3), File(4)],
            [new("Synthetic matching.txt", 1024, 2, true)], true, 25,
            OwnerSummary: new(120, 10), AccessTimeSummary: new(120, DateTimeOffset.UnixEpoch))
        {
            Shares = Enumerable.Range(1, 20).Select(index => new NasStorageDirectorySummary($"Synthetic share {index}", 6, 6144)).ToArray(),
            Owners = Enumerable.Range(1, 10).Select(index => new NasStorageOwnerUsage($"Synthetic owner {index}", 12, 12288)).ToArray(),
            LeastRecentlyAccessedFiles = [File(1), File(2), File(3)],
        }], IsTruncated: partial);
    private static NasStorageFileCandidate File(int index) => new($"Synthetic file {index}.txt", 1024, DateTimeOffset.UnixEpoch.AddDays(index))
        { AccessedAt = DateTimeOffset.UnixEpoch.AddDays(index + 1) };
    public async Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken token = default)
    {
        if (state == "loading") await Task.Delay(Timeout.Infinite, token);
        var section = state switch
        {
            "empty" => new NasDetailsSection<NasStorageAnalysisSummary>(NasDetailsSectionStatus.Available, []),
            "error" => new NasDetailsSection<NasStorageAnalysisSummary>(NasDetailsSectionStatus.Failed, []),
            "unavailable" => new NasDetailsSection<NasStorageAnalysisSummary>(NasDetailsSectionStatus.Unavailable, []),
            _ => Content(state == "partial"),
        };
        return (await _read.LoadDetailsAsync(token)) with { StorageAnalysis = section };
    }
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken token = default) => Task.FromResult(Content());
    public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken token = default)
    { DeepReads++; return state == "cancel" ? Pending.Task : Task.FromResult(Content()); }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveNasAnalysisAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "content";
        var fake = new SmokeNasAnalysisRepository(state);
        using var page = new NasDetailsPage(fake);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(180);
        var flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var model = (NasDetailsViewModel)typeof(NasDetailsPage).GetField("_viewModel", flags)!.GetValue(page)!;
        if (state == "loading") model.SelectSection(NasDetailsSectionKind.StorageAnalysis);
        else ((ListView)page.FindName("SectionList")).SelectedItem = model.Sections.Single(option => option.Kind == NasDetailsSectionKind.StorageAnalysis);
        await Task.Delay(80);
        var expected = state switch { "loading" => NasDetailsContentState.Loading, "empty" => NasDetailsContentState.Empty,
            "error" => NasDetailsContentState.Error, "unavailable" => NasDetailsContentState.Unavailable, _ => NasDetailsContentState.Content };
        if (model.ContentState != expected) throw new InvalidOperationException("空间分析状态不符合预期。");
        if (state == "partial" && !model.SectionNoticeIsOpen) throw new InvalidOperationException("不完整空间分析未提示。");
        if (state is "content" or "bottom" or "deep" or "cancel")
        {
            if (model.Rows.Count <= 50 || !model.Rows.Any(row => row.Id == "storage-analysis-share-19") ||
                !model.Rows.Any(row => row.Id == "storage-analysis-owner-9") || !model.Rows.Any(row => row.Id == "storage-analysis-access-2") ||
                !model.Rows.Any(row => row.Id == "storage-analysis-duplicate-1")) throw new InvalidOperationException("空间分析维度被截断。");
            if (state is "deep" or "cancel")
            {
                static void Click(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                Click((Button)page.FindName("RunDeepStorageAnalysisButton")); await Task.Delay(80);
                if (fake.DeepReads != 1) throw new InvalidOperationException("深入分析入口未调用原仓储。");
                if (state == "cancel")
                {
                    if (!model.IsStorageAnalysisRunning) throw new InvalidOperationException("深入分析没有显示执行中。");
                    Click((Button)page.FindName("CancelStorageAnalysisButton")); await Task.Delay(60); fake.Pending.SetResult(new(NasDetailsSectionStatus.Available, [])); await Task.Delay(100);
                    if (!model.StorageAnalysisWasCancelled || model.Rows.Count <= 50) throw new InvalidOperationException("取消后的迟到结果覆盖了原分析。");
                }
            }
            if (state == "bottom") ((ListView)page.FindName("DetailsList")).ScrollIntoView(model.Rows[^1], ScrollIntoViewAlignment.Leading);
        }
        await Task.Delay(150); await WriteSnapshotAsync(page); page.Deactivate();
    }
}
