namespace LanStash.Domain;

public sealed record ContainerNetworkDeleteRequest(Guid ProfileId, IReadOnlyList<ContainerResourceSummary> Baselines, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(ContainerNetworkDeleteRequest);
}
public sealed record ContainerNetworkDeletionRecovery(string Id, string Name)
{
    public override string ToString() => nameof(ContainerNetworkDeletionRecovery);
}
public static class ContainerNetworkDeletionRules
{
    public static bool CanDelete(ContainerResourceSummary target) => target is not null && target.Kind == ContainerResourceKind.Network &&
        Stable(target.Id) && Stable(target.Name) && target.Name is not ("bridge" or "host" or "none") &&
        target.Network is { ConnectedContainerCount: 0, IsIpv6Enabled: not null } details && Stable(details.Driver) &&
        (details.ConnectedContainerNames is null || details.ConnectedContainerNames.Count == 0);
    private static bool Stable(string? value) => !string.IsNullOrWhiteSpace(value) && value == value.Trim() && !value.Any(char.IsControl);
}
