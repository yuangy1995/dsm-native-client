namespace LanStash.Domain;

// 标签身份与底层镜像 ID 分离；删除一个标签不要求整个镜像 ID 消失。
public sealed record ContainerImageReference(string ImageId, string Repository, string Tag)
{
    public bool UsesIdentity => Tag == "<none>";
    public override string ToString() => nameof(ContainerImageReference);
}

public sealed record ContainerImageDeleteRequest(Guid ProfileId, IReadOnlyList<ContainerResourceSummary> Baselines, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(ContainerImageDeleteRequest);
}

public sealed record ContainerImageDeletionRecovery(Guid RequestId, IReadOnlyList<ContainerResourceSummary> Baselines)
{
    public override string ToString() => nameof(ContainerImageDeletionRecovery);
}

public static class ContainerImageDeletionRules
{
    public static bool CanDelete(ContainerResourceSummary target) => target is not null && target.Kind == ContainerResourceKind.Image &&
        Stable(target.Id) && Stable(target.Name) && target.Image is { } image && Stable(image.ImageId) &&
        Stable(image.Repository) && Stable(image.Tag);

    private static bool Stable(string? value) => !string.IsNullOrWhiteSpace(value) && value == value.Trim() && !value.Any(char.IsControl);
}
