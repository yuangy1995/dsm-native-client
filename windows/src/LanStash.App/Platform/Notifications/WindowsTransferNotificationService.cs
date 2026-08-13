using LanStash.App.Features.Transfers;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace LanStash.App.Platform.Notifications;

internal sealed class WindowsTransferNotificationService(
    Action showActivity) : IForegroundTransferNotificationService, IDisposable
{
    private bool _registered;

    public bool IsEnabled => IsNotificationSupported();

    public void Show(ForegroundTransferNotification notification)
    {
        ArgumentNullException.ThrowIfNull(notification);
        if (!TryRegister())
        {
            return;
        }

        try
        {
            var toast = new AppNotificationBuilder()
                .AddText(notification.Title)
                .AddText(notification.Message)
                .AddArgument("route", "activity")
                .BuildNotification();
            AppNotificationManager.Default.Show(toast);
        }
        catch
        {
            _registered = false;
        }
    }

    internal void HandleInvoked(string arguments)
    {
        if (string.Equals(arguments, "route=activity", StringComparison.Ordinal) ||
            arguments.Contains("route=activity", StringComparison.Ordinal))
        {
            showActivity();
        }
    }

    private bool TryRegister()
    {
        if (_registered)
        {
            return true;
        }
        if (!IsNotificationSupported())
        {
            return false;
        }

        try
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
            AppNotificationManager.Default.NotificationInvoked += NotificationInvoked;
            AppNotificationManager.Default.Register();
            _registered = true;
            return true;
        }
        catch
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
            _registered = false;
            return false;
        }
    }

    private void NotificationInvoked(
        AppNotificationManager sender,
        AppNotificationActivatedEventArgs args) =>
        HandleInvoked(args.Argument);

    private static bool IsNotificationSupported()
    {
        try
        {
            return AppNotificationManager.IsSupported();
        }
        catch
        {
            return false;
        }
    }

    public void Dispose()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
        }
        catch
        {
        }
        _registered = false;
    }
}
