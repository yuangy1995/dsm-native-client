using LanStash.App.Features.Chat;
using LanStash.App.Features.Settings;
using LanStash.App.Features.Transfers;
using LanStash.App.Views;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel
{
    private sealed record ConnectedWorkspace(NasProfile Profile, NasProfile ConnectionProfile, DsmSession Session,
        IDsmRepository Repository, IDsmApiClient Api, HttpClient Http, DsmConnectionSource Source, ChatWorkspaceSession? Chat)
    {
        public CancellationTokenSource CloudLifetime { get; } = new();
        public Task CloudRecovery { get; set; } = Task.CompletedTask;
        public ChatPage? ChatPage { get; set; }
        public ForegroundTransferCoordinator? Transfers { get; set; }
        public WindowsTransferPickerService? TransferPicker { get; set; }
    }
    private readonly Dictionary<Guid, ConnectedWorkspace> _connectedWorkspaces = [];
    private readonly List<Task> _workspaceDisposals = [];
    internal event Action<ChatNotificationTarget>? ChatNotificationRequested;

    internal ChatPage GetChatPage(IChatRepository repository)
    {
        ObjectDisposedException.ThrowIf(_shuttingDown, this);
        if (_connectedWorkspaces.TryGetValue(repository.ProfileId, out var workspace) &&
            ReferenceEquals(workspace.Repository, repository) && workspace.Chat is { } session)
        {
            var page = workspace.ChatPage ??= new(repository, session);
            page.RefreshLocalization();
            return page;
        }
        // 仅合成宿主没有真实网络连接对象。
        return new(repository);
    }

    internal bool IsChatNotificationCurrent(ChatNotificationTarget target) =>
        !_shuttingDown && _connectedWorkspaces.TryGetValue(target.ProfileId, out var workspace) &&
        workspace.Chat is { IsDisposed: false, NotificationsEnabled: true } chat && chat.Id == target.SessionId;

    internal bool ActivateChatNotificationWorkspace(ChatNotificationTarget target)
    {
        if (!IsChatNotificationCurrent(target)) return false;
        ActivateConnectedWorkspace(_connectedWorkspaces[target.ProfileId]);
        return true;
    }

    private void ChatSettingsChanged(object? sender, AppSettingsChangedEventArgs args)
    {
        foreach (var workspace in _connectedWorkspaces.Values)
            if (workspace.Chat is { } chat) chat.NotificationsEnabled = AppSettingsService.Current.Preferences.ChatNotificationsEnabled;
    }

    private void ActivateConnectedWorkspace(ConnectedWorkspace workspace)
    {
        if (_shuttingDown) return;
        CancelConnection();
        ++_profileSelectionGeneration;
        ActiveProfile = workspace.Profile; ActiveConnectionProfile = workspace.ConnectionProfile;
        Session = workspace.Session; Repository = workspace.Repository; _api = workspace.Api;
        ActiveConnectionSource = workspace.Source;
        AvailableModules.Clear();
        foreach (var module in Repository.AvailableModules) AvailableModules.Add(module);
        ConnectionChanged?.Invoke(this, true);
    }

    private void DetachActiveWorkspace()
    {
        ++_profileSelectionGeneration;
        ActiveProfile = null; ActiveConnectionProfile = null; Session = null; Repository = null;
        ActiveConnectionSource = null; _api = null; AvailableModules.Clear();
        ConnectionChanged?.Invoke(this, false);
    }

    private void ReleaseWorkspace(Guid profileId) => _ = ReleaseWorkspaceAsync(profileId);

    private Task ReleaseWorkspaceAsync(Guid profileId, Func<Task>? beforeHttpDispose = null)
    {
        if (!_connectedWorkspaces.Remove(profileId, out var workspace)) return beforeHttpDispose?.Invoke() ?? Task.CompletedTask;
        workspace.CloudLifetime.Cancel();
        (workspace.Repository as INasSettingsRepository)?.StopPackageInstallationTracking();
        workspace.Chat?.Dispose();
        DsmRepository.UnregisterRepository(profileId, workspace.Repository as DsmRepository);
        DisconnectOffice(profileId);
        foreach (var mapping in _cloudDrives.Mappings.Where(item => item.ProfileId == profileId)) CancelDesktopDriveTask(mapping);
        _cloudDrives.DisconnectProfile(profileId);
        _workspaceDisposals.RemoveAll(task => task.IsCompletedSuccessfully);
        var disposal = DisposeWorkspaceAsync(workspace, beforeHttpDispose);
        _workspaceDisposals.Add(disposal);
        return disposal;
    }

    private static async Task DisposeWorkspaceAsync(ConnectedWorkspace workspace, Func<Task>? beforeHttpDispose)
    {
        try
        {
            // 先取消传输并等待本机内容保留，再结束原会话和网络连接。
            var transfers = workspace.TransferPicker?.DisposeAsync() ?? ValueTask.CompletedTask;
            try { if (workspace.ChatPage is { } page) await page.DisposeAsync(); }
            finally { await transfers; workspace.Transfers?.Dispose(); }
            if (beforeHttpDispose is not null) await beforeHttpDispose();
        }
        finally
        {
            try { await workspace.CloudRecovery; }
            finally { workspace.CloudLifetime.Dispose(); workspace.Http.Dispose(); }
        }
    }

    private static bool MatchesConnectedProfile(NasProfile first, NasProfile second) =>
        first.Id == second.Id && first.Host == second.Host && first.Port == second.Port && first.Username == second.Username;
}
