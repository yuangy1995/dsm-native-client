using LanStash.App.Features.Transfers;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace LanStash.App.Platform.Notifications;

internal sealed class WindowsTransferNotificationService : IForegroundTransferNotificationService, IDisposable
{
    private readonly ForegroundTransferNotificationSession _session;

    internal WindowsTransferNotificationService(Action showActivity, Func<Action, bool> dispatch,
        IForegroundTransferNotificationBackend backend) =>
        _session = new(backend, dispatch, showActivity);

    public bool IsEnabled => _session.IsEnabled;
    public void Show(ForegroundTransferNotification notification) => _session.Show(notification);
    public void Dispose() => _session.Dispose();

    internal static AppNotification BuildNotification(ForegroundTransferNotification notification, string context) =>
        new AppNotificationBuilder()
            .AddText(notification.Title)
            .AddText(notification.Message)
            .AddArgument("route", "activity")
            .AddArgument("context", context)
            .BuildNotification();

    internal sealed class WindowsNotificationBackend : IForegroundTransferNotificationBackend, IDisposable
    {
        private bool _registered;
        private bool _keepListening;
        private bool _disposed;
        private int _clients;
        public event Action<IReadOnlyDictionary<string, string>>? Invoked;
        public bool IsSupported
        {
            get { try { return !_disposed && AppNotificationManager.IsSupported(); } catch { return false; } }
        }

        internal void StartListening()
        {
            _keepListening = true;
            if (!IsSupported) return;
            try { EnsureRegistered(); }
            catch { /* 启动注册失败可由后续通知重试，不阻断启动。 */ }
        }

        public void Register()
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            EnsureRegistered();
            _clients++;
        }

        private void EnsureRegistered()
        {
            if (_registered) return;
            AppNotificationManager.Default.NotificationInvoked += NotificationInvoked;
            try { AppNotificationManager.Default.Register(); _registered = true; }
            catch
            {
                AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
                throw;
            }
        }

        public void Unregister()
        {
            if (_clients > 0) _clients--;
            if (_clients == 0 && !_keepListening) StopListening();
        }

        private void StopListening()
        {
            AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
            if (!_registered) return;
            _registered = false;
            AppNotificationManager.Default.Unregister();
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _keepListening = false;
            Invoked = null;
            try { StopListening(); }
            catch { /* 退出时不删除应用持久注册，也不重新订阅。 */ }
        }

        public void Show(ForegroundTransferNotification notification, string context)
        {
            var toast = BuildNotification(notification, context);
            AppNotificationManager.Default.Show(toast);
        }

        private void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
            Invoked?.Invoke(args.Arguments.ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal));
    }
}
