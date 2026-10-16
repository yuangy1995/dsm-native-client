using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Locations;

public sealed partial class FileVfsViewModel
{
    private FileVfsCloudRequest? _cloudRequest;
    private FileVfsCloudAuthorization? _authorization;
    private FileVfsCloudSession? _cloudSession;
    private CancellationTokenSource? _cloudCancellation;
    private int _cloudGeneration;
    public string? CloudProtocol { get; private set; }
    public string CloudAlias { get; private set; } = "";
    public string CloudAccount => _authorization?.Account ?? (IsCloud ? Progress?.Change.CloudIdentity?.Account : null) ?? Selected?.Account ?? "";
    public bool IsCloud => Action is FileVfsAction.CreateCloud or FileVfsAction.Reauthorize;
    public bool IsAuthorizing { get; private set; }
    public bool HasCloudAuthorization => _authorization is not null;
    public bool SupportsCloud => repository is IFileVfsCloudRepository;
    public string? CloudMessageKey { get; private set; }
    private bool CanSaveCloud => _authorization is not null && _cloudRequest?.ExpiresAt > DateTimeOffset.UtcNow &&
        new FileVfsCloudIdentity(CloudProtocol ?? "", CloudAlias, CloudAccount).IsValid;

    public void NewCloud(string? protocol = null)
    {
        if (_disposed || IsBusy || IsPending || LoadFailed || !SupportsCloud) return;
        var selected = Protocols.FirstOrDefault(p => p.SupportsCloudAuthorization && (protocol is null || p.Id == protocol));
        if (selected is null) return;
        ResetCloud(); CloudProtocol = selected.Id; CloudAlias = ""; Action = FileVfsAction.CreateCloud;
        Selected = null; Draft = null; Detail = null; Progress = null; DetailFailed = false; Notify();
    }
    public void Reauthorize()
    {
        if (!CanEdit || !SupportsCloud || Selected is not { State: not FileVfsState.Unknown, Account: not null } p ||
            !Protocols.Any(item => item.Id == p.Protocol && item.SupportsCloudAuthorization)) return;
        ResetCloud(); CloudProtocol = p.Protocol; CloudAlias = p.Alias; Action = FileVfsAction.Reauthorize;
        Draft = null; Detail = null; Progress = null; Notify();
    }
    public void UpdateCloudAlias(string alias)
    { if (!CanEdit || Action != FileVfsAction.CreateCloud) return; CloudAlias = alias; Progress = null; Notify(); }

    public async Task AuthorizeCloudAsync(Func<Uri, Task<bool>> openBrowser)
    {
        if (!CanEdit || !IsCloud || CloudProtocol is null || repository is not IFileVfsCloudRepository cloud) return;
        ResetCloud(); var generation = _cloudGeneration;
        IsBusy = IsAuthorizing = true; CloudMessageKey = "VfsCloudWaiting"; Progress = null; Notify();
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token); _cloudCancellation = cancellation;
        try
        {
            var request = await cloud.PrepareVfsCloudAsync(CloudProtocol, Selected, cancellation.Token);
            if (_disposed || generation != _cloudGeneration) { cloud.CancelVfsCloud(request.RequestId); return; }
            _cloudRequest = request;
            var text = LocalizationService.Current;
            var session = new FileVfsCloudSession(request, text.Get("VfsCloudBrowserComplete"), text.Get("VfsCloudFailed"));
            _cloudSession = session;
            if (!await openBrowser(session.LoginUri)) throw new InvalidOperationException();
            var authorization = await session.Completion;
            if (_disposed || generation != _cloudGeneration) { authorization.Dispose(); return; }
            if (Selected is { } existing && authorization.Account != existing.Account)
            { authorization.Dispose(); cloud.CancelVfsCloud(request.RequestId); CloudMessageKey = "VfsCloudMismatch"; }
            else { _authorization = authorization; CloudMessageKey = "VfsCloudReady"; }
        }
        catch { if (!_disposed && generation == _cloudGeneration) { if (_cloudRequest is { } request) cloud.CancelVfsCloud(request.RequestId); CloudMessageKey = "VfsCloudFailed"; } }
        finally
        {
            cancellation.Dispose();
            if (!_disposed && generation == _cloudGeneration)
            { _cloudSession?.Dispose(); _cloudSession = null; _cloudCancellation = null; IsBusy = IsAuthorizing = false; Notify(); }
        }
    }

    public void CancelCloud()
    { if (!IsAuthorizing) return; ResetCloud(); IsBusy = false; CloudMessageKey = "VfsCloudCancelled"; Notify(); }
    private void ResetCloud()
    {
        _cloudGeneration++; _cloudCancellation?.Cancel(); _cloudCancellation = null;
        _cloudSession?.Dispose(); _cloudSession = null; _authorization?.Dispose(); _authorization = null;
        if (_cloudRequest is { } request && repository is IFileVfsCloudRepository cloud) cloud.CancelVfsCloud(request.RequestId);
        _cloudRequest = null; CloudMessageKey = null; IsAuthorizing = false;
    }
    private async Task SaveCloudAsync()
    {
        if (repository is not IFileVfsCloudRepository cloud || _authorization is not { } authorization) return;
        var change = new FileVfsChange(repository.ProfileId, Guid.NewGuid(), Action!.Value, Selected,
            Confirmed: true, CloudIdentity: new(CloudProtocol!, CloudAlias, authorization.Account));
        _authorization = null; CloudMessageKey = null; IsBusy = true; HasAttemptedSave = true; Notify();
        try
        {
            var progress = await cloud.AuthorizeVfsAsync(change, authorization, _lifetime.Token);
            if (_disposed) return;
            Progress = progress; Pending = progress.Outcome.RequiresRefresh ? [progress] : [];
        }
        catch { if (!_disposed) { Progress = new(change, new(1, MutationResultStatus.SubmittedButUnverified, "fileVfs", true, true, new(0, 0, 1))); Pending = [Progress]; } }
        finally { authorization.Dispose(); ResetCloud(); if (!_disposed) { IsBusy = false; Notify(); } }
        if (!_disposed && Progress?.Outcome.Status == MutationResultStatus.ConfirmedSuccess) await LoadAsync();
    }
}
