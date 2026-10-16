using LanStash.App.Features.Containers;
using LanStash.App.Localization;
using LanStash.App.Views;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.ViewModels;

internal sealed class SmokeContainerResourcesRepository : IContainerManagerRepository
{
    public Guid ProfileId { get; } = Guid.NewGuid();
    public int Reads;
    public ContainerManagerAvailability Availability => new(ContainerManagerAvailabilityStatus.InternalObserved,
        Enum.GetValues<ContainerManagerReadFeature>().ToHashSet());
    public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default)
    {
        Reads++;
        ContainerResourceSummary Resource(string name, ContainerResourceKind kind) => new(name, name, kind, ContainerOperationalState.Unknown);
        return Task.FromResult(new ContainerManagerSnapshot(ProfileId, ContainerManagerSection<ContainerSummary>.Available([]),
            ContainerManagerSection<ContainerResourceSummary>.Available([
                Resource("synthetic/web:latest", ContainerResourceKind.Image) with { ImageSizeBytes = 2097152, IsImageInUse = true },
                Resource("synthetic/web:stable", ContainerResourceKind.Image) with { ImageSizeBytes = 2097152, IsImageInUse = false },
                Resource("synthetic/legacy:latest", ContainerResourceKind.Image)]),
            ContainerManagerSection<ContainerResourceSummary>.Available([
                Resource("Application", ContainerResourceKind.Network) with { Network = new("bridge", 1, ["Synthetic container"], "192.0.2.0/24", "192.0.2.1", null, false) },
                Resource("External", ContainerResourceKind.Network) with { Network = new("macvlan", 0, [], null, null, null, false) }]),
            ContainerManagerSection<ContainerResourceSummary>.Available([
                Resource("Synthetic project", ContainerResourceKind.Project) with { State = ContainerOperationalState.Running, ProjectContainerCount = 2 },
                Resource("Synthetic empty project", ContainerResourceKind.Project) with { ProjectContainerCount = 0 },
                Resource("Synthetic legacy project", ContainerResourceKind.Project)]), ContainerManagerSection<ServiceEventSummary>.Available([])));
    }
}

internal static partial class SmokeSnapshot
{
    private static async Task SaveContainerResourcesAsync(FrameworkElement root)
    {
        if (root is not Frame { Content: ShellPage shell }) throw new InvalidOperationException("缺少合成 Shell。");
        var state = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_STATE") ?? "images";
        var repository = new SmokeContainerResourcesRepository(); var model = new ContainerManagerViewModel();
        using var page = new ContainerManagerPage(repository, model);
        ((Frame)shell.FindName("ContentFrame")).Content = page; await Task.Delay(220);
        T Control<T>(string name) where T : FrameworkElement => (T)page.FindName(name);
        var pivot = Control<Pivot>("SectionPivot"); pivot.SelectedIndex = state == "images" ? 2 : state == "projects" ? 4 : 3;
        await Task.Delay(200);
        static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            { var child = VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
        }
        if (state is "images" or "projects")
        {
            var list = Control<ListView>(state == "images" ? "ImagesList" : "ProjectsList");
            var displayed = Descendants(list).OfType<TextBlock>().Select(item => item.Text).ToArray();
            var expected = state == "images" ? model.Images : model.Projects;
            if (list.Items.Count != 3 || expected.Any(item => !displayed.Contains(item.DetailsText)))
                throw new InvalidOperationException("资源元数据未出现在原生列表。");
            if (state == "images" && (displayed.Contains(LocalizationService.Current.Get("ContainerManagerStatusUnknown")) ||
                !expected[0].DetailsText.Contains("2") || !expected[2].DetailsText.Contains(LocalizationService.Current.Get("ContainerImageUsageUnavailable"))))
                throw new InvalidOperationException("映像大小/使用状态缺失或错误显示运行状态。");
            if (state == "projects" && !expected[2].DetailsText.Contains(LocalizationService.Current.Get("ContainerProjectCountUnavailable")))
                throw new InvalidOperationException("项目未知容器数被当成零。");
        }
        if (state is "filter" or "filtered" or "clear")
        {
            var search = Control<TextBox>("NetworkSearchBox"); search.Text = state == "filter" ? "BRIDGE" : "missing";
            await Task.Delay(100);
            if (model.Networks.Count != (state == "filter" ? 1 : 0) || repository.Reads != 1 || model.TotalNetworkCount != 2 ||
                Control<TextBlock>("OverviewNetworksCount").Text != "2") throw new InvalidOperationException("网络筛选改变总数或发出重复请求。");
            if (state != "filter" && Control<StackPanel>("NetworksFilteredEmptyState").Visibility != Visibility.Visible)
                throw new InvalidOperationException("网络筛选空状态缺失。");
            if (state == "clear")
            {
                ((IInvokeProvider)new ButtonAutomationPeer(Control<Button>("NetworkClearButton")).GetPattern(PatternInterface.Invoke)).Invoke();
                await Task.Delay(100);
                if (model.Networks.Count != 2 || search.Text != "" || Control<ListView>("NetworksList").Visibility != Visibility.Visible)
                    throw new InvalidOperationException("清除筛选没有恢复网络列表。");
            }
        }
        await WriteSnapshotAsync(page);
    }
}
