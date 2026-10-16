using LanStash.App.Localization;
using LanStash.App.Features.Files;
using LanStash.Domain;
using System.Globalization;

namespace LanStash.App.Features.Containers;

public enum ContainerManagerContentState
{
    Loading,
    Empty,
    FilteredEmpty,
    Error,
    Content,
    Unavailable,
}

public enum ContainerManagerFilter
{
    All,
    Running,
    Stopped,
    Attention,
}

public sealed record ContainerItem(ContainerSummary Container)
{
    public string Id => Container.Id;
    public string Name => Container.Name;
    public ContainerOperationalState State => Container.State;
    public string? Image => Container.Image;
    public string StatusText => LocalizationService.Current.Get(State switch
    {
        ContainerOperationalState.Running => "ContainerManagerStatusRunning",
        ContainerOperationalState.Restarting => "ContainerManagerStatusRestarting",
        ContainerOperationalState.Stopped => "ContainerManagerStatusStopped",
        ContainerOperationalState.Attention => "ContainerManagerStatusNeedsAttention",
        _ => "ContainerManagerStatusUnknown",
    });
    public string ImageText => string.IsNullOrWhiteSpace(Image)
        ? LocalizationService.Current.Get("ContainerManagerValueUnavailable")
        : Image!;
    public string AutomationName => LocalizationService.Current.Format(
        "ContainerManagerItemAutomationName",
        Name,
        StatusText);
}

public sealed record ContainerResourceItem(ContainerResourceSummary Resource)
{
    public string Id => Resource.Id;
    public string Name => Resource.Name;
    public string DetailsText => Resource.Kind switch
    {
        ContainerResourceKind.Image => LocalizationService.Current.Format("ContainerImageDetails",
            Resource.ImageSizeBytes is { } size ? FileBrowserViewModel.FormatBytes(size) : LocalizationService.Current.Get("ContainerManagerValueUnavailable"),
            LocalizationService.Current.Get(Resource.IsImageInUse switch
            { true => "ContainerImageInUse", false => "ContainerImageUnused", _ => "ContainerImageUsageUnavailable" })),
        ContainerResourceKind.Project => Resource.ProjectContainerCount is { } count
            ? LocalizationService.Current.Format("ContainerProjectCount", count)
            : LocalizationService.Current.Get("ContainerProjectCountUnavailable"),
        _ => "",
    };
    public string NetworkSummary => Resource.Network is { } network
        ? LocalizationService.Current.Format("ContainerNetworkSummary", network.Driver ?? LocalizationService.Current.Get("ContainerManagerValueUnavailable"), network.ConnectedContainerCount)
        : LocalizationService.Current.Get("ContainerNetworkDetailsUnavailable");
    public string SubnetText => Resource.Network?.Subnet ?? LocalizationService.Current.Get("ContainerManagerValueUnavailable");
    public string GatewayText => Resource.Network?.Gateway ?? LocalizationService.Current.Get("ContainerManagerValueUnavailable");
    public string IpRangeText => Resource.Network?.IpRange ?? LocalizationService.Current.Get("ContainerManagerValueUnavailable");
    public string Ipv6Text => LocalizationService.Current.Get(Resource.Network?.IsIpv6Enabled switch
    { true => "ContainerNetworkIpv6Enabled", false => "ContainerNetworkIpv6Disabled", _ => "ContainerManagerValueUnavailable" });
    public string ConnectionsText => Resource.Network?.ConnectedContainerNames is { } names
        ? names.Count == 0 ? LocalizationService.Current.Get("ContainerNetworkNoConnections") : string.Join(Environment.NewLine, names)
        : LocalizationService.Current.Get("ContainerNetworkNamesUnavailable");
    public string NetworkAutomationName => LocalizationService.Current.Format("ContainerManagerItemAutomationName", Name, NetworkSummary);
    public string ResourceStatusText => Resource.Kind == ContainerResourceKind.Image ? "" : StatusText;
    public string StatusText => LocalizationService.Current.Get(Resource.State switch
    {
        ContainerOperationalState.Running => "ContainerManagerStatusRunning",
        ContainerOperationalState.Restarting => "ContainerManagerStatusRestarting",
        ContainerOperationalState.Stopped => "ContainerManagerStatusStopped",
        ContainerOperationalState.Attention => "ContainerManagerStatusNeedsAttention",
        _ => "ContainerManagerStatusUnknown",
    });
    public string AutomationName => LocalizationService.Current.Format(
        "ContainerManagerItemAutomationName",
        Name,
        Resource.Kind == ContainerResourceKind.Image ? DetailsText : LocalizationService.Current.Format("ContainerResourceStatusDetails", StatusText, DetailsText));
}

public sealed record ContainerEventItem(ServiceEventSummary Event)
{
    public ServiceActivityEntry? Activity { get; init; }
    public string Id => Event.Id;
    public string Message => Activity?.Message ?? "";
    public string Account => Activity?.Account ?? "";
    public string TimeText => Activity?.LocalTime?.ToString("G", CultureInfo.CurrentCulture) ?? Event.OccurredAt?.ToLocalTime().ToString("G", CultureInfo.CurrentCulture)
        ?? LocalizationService.Current.Get("ContainerManagerValueUnavailable");
    public string LevelText => LocalizationService.Current.Get(Event.Level switch
    {
        ServiceEventLevel.Information => "ContainerManagerEventLevelInformation",
        ServiceEventLevel.Warning => "ContainerManagerEventLevelWarning",
        ServiceEventLevel.Error => "ContainerManagerEventLevelError",
        _ => "ContainerManagerStatusUnknown",
    });
    public string AutomationName => LocalizationService.Current.Format(
        "ContainerManagerEventAutomationName",
        TimeText,
        LevelText);
    public override string ToString() => nameof(ContainerEventItem);
}
