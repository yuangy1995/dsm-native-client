using LanStash.App.Features.Transfers;
using LanStash.App.Features.Chat;
using LanStash.App.Platform.Chat;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel
{
    internal ChatSavedRecordings SavedVoiceRecordings { get; } = new(WindowsChatVoiceCapture.DraftDirectory);
    internal IReadOnlySet<string> ProtectedVoicePaths() => _connectedWorkspaces.Values
        .SelectMany(item => item.ChatPage?.VoiceRecordings ?? []).Select(item => item.Recording?.Path).OfType<string>()
        .Concat(WindowsChatVoiceCapture.CapturingPaths).ToHashSet(StringComparer.OrdinalIgnoreCase);
    internal bool HasChatDrafts => _connectedWorkspaces.Values.Any(item => item.ChatPage?.HasUnsentDrafts == true);
    internal bool HasSendingChat => _connectedWorkspaces.Values.Any(item => item.ChatPage?.HasSendingMessages == true);
    internal bool HasVoiceDrafts => _connectedWorkspaces.Values.Any(item => item.ChatPage?.VoiceRecordings.Any(voice => voice.IsCapturing || voice.Recording is not null) == true);

    internal bool IsConnectedWorkspace(IDsmRepository repository) => !_shuttingDown &&
        _connectedWorkspaces.Values.Any(workspace => ReferenceEquals(workspace.Repository, repository));

    internal bool ActivateTransferWorkspace(IDsmRepository repository)
    {
        if (_shuttingDown) return false;
        var workspace = _connectedWorkspaces.Values.FirstOrDefault(item => ReferenceEquals(item.Repository, repository));
        if (workspace is null) return false;
        ActivateConnectedWorkspace(workspace);
        return true;
    }

    internal bool HasRunningTransfers => _connectedWorkspaces.Values.Any(item => item.TransferPicker?.HasRunningTransfers == true);

    internal (ForegroundTransferCoordinator Coordinator, WindowsTransferPickerService? Picker, bool OwnedByWorkspace)
        GetWorkspaceTransfers(IForegroundTransferNotificationService? notifications)
    {
        ObjectDisposedException.ThrowIf(_shuttingDown, this);
        if (ActiveProfile is { } profile && Repository is { } repository)
        {
            var owned = _connectedWorkspaces.TryGetValue(profile.Id, out var workspace) && ReferenceEquals(workspace.Repository, repository);
            if (owned && workspace!.Transfers is { } existing) return (existing, workspace.TransferPicker, true);
            var coordinator = new ForegroundTransferCoordinator(notifications);
            coordinator.ActivateProfile(profile.Id.ToString());
            var picker = new WindowsTransferPickerService(repository, coordinator,
                new WindowsTransferSavePicker(() => (Application.Current as App)?.MainWindow),
                new WindowsTransferOpenPicker(() => (Application.Current as App)?.MainWindow));
            if (owned) { workspace!.Transfers = coordinator; workspace.TransferPicker = picker; }
            return (coordinator, picker, owned);
        }
        return (new ForegroundTransferCoordinator(notifications), null, false);
    }
}
