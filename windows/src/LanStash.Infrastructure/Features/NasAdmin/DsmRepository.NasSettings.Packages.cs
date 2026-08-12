using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> ControlPackageAsync(
        string packageId,
        NasPackageAction action,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(packageId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "controlPackage", MutationErrorCategory.Validation, "package.control.validation"));
        }

        var method = action switch
        {
            NasPackageAction.Start => "start",
            NasPackageAction.Stop => "stop",
            NasPackageAction.Uninstall => "uninstall",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

        var operation = action switch
        {
            NasPackageAction.Start => "startPackage",
            NasPackageAction.Stop => "stopPackage",
            NasPackageAction.Uninstall => "uninstallPackage",
            _ => throw new ArgumentOutOfRangeException(nameof(action)),
        };

        return SaveSettingsAsync(
            "SYNO.Core.Package", method,
            new Dictionary<string, string>(StringComparer.Ordinal) { ["id"] = packageId },
            operation,
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
