using LanStash.Domain;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel
{
    private CancellationToken ConnectedCloudToken(Guid profileId, IDsmRepository repository)
    {
        if (_shuttingDown || !_connectedWorkspaces.TryGetValue(profileId, out var workspace) ||
            !ReferenceEquals(workspace.Repository, repository))
            throw new InvalidOperationException("CloudDriveSignInRequired");
        return workspace.CloudLifetime.Token;
    }

    private void StartDesktopDriveRecovery(ConnectedWorkspace workspace)
    {
        var token = workspace.CloudLifetime.Token;
        // 初次注册和后续恢复都归属原工作区；切页或切换 NAS 不改变任务所有者。
        workspace.CloudRecovery = Task.Run(async () =>
        {
            var delaySeconds = 15;
            while (!token.IsCancellationRequested)
            {
                try
                {
                    await _cloudDrives.ActivateAsync(workspace.Profile.Id, workspace.Repository, token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    var hasIssue = _cloudDrives.Mappings.Where(item => item.ProfileId == workspace.Profile.Id)
                        .Any(mapping => _cloudDrives.Runtime(mapping).State is not
                            (DesktopDriveMappingState.Available or DesktopDriveMappingState.Paused));
                    delaySeconds = hasIssue ? Math.Min(delaySeconds * 2, 300) : 300;
                    DesktopDriveProgressChanged?.Invoke(this, EventArgs.Empty);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
                catch { delaySeconds = Math.Min(delaySeconds * 2, 300); }
                try { await Task.Delay(TimeSpan.FromSeconds(delaySeconds + Random.Shared.Next(0, 6)), token).ConfigureAwait(false); }
                catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            }
        }, CancellationToken.None);
    }
}
