using LanStash.Domain;

namespace LanStash.App.Features.Settings;

// 路由仅使用稳定标识；翻译、NAS 名称和文件路径不参与导航判断。
public enum WorkspaceDestination
{
    Files, Favorites, Recent, RemoteLocations, SharedLinks, Recycle,
    Photos, PhotoAlbums, PhotoFolders, PhotoSharing,
    Chat, Downloads, Containers, ContainerList, ContainerImages,
    ContainerNetworks, ContainerProjects, ContainerEvents,
    Machines, MachineHosts, MachineStorage, MachineNetworks,
    MachineImages, MachineProtection, MachineEvents,
    NasSettings, Transfers, Settings, DesktopDrive,
}

public sealed record WorkspaceRoute(
    WorkspaceDestination Destination, AppModule Module, string TitleKey, string Glyph,
    bool IsChild = false);

public static class WorkspaceRoutes
{
    public static IReadOnlyList<WorkspaceRoute> All { get; } = Array.AsReadOnly<WorkspaceRoute>(
    [
        new(WorkspaceDestination.Files, AppModule.Files, "ModuleFiles", "\uE8B7"),
        new(WorkspaceDestination.Favorites, AppModule.Files, "NativeNavFavorites", "\uE734", true),
        new(WorkspaceDestination.Recent, AppModule.Files, "NativeNavRecent", "\uE823", true),
        new(WorkspaceDestination.RemoteLocations, AppModule.Files, "NativeNavRemote", "\uE968", true),
        new(WorkspaceDestination.SharedLinks, AppModule.Files, "NativeNavSharedLinks", "\uE71B", true),
        new(WorkspaceDestination.Recycle, AppModule.Files, "NativeNavRecycle", "\uE74D", true),
        new(WorkspaceDestination.Photos, AppModule.Photos, "ModulePhotos", "\uEB9F"),
        new(WorkspaceDestination.PhotoAlbums, AppModule.Photos, "PhotosLibraryAlbums", "\uE93C", true),
        new(WorkspaceDestination.PhotoFolders, AppModule.Photos, "PhotosLibraryFolders", "\uE8B7", true),
        new(WorkspaceDestination.PhotoSharing, AppModule.Photos, "PhotosLibrarySharing", "\uE72D", true),
        new(WorkspaceDestination.Chat, AppModule.Chat, "ModuleChat", "\uE8BD"),
        new(WorkspaceDestination.Downloads, AppModule.Downloads, "ModuleDownloads", "\uE896"),
        new(WorkspaceDestination.Containers, AppModule.Containers, "ModuleContainers", "\uE7B8"),
        new(WorkspaceDestination.ContainerList, AppModule.Containers, "NativeNavContainerList", "\uE7B8", true),
        new(WorkspaceDestination.ContainerImages, AppModule.Containers, "NativeNavImages", "\uE7B9", true),
        new(WorkspaceDestination.ContainerNetworks, AppModule.Containers, "NativeNavNetworks", "\uE968", true),
        new(WorkspaceDestination.ContainerProjects, AppModule.Containers, "NativeNavProjects", "\uE8F1", true),
        new(WorkspaceDestination.ContainerEvents, AppModule.Containers, "NativeNavEvents", "\uE81C", true),
        new(WorkspaceDestination.Machines, AppModule.VirtualMachines, "ModuleVirtualMachines", "\uE7F4"),
        new(WorkspaceDestination.MachineHosts, AppModule.VirtualMachines, "NativeNavHosts", "\uE977", true),
        new(WorkspaceDestination.MachineStorage, AppModule.VirtualMachines, "NativeNavStorage", "\uEDA2", true),
        new(WorkspaceDestination.MachineNetworks, AppModule.VirtualMachines, "NativeNavNetworks", "\uE968", true),
        new(WorkspaceDestination.MachineImages, AppModule.VirtualMachines, "NativeNavImages", "\uE7B9", true),
        new(WorkspaceDestination.MachineProtection, AppModule.VirtualMachines, "NativeNavProtection", "\uE83D", true),
        new(WorkspaceDestination.MachineEvents, AppModule.VirtualMachines, "NativeNavEvents", "\uE81C", true),
        new(WorkspaceDestination.NasSettings, AppModule.NasSettings, "ModuleNasSettings", "\uE713"),
        new(WorkspaceDestination.Transfers, AppModule.Transfers, "ModuleTransfers", "\uE898"),
        new(WorkspaceDestination.Settings, AppModule.Settings, "ModuleSettings", "\uE713"),
        new(WorkspaceDestination.DesktopDrive, AppModule.Settings, "CloudDriveTitle", "\uE753", true),
    ]);

    public static WorkspaceRoute Get(WorkspaceDestination destination) =>
        All.First(route => route.Destination == destination);

    public static bool HasChildren(AppModule module) => All.Any(route => route.Module == module && route.IsChild);
}

// 一个实例只属于一个连接工作区，最多保留 64 个模块/子页记录，不保存凭据或真实路径。
public sealed class WorkspaceNavigation
{
    public const int HistoryLimit = 64;
    private readonly List<WorkspaceDestination> _history = [];
    private readonly HashSet<AppModule> _expanded = [];
    private HashSet<AppModule> _available = [];

    public WorkspaceNavigation(Guid profileId, IEnumerable<AppModule> modules)
    {
        ProfileId = profileId;
        SetAvailableModules(modules);
        Current = WorkspaceRoutes.All.First(route => _available.Contains(route.Module) && !route.IsChild).Destination;
        _expanded.Add(WorkspaceRoutes.Get(Current).Module);
    }

    public Guid ProfileId { get; }
    public WorkspaceDestination Current { get; private set; } = WorkspaceDestination.Settings;
    public bool CanGoBack => _history.Count > 0;
    public int HistoryCount => _history.Count;
    public bool IsAvailable(WorkspaceDestination destination) =>
        Enum.IsDefined(destination) && _available.Contains(WorkspaceRoutes.Get(destination).Module);
    public bool IsExpanded(AppModule module) => _expanded.Contains(module);

    public void SetAvailableModules(IEnumerable<AppModule> modules)
    {
        _available = modules.Where(Enum.IsDefined).ToHashSet();
        _available.Add(AppModule.Settings);
        _history.RemoveAll(destination => !IsAvailable(destination));
        _expanded.IntersectWith(_available);
        if (!IsAvailable(Current))
        {
            Current = WorkspaceDestination.Settings;
            _expanded.Add(AppModule.Settings);
        }
    }

    public bool Navigate(WorkspaceDestination destination)
    {
        if (!IsAvailable(destination)) return false;
        if (Current != destination)
        {
            _history.Add(Current);
            if (_history.Count > HistoryLimit) _history.RemoveAt(0);
            Current = destination;
        }
        _expanded.Add(WorkspaceRoutes.Get(destination).Module);
        return true;
    }

    public bool GoBack()
    {
        if (_history.Count == 0) return false;
        Current = _history[^1];
        _history.RemoveAt(_history.Count - 1);
        _expanded.Add(WorkspaceRoutes.Get(Current).Module);
        return true;
    }

    public void ToggleExpanded(AppModule module)
    {
        if (!_available.Contains(module) || !WorkspaceRoutes.HasChildren(module)) return;
        if (!_expanded.Remove(module)) _expanded.Add(module);
    }

    public IReadOnlyList<WorkspaceRoute> VisibleRoutes() => WorkspaceRoutes.All
        .Where(route => _available.Contains(route.Module))
        .Where(route => !route.IsChild || _expanded.Contains(route.Module))
        .ToArray();
}

public static class WorkspaceLayout
{
    public const double SidebarDefault = 241;
    public const double SidebarMinimum = 210;
    public const double SidebarMaximum = 280;
    public const double InspectorWidth = 210;
    public const double InspectorBreakpoint = 800;
    public const double SidebarBreakpoint = 900;
    public const double SurfaceRadius = 16;
    public const double WorkspaceInset = 12;

    public static double ClampSidebar(double width) => double.IsFinite(width)
        ? Math.Clamp(width, SidebarMinimum, SidebarMaximum) : SidebarDefault;
}
