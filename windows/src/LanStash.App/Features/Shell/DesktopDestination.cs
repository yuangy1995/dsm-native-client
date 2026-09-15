using LanStash.Domain;

namespace LanStash.App.Features.Shell;

public enum DesktopSection
{
    Root, Favorites, Recent, Recycle, RemoteLocations, SharedLinks,
    PhotoFolders, PhotoAlbums, PhotoSharing,
    ContainerImages, ContainerNetworks, ContainerProjects, ContainerEvents,
    VirtualHosts, VirtualStorage, VirtualNetworks, VirtualImages, VirtualProtection, VirtualEvents,
}

public readonly record struct DesktopDestination(AppModule Module, DesktopSection Section = DesktopSection.Root);
public sealed record DesktopNavigationEntry(DesktopDestination Destination, string TitleKey, string Glyph);

/// <summary>按 Mac WorkspaceSection 组织；稳定标识符与本地化文案分离。</summary>
public static class DesktopNavigationCatalog
{
    public const double DefaultSidebarWidth = 241;
    public const double MinimumSidebarWidth = 210;
    public const double MaximumSidebarWidth = 280;
    public static double ClampSidebarWidth(double width) => double.IsFinite(width)
        ? Math.Clamp(width, MinimumSidebarWidth, MaximumSidebarWidth) : DefaultSidebarWidth;

    private static readonly IReadOnlyList<DesktopNavigationEntry> Entries = Array.AsReadOnly<DesktopNavigationEntry>([
        new(new(AppModule.Files, DesktopSection.Favorites), "DesktopNavFavorites", "\uE734"),
        new(new(AppModule.Files, DesktopSection.Recent), "DesktopNavRecent", "\uE823"),
        new(new(AppModule.Files, DesktopSection.Recycle), "DesktopNavRecycle", "\uE74D"),
        new(new(AppModule.Files, DesktopSection.RemoteLocations), "DesktopNavRemote", "\uE774"),
        new(new(AppModule.Files, DesktopSection.SharedLinks), "DesktopNavSharedLinks", "\uE71B"),
        new(new(AppModule.Photos, DesktopSection.PhotoFolders), "PhotosLibraryFolders", "\uE8B7"),
        new(new(AppModule.Photos, DesktopSection.PhotoAlbums), "PhotosLibraryAlbums", "\uE93C"),
        new(new(AppModule.Photos, DesktopSection.PhotoSharing), "PhotosLibrarySharing", "\uE72D"),
        new(new(AppModule.Containers, DesktopSection.ContainerImages), "DesktopNavImages", "\uE7B8"),
        new(new(AppModule.Containers, DesktopSection.ContainerNetworks), "DesktopNavNetworks", "\uE968"),
        new(new(AppModule.Containers, DesktopSection.ContainerProjects), "DesktopNavProjects", "\uE8F1"),
        new(new(AppModule.Containers, DesktopSection.ContainerEvents), "DesktopNavEvents", "\uE81C"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualHosts), "DesktopNavHosts", "\uEDA2"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualStorage), "DesktopNavStorage", "\uE7F1"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualNetworks), "DesktopNavNetworks", "\uE968"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualImages), "DesktopNavImages", "\uE7B8"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualProtection), "DesktopNavProtection", "\uE72E"),
        new(new(AppModule.VirtualMachines, DesktopSection.VirtualEvents), "DesktopNavEvents", "\uE81C"),
    ]);

    public static IEnumerable<DesktopNavigationEntry> Children(AppModule module) =>
        Entries.Where(entry => entry.Destination.Module == module);
    public static bool IsValid(DesktopDestination destination) =>
        Enum.IsDefined(destination.Module) && (destination.Section == DesktopSection.Root ||
            Entries.Any(entry => entry.Destination == destination));
    public static bool IsFooterModule(AppModule module) => module is AppModule.Transfers or AppModule.NasSettings;
}
