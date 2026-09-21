namespace LanStash.Domain;

public enum ContainerImagePullStage { AwaitingReceipt, Downloading, NeedsReview, Ready, Rejected }

public sealed record ContainerImagePullRequest(Guid ProfileId, string Repository, string Tag, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(ContainerImagePullRequest);
}

public sealed record ContainerImagePullResult(Guid RequestId, string Repository, string Tag,
    ContainerImagePullStage Stage, double? Percentage, MutationResult Outcome)
{
    public override string ToString() => nameof(ContainerImagePullResult);
}

public static class ContainerImagePullRules
{
    public static bool IsValidTarget(string? repository, string? tag) =>
        ContainerRegistryRules.IsValidRepository(repository) && repository == repository!.Trim() &&
        !repository.Any(char.IsWhiteSpace) && !repository.Contains('@') && !repository.Contains("://", StringComparison.Ordinal) &&
        !string.IsNullOrWhiteSpace(tag) && tag == tag.Trim() && !tag.Any(character => char.IsWhiteSpace(character) || char.IsControl(character)) &&
        tag.IndexOfAny(['/', ':', '@']) < 0 && tag != "<none>";
}
