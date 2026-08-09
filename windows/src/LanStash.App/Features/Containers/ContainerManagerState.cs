using LanStash.App.Localization;
using LanStash.Domain;

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
