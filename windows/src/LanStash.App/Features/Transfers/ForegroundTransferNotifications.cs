using LanStash.App.Localization;

namespace LanStash.App.Features.Transfers;

internal enum ForegroundTransferNotificationKind
{
    Completed,
    Failed,
    NeedsReview,
}

internal sealed record ForegroundTransferNotification(
    ForegroundTransferNotificationKind Kind,
    ForegroundTransferDirection Direction,
    string Title,
    string Message);

internal interface IForegroundTransferNotificationService
{
    bool IsEnabled { get; }

    void Show(ForegroundTransferNotification notification);
}

internal sealed class NullForegroundTransferNotificationService
    : IForegroundTransferNotificationService
{
    public static NullForegroundTransferNotificationService Instance { get; } = new();

    public bool IsEnabled => false;

    public void Show(ForegroundTransferNotification notification)
    {
    }
}

internal static class ForegroundTransferNotificationFactory
{
    public static ForegroundTransferNotification? Create(
        ForegroundTransferActivity activity)
    {
        if (activity.Source != ForegroundTransferSource.App)
        {
            return null;
        }

        var localization = LocalizationService.Current;
        return activity.State switch
        {
            ForegroundTransferState.Completed => new(
                ForegroundTransferNotificationKind.Completed,
                activity.Direction,
                localization.Get("TransferNotificationCompletedTitle"),
                activity.Direction == ForegroundTransferDirection.Upload
                    ? localization.Get("TransferNotificationUploadCompletedMessage")
                    : localization.Get("TransferNotificationDownloadCompletedMessage")),
            ForegroundTransferState.ResultNeedsReview => new(
                ForegroundTransferNotificationKind.NeedsReview,
                activity.Direction,
                localization.Get("TransferNotificationReviewTitle"),
                localization.Get("TransferNotificationReviewMessage")),
            ForegroundTransferState.Failed => new(
                ForegroundTransferNotificationKind.Failed,
                activity.Direction,
                localization.Get("TransferNotificationFailedTitle"),
                localization.Get("TransferNotificationFailedMessage")),
            _ => null,
        };
    }
}
