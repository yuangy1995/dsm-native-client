using LanStash.App.Localization;
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
        StatusText);
}

public sealed record ContainerEventItem(ServiceEventSummary Event)
{
    public string Id => Event.Id;
    public string TimeText => Event.OccurredAt?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture)
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
}
