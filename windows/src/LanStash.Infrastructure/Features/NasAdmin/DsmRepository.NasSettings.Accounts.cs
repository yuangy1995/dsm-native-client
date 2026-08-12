using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> DeleteAccountAsync(
        string accountName,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(accountName))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "deleteAccount", MutationErrorCategory.Validation, "account.delete.validation"));
        }

        return SaveSettingsAsync(
            "SYNO.Core.User", "delete",
            new Dictionary<string, string>(StringComparer.Ordinal) { ["name"] = accountName },
            "deleteAccount",
            ct => Task.CompletedTask,
            cancellationToken);
    }

    public Task<MutationResult> DeleteGroupAsync(
        string groupName,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(groupName))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "deleteGroup", MutationErrorCategory.Validation, "group.delete.validation"));
        }

        return SaveSettingsAsync(
            "SYNO.Core.Group", "delete",
            new Dictionary<string, string>(StringComparer.Ordinal) { ["name"] = groupName },
            "deleteGroup",
            ct => Task.CompletedTask,
            cancellationToken);
    }

    public Task<MutationResult> DisconnectConnectionAsync(
        string connectionId,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(connectionId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "disconnectConnection", MutationErrorCategory.Validation,
                "connection.disconnect.validation"));
        }

        return SaveSettingsAsync(
            "SYNO.Core.CurrentConnection", "delete",
            new Dictionary<string, string>(StringComparer.Ordinal) { ["id"] = connectionId },
            "disconnectConnection",
            ct => Task.CompletedTask,
            cancellationToken);
    }

    public Task<MutationResult> StartDiskTestAsync(
        string diskId,
        NasDiskTestType testType,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(diskId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "startDiskTest", MutationErrorCategory.Validation, "disk.test.validation"));
        }

        var type = testType switch
        {
            NasDiskTestType.Quick => "quick",
            NasDiskTestType.Extended => "extended",
            _ => throw new ArgumentOutOfRangeException(nameof(testType)),
        };

        return SaveSettingsAsync(
            "SYNO.Storage.CGI.Storage", "disk_test",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["disk_id"] = diskId,
                ["type"] = type,
            },
            "startDiskTest",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
