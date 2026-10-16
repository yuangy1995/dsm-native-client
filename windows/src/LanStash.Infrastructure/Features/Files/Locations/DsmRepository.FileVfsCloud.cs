using System.Globalization;
using System.Text.RegularExpressions;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private readonly object _vfsCloudGate = new();
    private FileVfsCloudRequest? _vfsCloudRequest;
    private string? _vfsCloudScope;

    public async Task<FileVfsCloudRequest> PrepareVfsCloudAsync(string protocol, FileVfsProfile? existing = null, CancellationToken cancellationToken = default)
    {
        if (!CanManageVfs || !HasFixedCapability("SYNO.Core.System", 1)) throw new NotSupportedException();
        if (_api.GetBaseUri(_profile).Scheme != Uri.UriSchemeHttps) throw VfsInvalid();
        if (existing is not null && (existing.ProfileId != _profile.Id || existing.Protocol != protocol || existing.State == FileVfsState.Unknown || string.IsNullOrEmpty(existing.Account))) throw VfsInvalid();
        await RequireFileShareAdvancedWriteAsync(cancellationToken).ConfigureAwait(false);
        if (!(await ListVfsProtocolsAsync(cancellationToken).ConfigureAwait(false)).Any(p => p.Id == protocol && p.SupportsCloudAuthorization)) throw new NotSupportedException();
        if (existing is not null && !(await ListVfsProfilesAsync(cancellationToken).ConfigureAwait(false)).Contains(existing)) throw VfsInvalid();
        // 版本仅用于官方授权页面必需参数，不作为开放操作的白名单。
        var system = await VfsCallAsync("SYNO.Core.System", "info", [], cancellationToken).ConfigureAwait(false);
        var match = Regex.Match(VfsText(system, "firmware_ver"), @"(?:^|[^0-9])([0-9]+)\.([0-9]+)(?:[^0-9]|$)", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(250));
        if (!match.Success || !int.TryParse(match.Groups[1].Value, out var major) || major <= 0 || !int.TryParse(match.Groups[2].Value, out var minor)) throw VfsInvalid();
        cancellationToken.ThrowIfCancellationRequested();
        var uri = new Uri($"https://synooauth.synology.com/FileStation/Cloud/login.php?major={major.ToString(CultureInfo.InvariantCulture)}&minor={minor.ToString(CultureInfo.InvariantCulture)}&type={Uri.EscapeDataString(protocol)}");
        var request = new FileVfsCloudRequest(Guid.NewGuid(), _profile.Id, protocol, uri, DateTimeOffset.UtcNow.AddMinutes(10), existing);
        lock (_vfsCloudGate) { _vfsCloudRequest = request; _vfsCloudScope = ServiceScope(); }
        return request;
    }

    public void CancelVfsCloud(Guid requestId)
    {
        lock (_vfsCloudGate) if (_vfsCloudRequest?.RequestId == requestId) { _vfsCloudRequest = null; _vfsCloudScope = null; }
    }

    public Task<FileVfsProgress> AuthorizeVfsAsync(FileVfsChange change, FileVfsCloudAuthorization authorization, CancellationToken cancellationToken = default)
    {
        bool valid;
        lock (_vfsCloudGate)
        {
            var request = _vfsCloudRequest;
            valid = request is not null && request.RequestId == authorization.RequestId && request.ProfileId == authorization.ProfileId &&
                request.Protocol == authorization.Protocol && request.Existing == change.Existing && request.ExpiresAt > DateTimeOffset.UtcNow &&
                _vfsCloudScope == ServiceScope() && change.Action is FileVfsAction.CreateCloud or FileVfsAction.Reauthorize;
            // 一次尝试最多进入一次提交流程；失败后必须重新授权，未知结果沿原操作只读恢复。
            if (request?.RequestId == authorization.RequestId) { _vfsCloudRequest = null; _vfsCloudScope = null; }
        }
        return valid ? ChangeVfsCoreAsync(change, null, authorization, cancellationToken) :
            Task.FromResult(VfsResult(change, MutationResultStatus.ConfirmedFailure, false, MutationErrorCategory.Conflict, FileVfsNotice.AuthorizationMismatch));
    }

    private bool ValidVfsCloudChange(FileVfsChange change, FileVfsCloudAuthorization? authorization, string? password) =>
        change.Configuration is null && change.Baseline is null && password is null && change.CloudIdentity is { IsValid: true } identity &&
        authorization is not null && authorization.ProfileId == _profile.Id && authorization.Protocol == identity.Protocol &&
        authorization.Account == identity.Account && !string.IsNullOrEmpty(authorization.AccessToken) && authorization.ExpiresIn is not < 0;

    private Dictionary<string, string> VfsCloudParameters(string api, FileVfsChange change, FileVfsCloudAuthorization authorization)
    {
        string Value(string value) => ShareParameterString(api, value);
        var fields = new Dictionary<string, string> { ["account"] = Value(authorization.Account), ["access_token"] = Value(authorization.AccessToken) };
        if (authorization.ClientId is { } client) fields["client_id"] = Value(client);
        if (authorization.RefreshToken is { } refresh) fields["refresh_token"] = Value(refresh);
        if (authorization.ExpiresIn is { } expires) fields["expires_in"] = expires.ToString(CultureInfo.InvariantCulture);
        if (change.Action == FileVfsAction.CreateCloud)
        { fields["protocol"] = Value(change.CloudIdentity!.Protocol); fields["alias"] = Value(change.CloudIdentity.Alias); fields["hostname"] = Value(""); }
        else fields["id"] = Value(change.Existing!.Id);
        return fields;
    }

    private static bool VfsMatchesCloud(FileVfsProfile profile, FileVfsCloudIdentity identity) =>
        profile.Protocol == identity.Protocol && profile.Account == identity.Account && profile.Alias == identity.Alias;
}
