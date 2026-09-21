using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 旧签名没有用户确认的基线，不能通过它提交套件操作。
    public Task<MutationResult> ControlPackageAsync(string packageId, NasPackageAction action, CancellationToken cancellationToken = default) =>
        Task.FromResult(!StablePackageId(packageId) || !Enum.IsDefined(action)
            ? ServicePreflightFailure("controlPackage", MutationErrorCategory.Validation) : UnsupportedResult(PackageOperationName(action)));
}
